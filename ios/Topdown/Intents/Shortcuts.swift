import AppIntents

struct OpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "فتح تحميلات Topdown"
    static let description = IntentDescription("يفتح المحتوى المحمّل للمشاهدة والقراءة بدون إنترنت.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.tab = .library
        return .result()
    }
}

struct OpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "البحث في Topdown"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.tab = .search
        return .result()
    }
}

struct TopdownShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenLibraryIntent(),
                    phrases: ["افتح مكتبة \(.applicationName)", "Open \(.applicationName) library"],
                    shortTitle: "المكتبة", systemImageName: "square.stack.fill")
        AppShortcut(intent: OpenDownloadsIntent(),
                    phrases: ["ابحث في \(.applicationName)", "Search \(.applicationName)"],
                    shortTitle: "البحث", systemImageName: "magnifyingglass")
    }
}
