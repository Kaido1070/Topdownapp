import Foundation
import Security
import AVFoundation

enum Site {
    static let home: URL = {
        #if DEBUG
        // اختبار المحاكي في CI يشغّل نسخة محلية من خادم الموقع
        if let s = UserDefaults.standard.string(forKey: "smokeBaseURL"), let u = URL(string: s) { return u }
        #endif
        return URL(string: "https://topdownn.pages.dev/")!
    }()
    static let imageRev = "4"
    static let mangaPageRev = "5"

    static func url(_ pathOrURL: String) -> URL? {
        if pathOrURL.hasPrefix("http") { return URL(string: pathOrURL) }
        return URL(string: pathOrURL, relativeTo: home)?.absoluteURL
    }

    static func url(_ path: String, _ query: [String: String]) -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var s = home.absoluteString + clean
        if !query.isEmpty {
            s += "?" + query.sorted { $0.key < $1.key }.map { k, v in
                k + "=" + (v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }.joined(separator: "&")
        }
        return URL(string: s) ?? home
    }

    static func videoThumb(_ raw: String?) -> [URL] {
        guard let raw, !raw.isEmpty else { return [] }
        return [url("/api/video-thumb", ["u": raw, "v": imageRev])] + (url(raw).map { [$0] } ?? [])
    }

    static func mangaThumb(_ raw: String?, ref: String) -> [URL] {
        guard let raw, !raw.isEmpty else { return [] }
        return [url("/api/manga-thumb", ["u": raw, "r": ref, "v": imageRev])] + (url(raw).map { [$0] } ?? [])
    }

    /// نفس ترتيب الموقع: الصورة الأصلية ثم بروكسي /api/manga-image مرتين.
    static func mangaPage(_ raw: String, chapter: String) -> [URL] {
        var out: [URL] = []
        if let direct = url(raw) { out.append(direct) }
        for attempt in 0..<2 {
            out.append(url("/api/manga-image", ["u": raw, "r": chapter, "v": mangaPageRev, "retry": String(attempt)]))
        }
        return out
    }
}

enum APIError: LocalizedError {
    case unauthorized
    case server(String)
    case offline

    var errorDescription: String? {
        switch self {
        case .unauthorized: "انتهت الجلسة، سجّل الدخول من جديد"
        case .server(let m): m
        case .offline: "لا يوجد اتصال بالإنترنت"
        }
    }
}

/// عميل واجهة الموقع.
/// كوكي الجلسة td_session من نوع SameSite=Strict، وiOS لا يرسل هذا النوع تلقائيًا
/// مع طلبات URLSession العادية، فكانت كل الطلبات بعد الدخول ترجع 401.
/// لذلك نحفظ رمز الجلسة بأنفسنا في Keychain ونرفقه صراحةً في ترويسة Cookie لكل طلب.
final class API: @unchecked Sendable {
    static let shared = API()

