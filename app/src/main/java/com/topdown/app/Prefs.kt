package com.topdown.app

import android.content.Context
import androidx.preference.PreferenceManager

/** وصول موحّد لإعدادات التطبيق. */
class Prefs(context: Context) {
    private val sp = PreferenceManager.getDefaultSharedPreferences(context.applicationContext)

    val homeUrl: String get() = BuildConfig.HOME_URL

    var quality: String
        get() = sp.getString("quality", "ask") ?: "ask"
        set(value) = sp.edit().putString("quality", value).apply()

    val wifiOnly get() = sp.getBoolean("wifi_only", false)
    val detectMedia get() = sp.getBoolean("detect_media", true)
    val pullRefresh get() = sp.getBoolean("pull_refresh", true)
    val autoHideDock get() = sp.getBoolean("auto_hide_dock", true)
    val externalLinks get() = sp.getBoolean("external_links", true)
    val keepScreenOn get() = sp.getBoolean("keep_screen_on", false)
    val forceDarkWeb get() = sp.getBoolean("force_dark_web", false)
    val textZoom get() = sp.getInt("text_zoom", 100)
    val theme get() = sp.getString("theme", "system") ?: "system"

    var desktopMode: Boolean
        get() = sp.getBoolean("desktop_mode", false)
        set(value) = sp.edit().putBoolean("desktop_mode", value).apply()

    var lastUrl: String?
        get() = sp.getString("last_url", null)
        set(value) = sp.edit().putString("last_url", value).apply()
}
