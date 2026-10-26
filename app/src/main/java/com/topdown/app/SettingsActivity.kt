package com.topdown.app

import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebStorage
import android.webkit.WebView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.preference.ListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceFragmentCompat
import com.topdown.app.databinding.ActivitySettingsBinding

class SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val b = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(b.root)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        ViewCompat.setOnApplyWindowInsetsListener(b.root) { v, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            v.updatePadding(top = bars.top, bottom = bars.bottom, left = bars.left, right = bars.right)
            insets
        }
        b.btnClose.setOnClickListener { finish() }
        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction().replace(R.id.settingsContainer, SettingsFragment()).commit()
        }
    }

    class SettingsFragment : PreferenceFragmentCompat() {
        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            setPreferencesFromResource(R.xml.preferences, rootKey)

            findPreference<ListPreference>("theme")?.setOnPreferenceChangeListener { _, v ->
                TopdownApp.applyTheme(v as String); true
            }
            findPreference<Preference>("clear_cache")?.setOnPreferenceClickListener {
                WebView(requireContext()).apply { clearCache(true); destroy() }
                requireContext().cacheDir.listFiles()?.forEach { it.deleteRecursively() }
                toast(getString(R.string.cleared)); true
            }
            findPreference<Preference>("clear_cookies")?.setOnPreferenceClickListener {
                CookieManager.getInstance().removeAllCookies(null)
                CookieManager.getInstance().flush()
                WebStorage.getInstance().deleteAllData()
                toast(getString(R.string.cleared)); true
            }
            findPreference<Preference>("version")?.summary = "${BuildConfig.VERSION_NAME} • ${BuildConfig.HOME_URL}"
        }

        private fun toast(m: String) = Toast.makeText(requireContext(), m, Toast.LENGTH_SHORT).show()
    }
}
