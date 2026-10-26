import Foundation
import Security

enum Site {
    static let home = URL(string: "https://topdownn.pages.dev/")!
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

/// عميل واجهة الموقع. الكوكيز (td_session) تُحفظ تلقائيًا في HTTPCookieStorage
/// وكلمة المرور في Keychain، فتسجيل الدخول مرة واحدة فقط.
final class API: @unchecked Sendable {
    static let shared = API()

    let session: URLSession
    private let decoder = JSONDecoder()
    private let reloginLock = NSLock()
    private var reloginTask: Task<Bool, Never>?

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": API.userAgent, "Accept": "application/json, */*"]
        session = URLSession(configuration: config)
    }

    static let userAgent = "TopdownApp/1.0 (iPhone; iOS) Mozilla/5.0 AppleWebKit/605.1.15 Mobile/15E148"

    var hasSessionCookie: Bool {
        (HTTPCookieStorage.shared.cookies(for: Site.home) ?? []).contains { $0.name == "td_session" && ($0.expiresDate ?? .distantFuture) > .now }
    }

    func cookieHeader(for url: URL) -> [String: String] {
        HTTPCookie.requestHeaderFields(with: HTTPCookieStorage.shared.cookies(for: url) ?? [])
    }

    var sessionCookies: [HTTPCookie] { HTTPCookieStorage.shared.cookies(for: Site.home) ?? [] }

    // MARK: - المصادقة

    func checkSession() async -> Bool {
        struct S: Decodable { let authenticated: Bool }
        if let s: S = try? await get("/api/session", retry: false), s.authenticated { return true }
        return await silentRelogin()
    }

    func login(password: String) async throws {
        struct Body: Encodable { let password: String }
        var req = URLRequest(url: Site.url("/api/login", [:]))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Body(password: password))
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw code == 401 ? APIError.server("كلمة المرور غير صحيحة") : APIError.server(message(data) ?? "تعذّر تسجيل الدخول (\(code))")
        }
        Keychain.password = password
    }

    func logout() async {
        _ = try? await send("POST", "/api/logout", retry: false)
        Keychain.password = nil
        for c in sessionCookies { HTTPCookieStorage.shared.deleteCookie(c) }
    }

    /// إعادة دخول صامتة بكلمة المرور المحفوظة عند انتهاء الجلسة.
    private func silentRelogin() async -> Bool {
        guard let password = Keychain.password else { return false }
        reloginLock.lock()
        let task: Task<Bool, Never>
        if let existing = reloginTask {
            task = existing
        } else {
            task = Task { (try? await self.login(password: password)) != nil }
            reloginTask = task
        }
        reloginLock.unlock()
        let ok = await task.value
        reloginLock.lock(); reloginTask = nil; reloginLock.unlock()
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
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(e.code) {
            throw APIError.offline
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
    private static let account = "site-password"

    static var password: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard let newValue, let data = newValue.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
