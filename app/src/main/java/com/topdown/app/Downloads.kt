package com.topdown.app

import android.app.DownloadManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.CookieManager
import android.webkit.MimeTypeMap
import android.webkit.URLUtil
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale

/** سجل تحميل محفوظ. id موجب = DownloadManager، سالب = ملف محفوظ محليًا (blob/data). */
data class DownloadRecord(
    val id: Long,
    val name: String,
    val url: String,
    val mime: String?,
    val localUri: String?,
    val time: Long,
) {
    fun toJson() = JSONObject().apply {
        put("id", id); put("name", name); put("url", url)
        put("mime", mime ?: ""); put("localUri", localUri ?: ""); put("time", time)
    }

    companion object {
        fun from(o: JSONObject) = DownloadRecord(
            o.getLong("id"), o.optString("name"), o.optString("url"),
            o.optString("mime").ifBlank { null }, o.optString("localUri").ifBlank { null },
            o.optLong("time"),
        )
    }
}

data class DownloadInfo(
    val record: DownloadRecord,
    val status: Int,      // DownloadManager.STATUS_*
    val reason: Int,
    val downloaded: Long,
    val total: Long,
) {
    val isActive get() = status == DownloadManager.STATUS_RUNNING || status == DownloadManager.STATUS_PENDING || status == DownloadManager.STATUS_PAUSED
    val percent get() = if (total > 0) ((downloaded * 100) / total).toInt() else -1
}

class Downloads(context: Context) {
    private val ctx = context.applicationContext
    private val dm = ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private val store = ctx.getSharedPreferences("downloads", Context.MODE_PRIVATE)

    // ---------- السجلّات ----------
    fun records(): List<DownloadRecord> {
        val arr = runCatching { JSONArray(store.getString("items", "[]")) }.getOrDefault(JSONArray())
        return (0 until arr.length()).mapNotNull { runCatching { DownloadRecord.from(arr.getJSONObject(it)) }.getOrNull() }
    }

    private fun save(list: List<DownloadRecord>) {
        val arr = JSONArray(); list.forEach { arr.put(it.toJson()) }
        store.edit().putString("items", arr.toString()).apply()
    }

    private fun add(r: DownloadRecord) = save(listOf(r) + records().filter { it.id != r.id })
    fun forget(id: Long) = save(records().filter { it.id != id })
    fun clearList() = save(emptyList())

