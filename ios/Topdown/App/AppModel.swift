import SwiftUI
import Network
import LocalAuthentication

enum AppTab: Hashable { case explore, library, account, settings, search }
enum BrowseMode: String { case anime, stories }

enum Theme {
    static let accent = Color(red: 0.79, green: 0.69, blue: 0.56)
    static let background = Color(red: 0.05, green: 0.055, blue: 0.07)
}

enum Haptics {
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var tab: AppTab = .explore
    var mode: BrowseMode = .anime
    var isOnline = true
    var isLocked = false
    var isObscured = false
    var toast: String?

    @ObservationIgnored @AppStorage("appLock") var appLockEnabled = false
    @ObservationIgnored @AppStorage("privacyBlur") var privacyBlur = true
    @ObservationIgnored @AppStorage("appearance") var appearance = "dark"

    var colorScheme: ColorScheme? {
        switch appearance { case "light": .light; case "dark": .dark; default: nil }
    }

    private let monitor = NWPathMonitor()
    private var didLaunch = false

    private init() {
        isLocked = UserDefaults.standard.bool(forKey: "appLock")
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in AppModel.shared.networkChanged(path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "net.monitor"))
    }

    private func networkChanged(_ online: Bool) {
        let wasOnline = isOnline
        isOnline = online
        if !didLaunch {
            didLaunch = true
            // بدون إنترنت عند الفتح: نذهب مباشرة للمكتبة المحمّلة
            if !online { tab = .library }
            return
        }
        if online && !wasOnline {
            show("عاد الاتصال بالإنترنت")
        } else if !online && wasOnline {
            show("أنت الآن غير متصل — المحتوى المحمّل متاح في المكتبة")
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isObscured = false
            if isLocked { unlock() }
        case .inactive:
            if privacyBlur { isObscured = true }
        case .background:
            if privacyBlur { isObscured = true }
            if appLockEnabled { isLocked = true }
        @unknown default: break
        }
    }

    func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { isLocked = false; return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "افتح Topdown") { ok, _ in
            Task { @MainActor in if ok { AppModel.shared.isLocked = false } }
        }
    }

    func show(_ message: String) {
        withAnimation(.spring) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast == message { withAnimation(.spring) { toast = nil } }
        }
    }
}