    let session: URLSession
    private let decoder = JSONDecoder()
    private let reloginLock = NSLock()
    private var reloginTask: Task<Bool, Never>?

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        // فهرس القصص في الخادم قد يستغرق وقتًا عند أول طلب، والموقع ينتظره بلا حد
        config.timeoutIntervalForRequest = 100
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": API.userAgent, "Accept": "application/json, */*"]
        session = URLSession(configuration: config)
    }

    static let userAgent = "TopdownApp/1.0 (iPhone; iOS) Mozilla/5.0 AppleWebKit/605.1.15 Mobile/15E148"

    var hasSessionCookie: Bool { Keychain.sessionToken != nil }

    /// ترويسة الكوكي لروابط الموقع فقط (لا نرسل الجلسة لمواقع أخرى).
    func cookieHeader(for url: URL) -> [String: String] {
        guard url.host() == Site.home.host(), let token = Keychain.sessionToken else { return [:] }
        return ["Cookie": "td_session=" + token]
    }

    /// طلب جاهز يحمل الجلسة.
    func authorized(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        for (k, v) in cookieHeader(for: url) { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue(API.userAgent, forHTTPHeaderField: "User-Agent")
        r.mainDocumentURL = Site.home
        return r
    }

    var sessionCookies: [HTTPCookie] {
        guard let token = Keychain.sessionToken, let host = Site.home.host(),
              let c = HTTPCookie(properties: [.name: "td_session", .value: token, .domain: host, .path: "/", .secure: "TRUE"])
        else { return [] }
        return [c]
    }

    /// خيارات AVURLAsset لتشغيل روابط /api/stream المحمية.
    func assetOptions(for url: URL) -> [String: Any] {
        var o: [String: Any] = [AVURLAssetHTTPCookiesKey: sessionCookies]
        let h = cookieHeader(for: url)
        if !h.isEmpty { o["AVURLAssetHTTPHeaderFieldsKey"] = h }
        return o
    }

    // MARK: - المصادقة

    enum SessionStatus { case valid, invalid, unreachable }

    func sessionStatus() async -> SessionStatus {
        struct S: Decodable { let authenticated: Bool }
        do {
            let s: S = try await get("/api/session", retry: false)
            if s.authenticated { return .valid }
        } catch APIError.server, APIError.unauthorized {
            // نكمل لمحاولة الدخول الصامت
        } catch {
            return .unreachable
        }
        return await silentRelogin() ? .valid : .invalid
    }

    func login(password: String) async throws {
        struct Body: Encodable { let password: String }
        var req = URLRequest(url: Site.url("/api/login", [:]))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Body(password: password))
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw APIError.offline }
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard code == 200 else {
            throw code == 401 ? APIError.server("كلمة المرور غير صحيحة") : APIError.server(message(data) ?? "تعذّر تسجيل الدخول (\(code))")
        }
        guard let token = Self.sessionToken(from: http) else {
            throw APIError.server("الخادم لم يُرجع جلسة دخول")
        }
        Keychain.sessionToken = token
        Keychain.password = password
    }

    func logout() async {
        _ = try? await send("POST", "/api/logout", retry: false)
        Keychain.password = nil
        Keychain.sessionToken = nil
    }

    /// يستخرج قيمة td_session من ترويسة Set-Cookie كما هي (مُرمّزة) لإعادتها للخادم.
    static func sessionToken(from response: HTTPURLResponse?) -> String? {
        guard let response else { return nil }
        var headers: [String] = []
        for (k, v) in response.allHeaderFields {
            if let key = k as? String, key.lowercased() == "set-cookie", let value = v as? String { headers.append(value) }
        }
        for h in headers {
            if let r = h.range(of: "td_session=") {
                let value = h[r.upperBound...].prefix { $0 != ";" }
                if !value.isEmpty { return String(value) }
            }
        }
        if let url = response.url {
            let fields = response.allHeaderFields.reduce(into: [String: String]()) { d, kv in
                if let k = kv.key as? String, let v = kv.value as? String { d[k] = v }
            }
            return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).first { $0.name == "td_session" }?.value
        }
        return nil
    }

    /// إعادة دخول صامتة بكلمة المرور المحفوظة عند انتهاء الجلسة.
    private func silentRelogin() async -> Bool {
        guard let password = Keychain.password else { return false }
        let task: Task<Bool, Never> = reloginLock.withLock {
            if let existing = reloginTask { return existing }
            let t = Task { (try? await self.login(password: password)) != nil }
            reloginTask = t
            return t
        }
        let ok = await task.value
        reloginLock.withLock { reloginTask = nil }
        return ok
    }

    // MARK: - الطلبات

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], retry: Bool = true) async throws -> T {
        let data = try await perform(method: "GET", url: Site.url(path, query), body: nil, retry: retry)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.server("استجابة غير متوقعة من الخادم") }
    }

    func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        let data = try await perform(method: "POST", url: Site.url(path, [:]), body: try JSONEncoder().encode(body), retry: true)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.server("استجابة غير متوقعة من الخادم") }
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: (some Encodable)? = nil as String?, retry: Bool = true) async throws -> Data {
        try await perform(method: method, url: Site.url(path, [:]), body: try body.map { try JSONEncoder().encode($0) }, retry: retry)
    }

    private func perform(method: String, url: URL, body: Data?, retry: Bool) async throws -> Data {
        var req = authorized(url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                                         .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                         .internationalRoamingOff].contains(e.code) {
            throw APIError.offline
        } catch let e as URLError where e.code == .timedOut {
            throw APIError.server("الخادم تأخر في الرد، حاول مرة ثانية")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            if retry, await silentRelogin() { return try await perform(method: method, url: url, body: body, retry: false) }
            await MainActor.run { Auth.shared.sessionExpired() }
            throw APIError.unauthorized
        }
        guard (200..<300).contains(code) else { throw APIError.server(message(data) ?? "خطأ من الخادم (\(code))") }
        return data
    }

    private func message(_ data: Data) -> String? {
        struct E: Decodable { let error: String?; let message: String? }
        guard let e = try? decoder.decode(E.self, from: data) else { return nil }
        return e.error ?? e.message
    }

    // MARK: - نقاط الواجهة

    func home(page: Int, sort: String, tag: String = "") async throws -> VideoPage {
        try await get("/api/home", ["page": String(page), "sort": sort, "tag": tag])
    }

    func providerCatalog(_ id: String, page: Int, q: String) async throws -> VideoPage {
        try await get("/api/provider/\(id)/catalog", ["page": String(page), "q": q])
    }

    func search(_ q: String, page: Int) async throws -> VideoPage {
        try await get("/api/search", ["q": q, "page": String(page), "provider": "hentaitime"])
    }

    func details(_ item: MediaItem) async throws -> WorkDetails {
        try await get("/api/provider/\(item.providerId)/details", ["id": item.id])
    }

    func resolve(_ item: MediaItem) async throws -> Resolved {
        try await post("/api/resolve", body: item.payload)
    }

    func related(_ item: MediaItem) async throws -> [MediaItem] {
        let r: ItemsResponse<MediaItem> = try await get("/api/related", ["title": item.title, "id": item.id])
        return r.items.values
    }

    func videoTags() async throws -> [Tag] {
        let r: TagsResponse = try await get("/api/video/tags")
        return r.tags ?? []
    }

    func favorites() async throws -> [MediaItem] { (try await get("/api/favorites") as ItemsResponse<MediaItem>).items.values }
    func history() async throws -> [MediaItem] { (try await get("/api/history") as ItemsResponse<MediaItem>).items.values }
    func addFavorite(_ x: MediaItem) async throws { try await send("POST", "/api/favorites", body: x.payload) }
    func removeFavorite(_ x: MediaItem) async throws {
        try await send("DELETE", "/api/favorites/\(enc(x.providerId))/\(enc(x.id))")
    }
    func recordHistory(_ x: MediaItem) async throws { try await send("POST", "/api/history", body: x.payload) }
    func removeHistory(_ x: MediaItem) async throws {
        try await send("DELETE", "/api/history/\(enc(x.providerId))/\(enc(x.id))")
    }
    func clearHistory() async throws { try await send("DELETE", "/api/history/clear") }

    func stories(page: Int, q: String, genre: String, source: StorySource) async throws -> StoryPage {
        try await get("/api/stories", ["page": String(page), "q": q, "genre": source == .legacy ? genre : "", "source": source.rawValue])
    }
    func storyGenres() async throws -> [Tag] { (try await get("/api/story/genres") as GenresResponse).genres ?? [] }
    func story(_ url: String) async throws -> StoryDetail { try await get("/api/story", ["url": url]) }
    func chapter(_ url: String) async throws -> StoryChapter { try await get("/api/story/chapter", ["url": url]) }
    func savedStories() async throws -> [StoryItem] { (try await get("/api/story/saved") as ItemsResponse<StoryItem>).items.values }
    func storyHistory() async throws -> [StoryItem] { (try await get("/api/story/history") as ItemsResponse<StoryItem>).items.values }
    func saveStory(_ x: StoryItem) async throws { try await send("POST", "/api/story/saved", body: x.payload) }
    func unsaveStory(_ x: StoryItem) async throws {
        struct B: Encodable { let url: String }
        try await send("POST", "/api/story/saved/remove", body: B(url: x.url))
    }
    func recordStory(_ x: StoryItem, chapter: ChapterLink?) async throws {
        struct B: Encodable { let title: String; let url: String; let cover: String?; let latestChapter: Double?; let lastChapterUrl: String?; let lastChapterTitle: String? }
        try await send("POST", "/api/story/history", body: B(title: x.title, url: x.url, cover: x.cover, latestChapter: x.latestChapter,
                                                             lastChapterUrl: chapter?.url, lastChapterTitle: chapter?.title))
    }
    func removeStoryHistory(_ x: StoryItem) async throws {
        struct B: Encodable { let url: String }
        try await send("POST", "/api/story/history/remove", body: B(url: x.url))
    }
    func clearStoryHistory() async throws { try await send("POST", "/api/story/history/clear") }

    func sourceDirectory() async throws -> [DirectorySource] {
        struct R: Decodable { let sources: Lossy<DirectorySource> }
        return (try await get("/api/source-directory") as R).sources.values
    }
    func sourceHealth(_ id: String) async throws -> SourceCheck? {
        struct R: Decodable { let checks: Lossy<SourceCheck>? }
        return (try await get("/api/source-health", ["id": id]) as R).checks?.values.first
    }

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
}

enum Keychain {
    private static let service = "com.topdown.app"

    static var password: String? {
        get { read("site-password") }
        set { write("site-password", newValue) }
    }

    /// قيمة كوكي td_session (صالحة 30 يومًا، وتتجدد تلقائيًا بكلمة المرور).
    static var sessionToken: String? {
        get { read("session-token") }
        set { write("session-token", newValue) }
    }

    // نسخة في الذاكرة + بديل في UserDefaults إذا رفض Keychain الحفظ
    // (يحدث مع بعض أدوات إعادة التوقيع ومع المحاكي بدون توقيع).
    private static var memory: [String: String] = [:]
    private static let lock = NSLock()

    private static func read(_ account: String) -> String? {
        if let v = lock.withLock({ memory[account] }) { return v }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        var value: String?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            value = String(data: d, encoding: .utf8)
        } else {
            value = UserDefaults.standard.string(forKey: "kc." + account)
        }
        if let value { lock.withLock { memory[account] = value } }
        return value
    }

    private static func write(_ account: String, _ value: String?) {
        lock.withLock { memory[account] = value }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else {
            UserDefaults.standard.removeObject(forKey: "kc." + account)
            return
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: "kc." + account)
        } else {
            UserDefaults.standard.set(value, forKey: "kc." + account)
        }
    }
}
