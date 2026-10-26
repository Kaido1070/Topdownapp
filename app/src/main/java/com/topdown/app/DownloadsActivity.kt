package com.topdown.app

import android.app.DownloadManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.format.DateUtils
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.progressindicator.LinearProgressIndicator
import com.topdown.app.databinding.ActivityDownloadsBinding

class DownloadsActivity : AppCompatActivity() {

    private lateinit var b: ActivityDownloadsBinding
    private lateinit var downloads: Downloads
    private val main = Handler(Looper.getMainLooper())
    private val adapter = Adapter()

    private val ticker = object : Runnable {
        override fun run() {
            val list = downloads.infos()
            adapter.submitList(list)
            b.empty.isVisible = list.isEmpty()
            main.postDelayed(this, if (list.any { it.isActive }) 800 else 3000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        downloads = Downloads(this)
        b = ActivityDownloadsBinding.inflate(layoutInflater)
        setContentView(b.root)

        WindowCompat.setDecorFitsSystemWindows(window, false)
        ViewCompat.setOnApplyWindowInsetsListener(b.root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            b.content.updatePadding(top = bars.top, left = bars.left, right = bars.right)
            b.list.updatePadding(bottom = bars.bottom + dp(24))
            insets
        }

        b.list.layoutManager = LinearLayoutManager(this)
        b.list.adapter = adapter
        b.list.itemAnimator = null
        b.btnClose.setOnClickListener { finish() }
        b.btnClear.setOnClickListener {
            MaterialAlertDialogBuilder(this)
                .setTitle(R.string.clear_all)
                .setMessage("سيتم مسح القائمة فقط، وتبقى الملفات في مجلد Download/Topdown.")
                .setPositiveButton(R.string.clear_all) { _, _ -> downloads.clearList(); refresh() }
                .setNegativeButton(R.string.cancel, null)
                .show()
        }
    }

    override fun onResume() { super.onResume(); main.post(ticker) }
    override fun onPause() { main.removeCallbacks(ticker); super.onPause() }

    private fun refresh() { main.removeCallbacks(ticker); main.post(ticker) }

    private fun onItemClick(info: DownloadInfo) {
        when (info.status) {
            DownloadManager.STATUS_SUCCESSFUL -> {
                val i = downloads.openIntent(info.record)
                if (i == null || runCatching { startActivity(i) }.isFailure) toast(getString(R.string.no_app_to_open))
            }
            DownloadManager.STATUS_FAILED -> if (info.record.url.isNotBlank()) {
                downloads.retry(info.record, null, Prefs(this).wifiOnly); refresh()
            }
        }
    }

    private fun onDelete(info: DownloadInfo) {
        MaterialAlertDialogBuilder(this)
            .setTitle(info.record.name)
            .setMessage(if (info.isActive) "إلغاء التحميل؟" else "حذف الملف من الجهاز؟")
            .setPositiveButton(if (info.isActive) R.string.cancel else R.string.delete) { _, _ ->
                downloads.delete(info.record); refresh()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun onShare(info: DownloadInfo) {
        val i = downloads.shareIntent(info.record)
        if (i == null || runCatching { startActivity(i) }.isFailure) toast(getString(R.string.no_app_to_open))
    }

    private fun statusText(i: DownloadInfo): String = when (i.status) {
        DownloadManager.STATUS_PENDING -> getString(R.string.status_pending)
        DownloadManager.STATUS_RUNNING -> buildString {
            append(getString(R.string.status_running))
            if (i.percent >= 0) append(" ${i.percent}%")
            append(" • ${Downloads.humanSize(i.downloaded)} / ${Downloads.humanSize(i.total)}")
        }
        DownloadManager.STATUS_PAUSED ->
            if (i.reason == DownloadManager.PAUSED_QUEUED_FOR_WIFI) getString(R.string.wifi_waiting)
            else getString(R.string.status_paused)
        DownloadManager.STATUS_SUCCESSFUL -> "${getString(R.string.status_done)} • ${Downloads.humanSize(i.total)} • " +
            DateUtils.getRelativeTimeSpanString(i.record.time)
        else -> "${getString(R.string.status_failed)} — اضغط لإعادة المحاولة"
    }

    private fun iconFor(i: DownloadInfo): Int {
        val m = downloads.mimeOf(i.record)
        return when {
            m.startsWith("video") || m.startsWith("audio") -> R.drawable.ic_play
            else -> R.drawable.ic_file
        }
    }

    private inner class Adapter : ListAdapter<DownloadInfo, Adapter.VH>(object : DiffUtil.ItemCallback<DownloadInfo>() {
        override fun areItemsTheSame(a: DownloadInfo, b: DownloadInfo) = a.record.id == b.record.id
        override fun areContentsTheSame(a: DownloadInfo, b: DownloadInfo) = a == b
    }) {
        inner class VH(v: View) : RecyclerView.ViewHolder(v) {
            val icon: ImageView = v.findViewById(R.id.icon)
            val name: TextView = v.findViewById(R.id.name)
            val meta: TextView = v.findViewById(R.id.meta)
            val bar: LinearProgressIndicator = v.findViewById(R.id.bar)
            val share: MaterialButton = v.findViewById(R.id.btnShare)
            val delete: MaterialButton = v.findViewById(R.id.btnDelete)
        }

        override fun onCreateViewHolder(p: ViewGroup, t: Int) =
            VH(LayoutInflater.from(p.context).inflate(R.layout.item_download, p, false))

        override fun onBindViewHolder(h: VH, pos: Int) {
            val i = getItem(pos)
            h.name.text = i.record.name
            h.meta.text = statusText(i)
            h.meta.setTextColor(getColor(if (i.status == DownloadManager.STATUS_FAILED) R.color.danger else R.color.on_bg_muted))
            h.icon.setImageResource(iconFor(i))
            h.bar.isVisible = i.isActive
            if (i.isActive) {
                if (i.percent >= 0) { h.bar.isIndeterminate = false; h.bar.setProgressCompat(i.percent, true) }
                else if (!h.bar.isIndeterminate) { h.bar.visibility = View.INVISIBLE; h.bar.isIndeterminate = true; h.bar.visibility = View.VISIBLE }
            }
            h.share.isVisible = i.status == DownloadManager.STATUS_SUCCESSFUL
            h.delete.setIconResource(if (i.isActive) R.drawable.ic_close else R.drawable.ic_delete)
            h.itemView.setOnClickListener { onItemClick(i) }
            h.share.setOnClickListener { onShare(i) }
            h.delete.setOnClickListener { onDelete(i) }
        }
    }

    private fun toast(m: String) = Toast.makeText(this, m, Toast.LENGTH_SHORT).show()
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
}
