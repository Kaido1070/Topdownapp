package com.topdown.app

import android.app.Application
import androidx.appcompat.app.AppCompatDelegate

class TopdownApp : Application() {
    override fun onCreate() {
        super.onCreate()
        applyTheme(Prefs(this).theme)
    }

    companion object {
        fun applyTheme(theme: String) {
            AppCompatDelegate.setDefaultNightMode(
                when (theme) {
                    "light" -> AppCompatDelegate.MODE_NIGHT_NO
                    "dark" -> AppCompatDelegate.MODE_NIGHT_YES
                    else -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
                }
            )
        }
    }
}
