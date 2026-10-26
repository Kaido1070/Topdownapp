import AppIntents

struct OpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "فتح مكتبة Topdown"
    static let description = IntentDescription("يفتح المحتوى المحمّل للمشاهدة والقراءة بدون إنترنت.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.tab = .library
        return .result()
    }
}

struct OpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "عرض تحميلات Topdown"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.tab = .downloads
        return .result()
    }
}

struct TopdownShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenLibraryIntent(),
                    phrases: ["افتح مكتبة \(.applicationName)", "Open \(.applicationName) library"],
                    shortTitle: "المكتبة", systemImageName: "square.stack.fill")
        AppShortcut(intent: OpenDownloadsIntent(),
                    phrases: ["تحميلات \(.applicationName)", "Show \(.applicationName) downloads"],
                    shortTitle: "التحميلات", systemImageName: "arrow.down.circle")
    }
}
