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
    /// الواجهة الظاهرة (محمّل فيديو عادي) تغطي التطبيق الحقيقي حتى يُدخَل الرمز
    var concealed = true
    /// لا نبني التطبيق الحقيقي إطلاقًا قبل أول فتح بالرمز
    var revealedOnce = false
    /// القارئ يُعرض بملء الشاشة فوق كل شيء (بدون شريط التبويبات)
    var reader: ReaderRequest?
    /// اختبار المحاكي فقط: فتح فيديو مباشرة
    var debugVideo: MediaItem?

    @ObservationIgnored @AppStorage("appLock") var appLockEnabled = false
    @ObservationIgnored @AppStorage("privacyBlur") var privacyBlur = true
    @ObservationIgnored @AppStorage("appearance") var appearance = "dark"
    /// مهلة (بالثواني) قبل العودة للواجهة الظاهرة بعد الخروج من التطبيق
    @ObservationIgnored @AppStorage("stealth.grace") var stealthGrace = 0.0
    @ObservationIgnored private var backgroundedAt: Date?

    var colorScheme: ColorScheme? {
        switch appearance { case "light": .light; case "dark": .dark; default: nil }
    }

    private let monitor = NWPathMonitor()
    private var didLaunch = false

    private init() {
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
            if let since = backgroundedAt, revealedOnce, Date().timeIntervalSince(since) < stealthGrace {
                concealed = false
            }
            backgroundedAt = nil
            if isLocked && !concealed { unlock() }
        case .inactive:
            if privacyBlur && !concealed { isObscured = true }
        case .background:
            if privacyBlur { isObscured = true }
            // الواجهة الظاهرة تغطي فورًا حتى تظهر هي في مبدّل التطبيقات
            if !concealed { backgroundedAt = Date() }
            concealed = true
        @unknown default: break
        }
    }

    /// يكشف التطبيق الحقيقي بعد التحقق من الرمز
    func reveal() {
        isLocked = false
        revealedOnce = true
        concealed = false
    }

    func conceal() {
        backgroundedAt = nil
        concealed = true
    }

    func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { isLocked = false; return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "فتح التطبيق") { ok, _ in
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

struct ReaderRequest: Identifiable {
    let id = UUID()
    let story: StoryItem
    let chapters: [ChapterLink]
    let url: String
    /// نسجّل القراءة في حساب الموقع (لا نفعل ذلك للقصص المفتوحة من التحميلات بدون اتصال)
    var recordHistory = true
}

enum AppVersion {
    static var short: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    /// مثل «1.3.0 (52)» حتى تتأكد أي نسخة مثبّتة
    static var full: String { "\(short) (\(build))" }
}
