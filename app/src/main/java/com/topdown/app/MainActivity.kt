package com.topdown.app

import android.Manifest
import android.annotation.SuppressLint
import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.RenderEffect
import android.graphics.Shader
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.PopupMenu
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.isVisible
import androidx.core.view.updateLayoutParams
import androidx.core.view.updatePadding
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.checkbox.MaterialCheckBox
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar
import com.topdown.app.databinding.ActivityMainBinding

class MainActivity : AppCompatActivity() {

    private lateinit var b: ActivityMainBinding
    private lateinit var prefs: Prefs
    private lateinit var downloads: Downloads
    private val web get() = b.web
    private val main = Handler(Looper.getMainLooper())

    private var media: List<MediaItem> = emptyList()
    private var pageLoading = true
    private var hadError = false
    private var lastBackPress = 0L
    private var dockHidden = false
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null
    private var fileCallback: ValueCallback<Array<Uri>>? = null
    private var pendingDownload: (() -> Unit)? = null
    private var mobileUa = ""

    private val homeHost by lazy { Uri.parse(prefs.homeUrl).host?.removePrefix("www.") ?: "" }

    // ---------- نتائج الأنشطة ----------
    private val filePicker = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
        fileCallback?.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(res.resultCode, res.data))
        fileCallback = null
    }

    private val storagePermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) pendingDownload?.invoke() else toast(getString(R.string.download_failed))
        pendingDownload = null
    }

    private val downloadDone = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val id = i.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
            val rec = downloads.find(id) ?: return
            val ok = downloads.infos().firstOrNull { it.record.id == id }?.status == DownloadManager.STATUS_SUCCESSFUL
            if (ok) snackOpen(getString(R.string.download_saved, rec.name), rec)
            else snack(getString(R.string.download_failed))
            refreshBadge()
        }
    }

    private val netCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = main.post {
            if (b.offlineBanner.isVisible) {
                b.offlineBanner.isVisible = false
                snack(getString(R.string.back_online))
            }
            if (hadError) reload()
        }.let { }

        override fun onLost(network: Network) = main.post {
            if (!isOnline()) b.offlineBanner.isVisible = true
        }.let { }
    }

    private val badgeTicker = object : Runnable {
        override fun run() {
            val n = refreshBadge()
            if (n > 0) main.postDelayed(this, 1500)
        }
    }

    // ---------- دورة الحياة ----------
    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        splash.setKeepOnScreenCondition { pageLoading && web.progress < 40 && !hadError && savedInstanceState == null }
        main.postDelayed({ pageLoading = false }, 3500) // لا تُبقِ شاشة البداية أكثر من اللازم

        prefs = Prefs(this)
        downloads = Downloads(this)
        b = ActivityMainBinding.inflate(layoutInflater)
        setContentView(b.root)

        setupEdgeToEdge()
        setupGlass()
        setupWebView()
        setupControls()
        setupBack()

        ContextCompat.registerReceiver(
            this, downloadDone, IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE),
            ContextCompat.RECEIVER_EXPORTED,
        )
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(netCallback)

        if (savedInstanceState != null && web.restoreState(savedInstanceState) != null) {
            pageLoading = false
        } else {
            web.loadUrl(sharedUrl(intent) ?: prefs.homeUrl)
        }
        if (!isOnline()) b.offlineBanner.isVisible = true
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        sharedUrl(intent)?.let { web.loadUrl(it) }
    }

    override fun onResume() {
        super.onResume()
        web.onResume()
        applySettings()
        main.post(badgeTicker)
    }

    override fun onPause() {
        web.onPause()
        prefs.lastUrl = web.url
        main.removeCallbacks(badgeTicker)
        super.onPause()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        web.saveState(outState)
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(downloadDone) }
        runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(netCallback) }
        main.removeCallbacksAndMessages(null)
        (web.parent as? ViewGroup)?.removeView(web)
        web.destroy()
        super.onDestroy()
    }

    // ---------- الواجهة ----------
    private fun setupEdgeToEdge() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        ViewCompat.setOnApplyWindowInsetsListener(b.root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
            b.content.updatePadding(top = bars.top, left = bars.left, right = bars.right, bottom = maxOf(ime.bottom - bars.bottom, 0))
            b.dock.updateLayoutParams<ViewGroup.MarginLayoutParams> { bottomMargin = bars.bottom + dp(14) }
            b.fabMedia.updateLayoutParams<ViewGroup.MarginLayoutParams> { bottomMargin = bars.bottom + dp(92) }
            insets
        }
    }

    private fun setupGlass() {
        // تمويه حقيقي للخلفية الملوّنة (أندرويد 12+) لإعطاء إحساس الزجاج المصنفر
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.blobs.setRenderEffect(RenderEffect.createBlurEffect(dp(60).toFloat(), dp(60).toFloat(), Shader.TileMode.DECAL))
        }
        b.topBar.clipToOutline = true
        b.dock.clipToOutline = true
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        with(web.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = true
            mediaPlaybackRequiresUserGesture = false
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            cacheMode = WebSettings.LOAD_DEFAULT
            allowFileAccess = false
            mobileUa = userAgentString
            userAgentString = "$mobileUa TopdownApp/${BuildConfig.VERSION_NAME}"
        }
        android.webkit.CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(web, true)
        }

        web.addJavascriptInterface(
            WebBridge(
                cacheDir,
                onMediaFound = ::onMediaFound,
                onBlobReady = { f, name, mime -> saveLocalFile(f, name, mime) },
                onBlobFailed = { snack(getString(R.string.download_failed)) },
            ),
            "TopdownApp",
        )

        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                handleUrl(request.url, request.isForMainFrame)

            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                hadError = false
                b.errorView.isVisible = false
                media = emptyList(); updateMediaFab()
                b.pageUrl.text = displayUrl(url)
                setLoadingUi(true)
            }

            override fun onPageFinished(view: WebView, url: String) {
                pageLoading = false
                b.swipe.isRefreshing = false
                setLoadingUi(false)
                b.pageTitle.text = view.title?.takeIf { it.isNotBlank() } ?: getString(R.string.app_name)
                b.pageUrl.text = displayUrl(url)
                updateNavButtons()
                if (prefs.detectMedia) view.evaluateJavascript(Scripts.MEDIA_SCANNER, null)
                android.webkit.CookieManager.getInstance().flush()
            }

            override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
                updateNavButtons()
                b.pageUrl.text = displayUrl(url)
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (!request.isForMainFrame) return
                showError(error.description?.toString())
            }
        }

        web.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                b.progress.setProgressCompat(newProgress, true)
                if (newProgress >= 100) setLoadingUi(false)
            }

            override fun onReceivedTitle(view: WebView, title: String?) {
                if (!title.isNullOrBlank()) b.pageTitle.text = title
            }

            override fun onShowCustomView(view: View, callback: CustomViewCallback) = enterFullscreen(view, callback)
            override fun onHideCustomView() = exitFullscreen()

            override fun onShowFileChooser(
                webView: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams,
            ): Boolean {
                fileCallback?.onReceiveValue(null)
                fileCallback = callback
                return try {
                    filePicker.launch(params.createIntent().apply {
                        if (params.mode == FileChooserParams.MODE_OPEN_MULTIPLE) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }); true
                } catch (e: Exception) {
                    fileCallback = null; false
                }
            }
        }

        web.setDownloadListener { url, userAgent, contentDisposition, mimeType, _ ->
            startDownload(url, userAgent, contentDisposition, mimeType)
        }

        web.setOnLongClickListener { onLongPress() }

        web.onScrollDelta = { dy, y ->
            if (prefs.autoHideDock) {
                if (dy > 12 && y > dp(80)) setDockHidden(true)
                else if (dy < -12 || y < dp(20)) setDockHidden(false)
            }
        }
    }

    private fun setupControls() {
        b.swipe.setColorSchemeResources(R.color.brand, R.color.brand_2)
        b.swipe.setProgressBackgroundColorSchemeResource(R.color.glass_fill_strong)
        b.swipe.setOnChildScrollUpCallback { _, _ -> web.scrollY > 0 }
        b.swipe.setOnRefreshListener { reload() }

        b.btnReload.setOnClickListener { if (web.progress in 1..99 && !hadError) web.stopLoading() else reload() }
        b.btnRetry.setOnClickListener { reload() }
        b.btnBack.setOnClickListener { if (web.canGoBack()) web.goBack() }
        b.btnForward.setOnClickListener { if (web.canGoForward()) web.goForward() }
        b.btnHome.setOnClickListener { web.loadUrl(prefs.homeUrl) }
        b.btnDownloads.setOnClickListener { startActivity(Intent(this, DownloadsActivity::class.java)) }
        b.btnSettings.setOnClickListener { startActivity(Intent(this, SettingsActivity::class.java)) }
        b.btnMore.setOnClickListener { showMoreMenu(it) }
        b.titleBox.setOnClickListener { web.flingScroll(0, -100000); setDockHidden(false) }
        b.logo.setOnClickListener { web.loadUrl(prefs.homeUrl) }
        b.fabMedia.setOnClickListener { showQualitySheet() }
        updateNavButtons()
    }

    private fun setupBack() {
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                when {
                    customView != null -> exitFullscreen()
                    web.canGoBack() -> web.goBack()
                    System.currentTimeMillis() - lastBackPress < 2000 -> finish()
                    else -> {
                        lastBackPress = System.currentTimeMillis()
                        toast(getString(R.string.press_back_again))
                    }
                }
            }
        })
    }

    private fun applySettings() {
        b.swipe.isEnabled = prefs.pullRefresh
        if (!prefs.autoHideDock) setDockHidden(false)
        if (prefs.keepScreenOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        web.settings.textZoom = prefs.textZoom
        if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
            WebSettingsCompat.setAlgorithmicDarkeningAllowed(web.settings, prefs.forceDarkWeb)
        }
        setDesktopMode(prefs.desktopMode, reload = false)
        if (!prefs.detectMedia) { media = emptyList(); updateMediaFab() }
    }

    private fun setDesktopMode(on: Boolean, reload: Boolean) {
        val ua = if (on) mobileUa.replace(Regex("""\(Linux; Android[^)]*\)"""), "(X11; Linux x86_64)")
            .replace(" Mobile", "") else mobileUa
        val full = "$ua TopdownApp/${BuildConfig.VERSION_NAME}"
        if (web.settings.userAgentString != full) {
            web.settings.userAgentString = full
            if (reload) reload()
        }
    }

    private fun setLoadingUi(loading: Boolean) {
        b.progress.visibility = if (loading) View.VISIBLE else View.INVISIBLE
        b.btnReload.setIconResource(if (loading) R.drawable.ic_close else R.drawable.ic_reload)
        b.btnReload.contentDescription = getString(if (loading) R.string.stop else R.string.reload)
    }

    private fun updateNavButtons() {
        b.btnBack.isEnabled = web.canGoBack(); b.btnBack.alpha = if (web.canGoBack()) 1f else 0.35f
        b.btnForward.isEnabled = web.canGoForward(); b.btnForward.alpha = if (web.canGoForward()) 1f else 0.35f
    }

    private fun setDockHidden(hide: Boolean) {
        if (hide == dockHidden) return
        dockHidden = hide
        val dy = if (hide) (b.dock.height + dp(40)).toFloat() else 0f
        b.dock.animate().translationY(dy).setDuration(220).start()
        b.fabMedia.animate().translationY(if (hide) dy - dp(60) else 0f).setDuration(220).start()
    }

    private fun reload() {
        b.errorView.isVisible = false
        hadError = false
        if (web.url.isNullOrBlank() || web.url == "about:blank") web.loadUrl(prefs.homeUrl) else web.reload()
    }

    private fun showError(desc: String?) {
        hadError = true
        b.swipe.isRefreshing = false
        setLoadingUi(false)
        val offline = !isOnline()
        b.errorTitle.setText(if (offline) R.string.no_internet_title else R.string.error_title)
        b.errorMsg.text = if (offline) getString(R.string.no_internet_msg) else (desc ?: "")
        b.errorView.isVisible = true
        b.errorView.alpha = 0f
        b.errorView.animate().alpha(1f).setDuration(250).start()
        web.loadUrl("about:blank")
    }

    // ---------- الروابط ----------
    private fun isInternal(uri: Uri): Boolean {
        val h = uri.host?.removePrefix("www.") ?: return false
        return h == homeHost || h.endsWith(".$homeHost")
    }

    private fun handleUrl(uri: Uri, mainFrame: Boolean): Boolean {
        val scheme = uri.scheme?.lowercase() ?: return false
        if (scheme == "http" || scheme == "https") {
            if (!mainFrame || isInternal(uri) || !prefs.externalLinks) return false
            return openExternal(uri)
        }
        if (scheme == "intent") {
            val i = runCatching { Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME) }.getOrNull() ?: return true
            try { startActivity(i) } catch (e: Exception) {
                i.getStringExtra("browser_fallback_url")?.let { web.loadUrl(it) }
            }
            return true
        }
        if (scheme == "blob" || scheme == "data" || scheme == "about" || scheme == "javascript") return false
        openExternal(uri)
        return true
    }

    private fun openExternal(uri: Uri): Boolean = try {
        startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
    } catch (e: Exception) { false }

    private fun sharedUrl(i: Intent?): String? {
        if (i?.action != Intent.ACTION_SEND) return null
        val text = i.getStringExtra(Intent.EXTRA_TEXT) ?: return null
        return Regex("""https?://\S+""").find(text)?.value
    }

    private fun displayUrl(url: String?) = url?.removePrefix("https://")?.removePrefix("http://")?.removeSuffix("/") ?: ""

    // ---------- التحميل ----------
    private fun needsStoragePermission() =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED

    private fun withStorage(action: () -> Unit) {
        if (needsStoragePermission()) {
            pendingDownload = action
            storagePermission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        } else action()
    }

    private fun startDownload(url: String, userAgent: String?, cd: String?, mime: String?, name: String? = null) {
        when {
            url.startsWith("blob:") -> withStorage {
                web.evaluateJavascript(Scripts.blobFetcher(url, name ?: "topdown_${System.currentTimeMillis()}", mime ?: ""), null)
                snack(getString(R.string.download_started, name ?: "…"))
            }
            url.startsWith("data:") -> withStorage { saveDataUrl(url, name) }
            else -> withStorage {
                runCatching {
                    downloads.enqueue(url, userAgent ?: web.settings.userAgentString, cd, mime, web.url, prefs.wifiOnly, name)
                }.onSuccess { rec ->
                    snack(getString(R.string.download_started, rec.name) +
                        if (prefs.wifiOnly && !isOnWifi()) " — " + getString(R.string.wifi_waiting) else "")
                    main.removeCallbacks(badgeTicker); main.post(badgeTicker)
                }.onFailure { snack(getString(R.string.download_failed)) }
            }
        }
    }

    private fun saveDataUrl(url: String, name: String?) {
        runCatching {
            val header = url.substringBefore(',')
            val mime = header.removePrefix("data:").substringBefore(';').ifBlank { "application/octet-stream" }
            val payload = url.substringAfter(',')
            val bytes = if (header.contains(";base64")) android.util.Base64.decode(payload, android.util.Base64.DEFAULT)
            else Uri.decode(payload).toByteArray()
            val tmp = java.io.File(cacheDir, "data_${System.currentTimeMillis()}").apply { writeBytes(bytes) }
            saveLocalFile(tmp, name ?: "topdown_${System.currentTimeMillis()}", mime)
        }.onFailure { snack(getString(R.string.download_failed)) }
    }

    private fun saveLocalFile(f: java.io.File, name: String, mime: String) {
        Thread {
            val rec = runCatching { downloads.saveLocal(f, name, mime) }.getOrNull()
            main.post {
                if (rec != null) snackOpen(getString(R.string.download_saved, rec.name), rec)
                else snack(getString(R.string.download_failed))
            }
        }.start()
    }

    private fun refreshBadge(): Int {
        val n = runCatching { downloads.activeCount() }.getOrDefault(0)
        b.downloadBadge.isVisible = n > 0
        b.downloadBadge.text = n.toString()
        return n
    }

    // ---------- الوسائط واختيار الجودة ----------
    private fun onMediaFound(items: List<MediaItem>) {
        media = items
        updateMediaFab()
    }

    private fun updateMediaFab() {
        val show = media.isNotEmpty() && prefs.detectMedia
        if (show) {
            b.fabMedia.text = if (media.size > 1) "${getString(R.string.download_media)} (${media.size})" else getString(R.string.download_media)
            if (!b.fabMedia.isVisible) { b.fabMedia.isVisible = true; b.fabMedia.extend() }
            main.postDelayed({ if (b.fabMedia.isVisible) b.fabMedia.shrink() }, 3500)
        } else b.fabMedia.isVisible = false
    }

    private fun showQualitySheet() {
        if (media.isEmpty()) { toast(getString(R.string.no_media_found)); return }
        MediaItem.pick(media, prefs.quality)?.let { downloadMedia(it); return }

        val dialog = BottomSheetDialog(this)
        val v = LayoutInflater.from(this).inflate(R.layout.sheet_quality, null)
        v.findViewById<TextView>(R.id.sheetSubtitle).text = web.title
        val always = v.findViewById<MaterialCheckBox>(R.id.alwaysUse)
        always.isVisible = media.any { it.height > 0 }
        val list = v.findViewById<RecyclerView>(R.id.qualityList)
        list.layoutManager = LinearLayoutManager(this)
        list.adapter = QualityAdapter(media) { item ->
            if (always.isChecked && item.height > 0) prefs.quality = item.height.toString()
            dialog.dismiss()
            downloadMedia(item)
        }
        dialog.setContentView(v)
        dialog.show()
    }

    private fun downloadMedia(item: MediaItem) {
        val base = Downloads.sanitize((web.title ?: "topdown").take(60))
        val ext = item.extension().ifBlank { if (item.kind == "audio") "mp3" else "mp4" }
        val q = if (item.height > 0) "_${item.qualityLabel}" else ""
        startDownload(item.url, null, null, item.mime, "$base$q.$ext")
    }

    private class QualityAdapter(
        private val items: List<MediaItem>,
        private val onPick: (MediaItem) -> Unit,
    ) : RecyclerView.Adapter<QualityAdapter.VH>() {
        class VH(v: View) : RecyclerView.ViewHolder(v) {
            val badge: TextView = v.findViewById(R.id.qBadge)
            val title: TextView = v.findViewById(R.id.qTitle)
            val meta: TextView = v.findViewById(R.id.qMeta)
        }

        override fun onCreateViewHolder(p: ViewGroup, t: Int) =
            VH(LayoutInflater.from(p.context).inflate(R.layout.item_quality, p, false))

        override fun getItemCount() = items.size

        override fun onBindViewHolder(h: VH, pos: Int) {
            val it = items[pos]
            val ctx = h.itemView.context
            h.badge.text = it.qualityLabel
            h.title.text = when (it.kind) {
                "video" -> "فيديو" + if (it.height > 0) " • ${it.qualityLabel}" else ""
                "audio" -> "صوت"
                else -> it.label.ifBlank { ctx.getString(R.string.download) }
            }
            h.meta.text = it.label.takeIf { l -> l.isNotBlank() && it.kind != "file" }
                ?: Uri.parse(it.url).lastPathSegment ?: it.url
            h.itemView.setOnClickListener { _ -> onPick(it) }
        }
    }

    // ---------- الضغط المطوّل ----------
    private fun onLongPress(): Boolean {
        val hit = web.hitTestResult
        val extra = hit.extra ?: return false
        val isImage = hit.type == WebView.HitTestResult.IMAGE_TYPE || hit.type == WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE
        val isLink = hit.type == WebView.HitTestResult.SRC_ANCHOR_TYPE || hit.type == WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE
        if (!isImage && !isLink) return false

        val opts = mutableListOf<Pair<String, () -> Unit>>()
        opts += getString(R.string.download) to { startDownload(extra, null, null, null) }
        if (isLink) opts += getString(R.string.open_in_browser) to { openExternal(Uri.parse(extra)); Unit }
        opts += getString(R.string.copy_link) to { copy(extra) }
        opts += getString(R.string.share) to { shareText(extra) }

        MaterialAlertDialogBuilder(this)
            .setTitle(displayUrl(extra).take(80))
            .setItems(opts.map { it.first }.toTypedArray()) { _, i -> opts[i].second() }
            .show()
        return true
    }

    private fun showMoreMenu(anchor: View) {
        PopupMenu(this, anchor).apply {
            menu.add(0, 1, 0, R.string.share)
            menu.add(0, 2, 1, R.string.copy_link)
            menu.add(0, 3, 2, R.string.open_in_browser)
            menu.add(0, 4, 3, R.string.download_media)
            menu.add(0, 5, 4, R.string.desktop_mode).apply { isCheckable = true; isChecked = prefs.desktopMode }
            menu.add(0, 6, 5, R.string.downloads)
            menu.add(0, 7, 6, R.string.exit)
            setOnMenuItemClickListener {
                when (it.itemId) {
                    1 -> web.url?.let(::shareText)
                    2 -> web.url?.let(::copy)
                    3 -> web.url?.let { u -> openExternal(Uri.parse(u)) }
                    4 -> showQualitySheet()
                    5 -> { prefs.desktopMode = !prefs.desktopMode; setDesktopMode(prefs.desktopMode, reload = true) }
                    6 -> startActivity(Intent(this@MainActivity, DownloadsActivity::class.java))
                    7 -> finishAffinity()
                }
                true
            }
            show()
        }
    }

    // ---------- ملء الشاشة ----------
    private fun enterFullscreen(view: View, cb: WebChromeClient.CustomViewCallback) {
        if (customView != null) { cb.onCustomViewHidden(); return }
        customView = view; customViewCallback = cb
        b.fullscreen.addView(view, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        b.fullscreen.isVisible = true
        WindowInsetsControllerCompat(window, b.root).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun exitFullscreen() {
        val v = customView ?: return
        b.fullscreen.removeView(v)
        b.fullscreen.isVisible = false
        customView = null
        customViewCallback?.onCustomViewHidden(); customViewCallback = null
        WindowInsetsControllerCompat(window, b.root).show(WindowInsetsCompat.Type.systemBars())
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        if (!prefs.keepScreenOn) window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    // ---------- أدوات ----------
    private fun isOnline(): Boolean {
        val cm = getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun isOnWifi(): Boolean {
        val cm = getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)
    }

    private fun copy(text: String) {
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("url", text))
        toast(getString(R.string.link_copied))
    }

    private fun shareText(text: String) {
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
    }

    private fun snack(msg: String) = Snackbar.make(b.root, msg, Snackbar.LENGTH_SHORT).setAnchorView(b.dock).show()

    private fun snackOpen(msg: String, rec: DownloadRecord) {
        Snackbar.make(b.root, msg, Snackbar.LENGTH_LONG).setAnchorView(b.dock)
            .setAction(R.string.open) {
                val i = downloads.openIntent(rec)
                if (i == null || runCatching { startActivity(i) }.isFailure) toast(getString(R.string.no_app_to_open))
            }.show()
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
}
