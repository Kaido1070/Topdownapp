package com.topdown.app

import org.json.JSONArray
import java.util.Locale

/** وسيط مكتشف في الصفحة مع جودته المستنتجة. */
data class MediaItem(
    val url: String,
    val label: String,
    val kind: String, // video | audio | file
    val height: Int,  // 0 = غير معروف
    val mime: String?,
) {
    val qualityLabel: String
        get() = when {
            height >= 2160 -> "4K"
            height >= 1440 -> "2K"
            height > 0 -> "${height}p"
            kind == "audio" -> "MP3"
            else -> extension().uppercase(Locale.ROOT).ifEmpty { "FILE" }
        }

    fun extension(): String =
        url.substringBefore('?').substringBefore('#').substringAfterLast('/', "")
            .substringAfterLast('.', "").take(5)

    companion object {
        private val pRegex = Regex("""(?<!\d)(2160|1440|1080|720|540|480|360|240|144)\s*[pP]""")
        private val resRegex = Regex("""(?<!\d)\d{3,4}\s*[xX×]\s*(\d{3,4})(?!\d)""")

        fun guessHeight(vararg hints: String?): Int {
            for (h in hints) {
                if (h.isNullOrBlank()) continue
                pRegex.find(h)?.let { return it.groupValues[1].toInt() }
                resRegex.find(h)?.let { return it.groupValues[1].toInt() }
                val l = h.lowercase(Locale.ROOT)
                when {
                    "4k" in l || "uhd" in l -> return 2160
                    "fhd" in l || "full hd" in l || "fullhd" in l -> return 1080
                    Regex("""\bhd\b""").containsMatchIn(l) -> return 720
                    Regex("""\bsd\b""").containsMatchIn(l) -> return 480
                }
                // صيغ مثل ...?quality=720 أو _720.mp4
                Regex("""(?:quality|res|q)[=_-]?(2160|1440|1080|720|480|360|240)""").find(l)
                    ?.let { return it.groupValues[1].toInt() }
                Regex("""[_\-/](2160|1440|1080|720|480|360|240)[_\-.]""").find(l)
                    ?.let { return it.groupValues[1].toInt() }
            }
            return 0
        }

        fun parse(json: String): List<MediaItem> {
            val arr = runCatching { JSONArray(json) }.getOrNull() ?: return emptyList()
            val out = LinkedHashMap<String, MediaItem>()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val url = o.optString("url")
                if (!url.startsWith("http")) continue
                val label = o.optString("label").trim()
                val explicit = o.optInt("height", 0)
                val h = if (explicit > 0) explicit else guessHeight(label, o.optString("q"), url)
                val item = MediaItem(
                    url = url,
                    label = label,
                    // رابط ملف يحمل وسم جودة (مثل "تحميل 720p") هو فيديو غالبًا
                    kind = o.optString("kind", "file").let { k -> if (k == "file" && h > 0) "video" else k },
                    height = h,
                    mime = o.optString("mime").ifBlank { null },
                )
                val prev = out[url]
                if (prev == null || (prev.height == 0 && h > 0) || (prev.label.isBlank() && label.isNotBlank())) {
                    out[url] = item
                }
            }
            return out.values.sortedWith(
                compareBy<MediaItem> { kindOrder(it.kind) }.thenByDescending { it.height }
            )
        }

        private fun kindOrder(k: String) = when (k) { "video" -> 0; "audio" -> 1; else -> 2 }

        /** يختار العنصر الأنسب حسب الجودة المفضلة، أو null إذا كان الإعداد "اسأل". */
        fun pick(items: List<MediaItem>, pref: String): MediaItem? {
            if (items.isEmpty() || pref == "ask") return null
            if (items.size == 1) return items.first()
            val videos = items.filter { it.kind == "video" }.ifEmpty { items }
            return when (pref) {
                "best" -> videos.maxByOrNull { it.height }
                "smallest" -> videos.filter { it.height > 0 }.minByOrNull { it.height } ?: videos.last()
                else -> {
                    val target = pref.toIntOrNull() ?: return null
                    val known = videos.filter { it.height > 0 }
                    if (known.isEmpty()) return null
                    known.filter { it.height <= target }.maxByOrNull { it.height }
                        ?: known.minByOrNull { it.height }
                }
            }
        }
    }
}