    // ---------- التحميل عبر DownloadManager ----------
    fun enqueue(
        url: String,
        userAgent: String?,
        contentDisposition: String?,
        mimeType: String?,
        referer: String?,
        wifiOnly: Boolean,
        suggestedName: String? = null,
    ): DownloadRecord {
        val mime = mimeType?.takeIf { it.isNotBlank() && it != "application/octet-stream" }
            ?: guessMime(url) ?: mimeType
        val name = sanitize(suggestedName ?: URLUtil.guessFileName(url, contentDisposition, mime))
        val req = DownloadManager.Request(Uri.parse(url)).apply {
            CookieManager.getInstance().getCookie(url)?.let { addRequestHeader("Cookie", it) }
            userAgent?.let { addRequestHeader("User-Agent", it) }
            referer?.let { addRequestHeader("Referer", it) }
            setTitle(name)
            setDescription(ctx.getString(R.string.app_name))
            mime?.let { setMimeType(it) }
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            setAllowedNetworkTypes(
                if (wifiOnly) DownloadManager.Request.NETWORK_WIFI
                else DownloadManager.Request.NETWORK_WIFI or DownloadManager.Request.NETWORK_MOBILE
            )
            setAllowedOverMetered(!wifiOnly)
            setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, "$FOLDER/$name")
        }
        val id = dm.enqueue(req)
        return DownloadRecord(id, name, url, mime, null, System.currentTimeMillis()).also { add(it) }
    }

    fun retry(r: DownloadRecord, userAgent: String?, wifiOnly: Boolean): DownloadRecord {
        if (r.id > 0) dm.remove(r.id)
        forget(r.id)
        return enqueue(r.url, userAgent, null, r.mime, null, wifiOnly, r.name)
    }

    // ---------- حفظ ملف محلي (blob: / data:) ----------
    fun saveLocal(src: File, rawName: String, mime: String?): DownloadRecord {
        val type = mime?.takeIf { it.isNotBlank() } ?: "application/octet-stream"
        var name = sanitize(rawName)
        if (!name.contains('.')) {
            MimeTypeMap.getSingleton().getExtensionFromMimeType(type)?.let { name = "$name.$it" }
        }
        val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, type)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = ctx.contentResolver
            val u = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: error("insert failed")
            resolver.openOutputStream(u)!!.use { out -> src.inputStream().use { it.copyTo(out) } }
            values.clear(); values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(u, values, null, null)
            u
        } else {
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), FOLDER)
            dir.mkdirs()
            val dest = unique(File(dir, name))
            src.copyTo(dest, overwrite = true)
            Uri.fromFile(dest)
        }
        src.delete()
        val id = -System.currentTimeMillis()
        return DownloadRecord(id, name, "", type, uri.toString(), System.currentTimeMillis()).also { add(it) }
    }

    // ---------- الحالة ----------
    fun infos(): List<DownloadInfo> {
        val recs = records()
        val dmIds = recs.filter { it.id > 0 }.map { it.id }.toLongArray()
        val states = HashMap<Long, DownloadInfo>()
        if (dmIds.isNotEmpty()) {
            dm.query(DownloadManager.Query().setFilterById(*dmIds))?.use { c ->
                val iId = c.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)
                val iSt = c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)
                val iRe = c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)
                val iSo = c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
                val iTo = c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
                while (c.moveToNext()) {
                    val id = c.getLong(iId)
                    val rec = recs.first { it.id == id }
                    states[id] = DownloadInfo(rec, c.getInt(iSt), c.getInt(iRe), c.getLong(iSo), c.getLong(iTo))
                }
            }
        }
        return recs.mapNotNull { r ->
            if (r.id > 0) states[r.id] ?: DownloadInfo(r, DownloadManager.STATUS_FAILED, 0, 0, 0)
            else DownloadInfo(r, DownloadManager.STATUS_SUCCESSFUL, 0, sizeOf(r), sizeOf(r))
        }
    }

    fun activeCount(): Int = infos().count { it.isActive }

    fun find(id: Long): DownloadRecord? = records().firstOrNull { it.id == id }

    // ---------- فتح / مشاركة / حذف ----------
    fun contentUri(r: DownloadRecord): Uri? {
        if (r.id > 0) return dm.getUriForDownloadedFile(r.id)
        val u = Uri.parse(r.localUri ?: return null)
        return if (u.scheme == "file") FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", File(u.path!!)) else u
    }

    fun mimeOf(r: DownloadRecord): String =
        (if (r.id > 0) dm.getMimeTypeForDownloadedFile(r.id) else null)
            ?: r.mime ?: guessMime(r.name) ?: "*/*"

    fun openIntent(r: DownloadRecord): Intent? {
        val uri = contentUri(r) ?: return null
        return Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeOf(r))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    fun shareIntent(r: DownloadRecord): Intent? {
        val uri = contentUri(r) ?: return null
        val send = Intent(Intent.ACTION_SEND).setType(mimeOf(r))
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return Intent.createChooser(send, r.name)
    }

    fun delete(r: DownloadRecord) {
        if (r.id > 0) dm.remove(r.id)
        else r.localUri?.let { s ->
            val u = Uri.parse(s)
            runCatching {
                if (u.scheme == "file") File(u.path!!).delete() else ctx.contentResolver.delete(u, null, null)
            }
        }
        forget(r.id)
    }

    private fun sizeOf(r: DownloadRecord): Long = runCatching {
        val u = Uri.parse(r.localUri ?: return 0)
        if (u.scheme == "file") File(u.path!!).length()
        else ctx.contentResolver.openAssetFileDescriptor(u, "r")?.use { it.length } ?: 0
    }.getOrDefault(0)

    companion object {
        const val FOLDER = "Topdown"

        fun guessMime(nameOrUrl: String): String? {
            val ext = MimeTypeMap.getFileExtensionFromUrl(nameOrUrl)?.lowercase(Locale.ROOT)
                ?.ifBlank { null } ?: nameOrUrl.substringAfterLast('.', "").lowercase(Locale.ROOT)
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        }

        fun sanitize(name: String): String {
            val clean = name.replace(Regex("""[\\/:*?"<>|\u0000-\u001f]"""), "_").trim().trim('.')
            return clean.take(120).ifBlank { "download" }
        }

        private fun unique(f: File): File {
            if (!f.exists()) return f
            val base = f.nameWithoutExtension; val ext = f.extension
            var i = 1
            while (true) {
                val c = File(f.parentFile, if (ext.isEmpty()) "$base ($i)" else "$base ($i).$ext")
                if (!c.exists()) return c
                i++
            }
        }

        fun humanSize(bytes: Long): String {
            if (bytes <= 0) return "—"
            val u = arrayOf("B", "KB", "MB", "GB")
            var v = bytes.toDouble(); var i = 0
            while (v >= 1024 && i < u.lastIndex) { v /= 1024; i++ }
            return String.format(Locale.US, if (i == 0) "%.0f %s" else "%.1f %s", v, u[i])
        }
    }
}
