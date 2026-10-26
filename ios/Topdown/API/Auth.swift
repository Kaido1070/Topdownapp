import SwiftUI

@MainActor
@Observable
final class Auth {
    static let shared = Auth()

    enum State { case checking, signedOut, signedIn }
    var state: State = .checking

    private init() {}

    func bootstrap() async {
        // بدون إنترنت: إذا كانت هناك جلسة محفوظة ندخل مباشرة (المكتبة تعمل بدون اتصال)
        if !AppModel.shared.isOnline {
            state = (API.shared.hasSessionCookie || Keychain.password != nil) ? .signedIn : .signedOut
            return
        }
        state = await API.shared.checkSession() ? .signedIn : .signedOut
        if state == .signedIn { await Library.shared.refresh() }
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
