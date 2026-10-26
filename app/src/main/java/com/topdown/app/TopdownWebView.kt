package com.topdown.app

import android.content.Context
import android.util.AttributeSet
import android.webkit.WebView

/** WebView يُبلغ عن اتجاه التمرير لإخفاء/إظهار الشريط الزجاجي. */
class TopdownWebView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : WebView(context, attrs) {

    var onScrollDelta: ((dy: Int, y: Int) -> Unit)? = null

    override fun onScrollChanged(l: Int, t: Int, oldl: Int, oldt: Int) {
        super.onScrollChanged(l, t, oldl, oldt)
        onScrollDelta?.invoke(t - oldt, t)
    }
}
