import AppIntents

struct OpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "فتح التحميلات"
    static let description = IntentDescription("يفتح الفيديوهات المحفوظة.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.tab = .library
        return .result()
    }
}

struct OpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "تنزيل من رابط"
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
                    phrases: ["افتح تحميلات \(.applicationName)", "Open \(.applicationName) downloads"],
                    shortTitle: "التحميلات", systemImageName: "arrow.down.circle")
        AppShortcut(intent: OpenDownloadsIntent(),
                    phrases: ["نزّل فيديو في \(.applicationName)", "Download with \(.applicationName)"],
                    shortTitle: "تنزيل", systemImageName: "link")
    }
}
