package com.topdown.app

import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.webkit.JavascriptInterface
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap

/** الجسر بين الصفحة والتطبيق (window.TopdownApp). */
class WebBridge(
    private val cacheDir: File,
    private val onMediaFound: (List<MediaItem>) -> Unit,
    private val onBlobReady: (file: File, name: String, mime: String) -> Unit,
    private val onBlobFailed: () -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())

    private class Pending(val file: File, val out: FileOutputStream, val name: String, val mime: String)
    private val pending = ConcurrentHashMap<String, Pending>()

    @JavascriptInterface
    fun onMedia(json: String) {
        val items = MediaItem.parse(json)
        main.post { onMediaFound(items) }
    }

    @JavascriptInterface
    fun blobStart(id: String, name: String, mime: String, size: Long) {
        val f = File(cacheDir, "blob_$id")
        pending[id] = Pending(f, FileOutputStream(f), name, mime)
    }

    @JavascriptInterface
    fun blobChunk(id: String, base64: String) {
        val p = pending[id] ?: return
        runCatching { p.out.write(Base64.decode(base64, Base64.DEFAULT)) }
            .onFailure { blobFail(id) }
    }

    @JavascriptInterface
    fun blobEnd(id: String) {
        val p = pending.remove(id) ?: return
        runCatching { p.out.close() }
        main.post { onBlobReady(p.file, p.name, p.mime) }
    }

    @JavascriptInterface
    fun blobFail(id: String) {
        pending.remove(id)?.let { runCatching { it.out.close() }; it.file.delete() }
        main.post { onBlobFailed() }
    }

    @JavascriptInterface
    fun appVersion(): String = BuildConfig.VERSION_NAME
}
