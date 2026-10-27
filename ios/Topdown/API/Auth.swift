import SwiftUI

@MainActor
@Observable
final class Auth {
    static let shared = Auth()

    enum State { case checking, signedOut, signedIn }
    var state: State = .checking

    private init() {}

    func bootstrap() async {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let pw = defaults.string(forKey: "smokePassword"), !pw.isEmpty, Keychain.password == nil {
            try? await API.shared.login(password: pw)
        }
        switch defaults.string(forKey: "smokeTab") {
        case "stories": AppModel.shared.mode = .stories
        case "account": AppModel.shared.tab = .account
        case "reader":
            Task {
                guard let page = try? await API.shared.stories(page: 1, q: "", genre: "", source: .legacy),
                      let first = page.items.values.first,
                      let detail = try? await API.shared.story(first.url) else { return }
                let chapters = detail.chapters.values.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
                guard let c = chapters.first else { return }
                AppModel.shared.reader = ReaderRequest(story: first, chapters: chapters, url: c.url)
            }
        case "tabHop":
            // تبديل سريع بين التبويبات أثناء تحميل القصص (يحاكي استخدامًا حقيقيًا)
            Task {
                try? await Task.sleep(for: .seconds(6))
                AppModel.shared.mode = .stories
                try? await Task.sleep(for: .milliseconds(150))
                AppModel.shared.tab = .library
                try? await Task.sleep(for: .milliseconds(300))
                AppModel.shared.tab = .explore
                try? await Task.sleep(for: .milliseconds(200))
                AppModel.shared.mode = .anime
                try? await Task.sleep(for: .milliseconds(200))
                AppModel.shared.mode = .stories
            }
        case "switchStories":
            Task { try? await Task.sleep(for: .seconds(8)); withAnimation(.smooth) { AppModel.shared.mode = .stories } }
        default: break
        }
        #endif
        // بدون إنترنت: إذا كانت هناك جلسة محفوظة ندخل مباشرة (المكتبة تعمل بدون اتصال)
        if !AppModel.shared.isOnline {
            state = (API.shared.hasSessionCookie || Keychain.password != nil) ? .signedIn : .signedOut
            return
        }
        switch await API.shared.sessionStatus() {
        case .valid:
            state = .signedIn
            await Library.shared.refresh()
        case .invalid:
            state = .signedOut
        case .unreachable:
            state = (API.shared.hasSessionCookie || Keychain.password != nil) ? .signedIn : .signedOut
            if state == .signedIn { AppModel.shared.tab = .library }
        }
    }

    func login(_ password: String) async throws {
        try await API.shared.login(password: password)
        withAnimation(.smooth) { state = .signedIn }
        await Library.shared.refresh()
    }

    func logout() async {
        await API.shared.logout()
        Library.shared.reset()
        withAnimation(.smooth) { state = .signedOut }
    }

    func sessionExpired() {
        if Keychain.password == nil { state = .signedOut }
    }
}

/// المفضلة والسجل على الخادم (نفس بيانات الموقع).
@MainActor
@Observable
final class Library {
    static let shared = Library()

    var favorites: [MediaItem] = []
    var history: [MediaItem] = []
    var savedStories: [StoryItem] = []
    var storyHistory: [StoryItem] = []
    var loading = false
    var error: String?

    var favoriteKeys: Set<String> { Set(favorites.map(\.key)) }
    var savedStoryURLs: Set<String> { Set(savedStories.map(\.url)) }

    private init() {}

    func reset() { favorites = []; history = []; savedStories = []; storyHistory = [] }

    func refresh() async {
        loading = true
        error = nil
        async let f = API.shared.favorites()
        async let h = API.shared.history()
        async let s = API.shared.savedStories()
        async let sh = API.shared.storyHistory()
        do { favorites = try await f } catch { self.error = error.localizedDescription }
        do { history = try await h } catch { self.error = error.localizedDescription }
        if let v = try? await s { savedStories = v }
        if let v = try? await sh { storyHistory = v }
        loading = false
    }

    func isFavorite(_ x: MediaItem) -> Bool { favoriteKeys.contains(x.key) }

    func toggleFavorite(_ x: MediaItem) {
        Haptics.tap()
        if isFavorite(x) {
            favorites.removeAll { $0.key == x.key }
            Task { try? await API.shared.removeFavorite(x) }
        } else {
            var y = x; y.createdAt = Date.now.timeIntervalSince1970 * 1000
            favorites.insert(y, at: 0)
            Task { try? await API.shared.addFavorite(x) }
        }
    }

    func recordWatch(_ x: MediaItem) {
        var y = x; y.watchedAt = Date.now.timeIntervalSince1970 * 1000
        history.removeAll { $0.key == x.key }
        history.insert(y, at: 0)
        Task { try? await API.shared.recordHistory(x) }
    }

    func removeHistory(_ x: MediaItem) {
        history.removeAll { $0.key == x.key }
        Task { try? await API.shared.removeHistory(x) }
    }

    func clearHistory() {
        history = []
        Task { try? await API.shared.clearHistory() }
    }

    func isSaved(_ s: StoryItem) -> Bool { savedStoryURLs.contains(s.url) }

    func toggleSaved(_ s: StoryItem) {
        Haptics.tap()
        if isSaved(s) {
            savedStories.removeAll { $0.url == s.url }
            Task { try? await API.shared.unsaveStory(s) }
        } else {
            var y = s.payload; y.createdAt = Date.now.timeIntervalSince1970 * 1000
            savedStories.insert(y, at: 0)
            Task { try? await API.shared.saveStory(s) }
        }
    }

    func recordRead(_ s: StoryItem, chapter: ChapterLink) {
        var y = s.payload
        y.lastChapterUrl = chapter.url
        y.lastChapterTitle = chapter.title.isEmpty ? chapter.displayTitle : chapter.title
        y.watchedAt = Date.now.timeIntervalSince1970 * 1000
        storyHistory.removeAll { $0.url == s.url }
        storyHistory.insert(y, at: 0)
        Task { try? await API.shared.recordStory(s, chapter: chapter) }
    }

    func removeStoryHistory(_ s: StoryItem) {
        storyHistory.removeAll { $0.url == s.url }
        Task { try? await API.shared.removeStoryHistory(s) }
    }

    func clearStoryHistory() {
        storyHistory = []
        Task { try? await API.shared.clearStoryHistory() }
    }
}
