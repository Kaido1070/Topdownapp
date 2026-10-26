import Foundation
import WebKit

/// يمرّر كوكيز جلسة الموقع (td_session) لطلبات التحميل الأصلية.
enum WebSession {
    @MainActor
    static func cookies() async -> [HTTPCookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies()
    }

    @MainActor
    static func request(_ url: URL, referer: String? = nil) async -> URLRequest {
        var r = URLRequest(url: url)
        let jar = await cookies().filter { c in
            guard let host = url.host() else { return false }
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return host == d || host.hasSuffix("." + d)
        }
        for (k, v) in HTTPCookie.requestHeaderFields(with: jar) { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { r.setValue(referer, forHTTPHeaderField: "Referer") }
        return r
    }

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 TopdownApp/1.0"

    /// يحوّل مسارًا نسبيًا للموقع إلى رابط كامل.
    static func absolute(_ s: String) -> URL? {
        if s.hasPrefix("http") { return URL(string: s) }
        return URL(string: s, relativeTo: Site.home)?.absoluteURL
    }
}

enum Site {
    static let home = URL(string: "https://topdownn.pages.dev/")!
}
