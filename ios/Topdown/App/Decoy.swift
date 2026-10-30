import SwiftUI
import AVKit
import CryptoKit

// MARK: - الستار: نافذة مستقلة فوق التطبيق الحقيقي

/// الواجهة الظاهرة تعيش في نافذة خاصة فوق كل شيء، فتغطي حتى الشاشات المعروضة
/// بملء الشاشة، ويبقى التطبيق الحقيقي (والتشغيل والتحميل) يعمل تحتها.
@MainActor
final class Curtain {
    static let shared = Curtain()
    private var window: UIWindow?

    func update(concealed: Bool) {
        if concealed {
            guard window == nil else { window?.alpha = 1; window?.makeKeyAndVisible(); return }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
                // المشهد لم يجهز بعد: نعيد المحاولة بعد لحظة
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    if AppModel.shared.concealed { self.update(concealed: true) }
                }
                return
            }
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            let host = UIHostingController(rootView: DecoyRoot()
                .environment(AppModel.shared)
                .environment(Auth.shared)
                .environment(DecoyStore.shared)
                .environment(\.layoutDirection, .rightToLeft)
                .tint(.blue))
            host.view.backgroundColor = .systemBackground
            w.rootViewController = host
            w.makeKeyAndVisible()
            window = w
        } else {
            guard let w = window else { return }
            UIView.animate(withDuration: 0.25, animations: { w.alpha = 0 }) { _ in
                w.isHidden = true
                if self.window === w { self.window = nil }
                w.windowScene?.windows.first { $0 !== w }?.makeKey()
            }
        }
    }
}

// MARK: - كود التفعيل

/// كود يختاره المستخدم بنفسه. لا يُحفظ نصّه أبدًا: نحفظ ملحًا عشوائيًا وبصمة مشتقة منه
/// (SHA-256 مكرّرة) في Keychain.
enum ActivationCode {
    static let minLength = 4
    private static let rounds = 20_000

    static var isSet: Bool { Keychain.activationCode != nil }

    static func set(_ code: String) {
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let saltHex = salt.map { String(format: "%02x", $0) }.joined()
        Keychain.activationCode = saltHex + ":" + digest(code, salt: saltHex)
        resetFailures()
    }

    static func matches(_ code: String) -> Bool {
        guard let stored = Keychain.activationCode else { return false }
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        let candidate = Array(digest(code, salt: parts[0]).utf8)
        let expected = Array(parts[1].utf8)
        guard candidate.count == expected.count else { return false }
        // مقارنة بزمن ثابت
        return zip(candidate, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func digest(_ code: String, salt: String) -> String {
        var data = Data((salt + ":" + code).utf8)
        for _ in 0..<rounds { data = Data(SHA256.hash(data: data)) }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: المحاولات الخاطئة (بدون أي إيقاف — بعد 10 يظهر «نسيت الكود»)

    static let forgotAfter = 10
    private static let failsKey = "stealth.fails"

    static var failures: Int { UserDefaults.standard.integer(forKey: failsKey) }

    static func recordFailure() {
        UserDefaults.standard.set(failures + 1, forKey: failsKey)
    }

    static func resetFailures() {
        UserDefaults.standard.removeObject(forKey: failsKey)
        UserDefaults.standard.removeObject(forKey: "stealth.lockUntil")
    }

    /// أول مرة فقط (قبل اختيار الكود): نتأكد أنك صاحب الحساب بكلمة مرور الموقع
    @MainActor
    static func verifyAccountPassword(_ password: String) async -> String? {
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { return "غير صحيح" }
        if let saved = Keychain.password, !saved.isEmpty {
            return saved == password ? nil : "غير صحيح"
        }
        guard AppModel.shared.isOnline else { return "يلزم اتصال بالإنترنت" }
        do { try await Auth.shared.login(password); return nil } catch { return "غير صحيح" }
    }
}

// MARK: - محمّل الفيديو (الواجهة الظاهرة)

struct DecoyFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let date: Date
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
@Observable
final class DecoyStore {
    static let shared = DecoyStore()

    var files: [DecoyFile] = []
    var busy = false
    var progress: Double = 0
    var message: String?
    var status: String?

    static let folder = URL.documentsDirectory.appending(path: "Saved", directoryHint: .isDirectory)
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "3gp"]

    private init() { reload() }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys)) ?? []
        files = urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return DecoyFile(url: u, size: Int64(v?.fileSize ?? 0), date: v?.creationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    /// أول رابط داخل النص (المشاركة من تيك توك تضيف كلامًا قبل الرابط)
    static func firstLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range).compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    private var maxHeight: Int {
        switch UserDefaults.standard.string(forKey: "decoy.quality") {
        case "medium": 720
        case "low": 360
        default: 1080
        }
    }

    func download(_ text: String) async {
        message = nil
        guard let url = Self.firstLink(in: text) else {
            message = "الرابط غير صالح"
            return
        }
        busy = true
        progress = 0
        status = "جارٍ قراءة الرابط…"
        defer { busy = false; status = nil }
        let fm = FileManager.default
        var temps: [URL] = []
        defer { temps.forEach { try? fm.removeItem(at: $0) } }
        do {
            let source: VideoGrabber.Source
            switch VideoGrabber.kind(of: url) {
            case .youtube(let id): source = try await VideoGrabber.youtube(id, maxHeight: maxHeight)
            case .tiktok: source = try await VideoGrabber.tiktok(url)
            case .direct:
                let base = url.deletingPathExtension().lastPathComponent
                source = VideoGrabber.Source(title: base.isEmpty || base == "/" ? "video" : base, video: url)
            }
            status = source.title
            // الفيديو 90٪ من الشريط والصوت الباقي
            let share = source.audio == nil ? 1.0 : 0.9
            let video = try await VideoGrabber.fetch(source.video, headers: source.headers, chunked: source.chunked,
                                                     length: source.videoLength) { p in
                Task { @MainActor in DecoyStore.shared.progress = p * share }
            }
            temps.append(video)
            if case .direct = VideoGrabber.kind(of: url) {
                let ext = url.pathExtension.lowercased()
                guard Self.videoExtensions.contains(ext) || Self.looksLikeVideo(video) else {
                    message = "هذا الرابط لا يحتوي فيديو. الصق رابط يوتيوب أو تيك توك أو رابط ملف فيديو."
                    return
                }
            }
            let target = uniqueURL(name: VideoGrabber.safeName(source.title), ext: "mp4")
            if let audioURL = source.audio {
                let audio = try await VideoGrabber.fetch(audioURL, headers: source.headers, chunked: source.chunked,
                                                         length: source.audioLength) { p in
                    Task { @MainActor in DecoyStore.shared.progress = 0.9 + p * 0.1 }
                }
                temps.append(audio)
                status = "دمج الصوت مع الفيديو…"
                try await VideoGrabber.mux(video: video, audio: audio, to: target)
            } else {
                try fm.moveItem(at: video, to: target)
            }
            progress = 1
            message = "تم الحفظ — تجده في «الملفات»"
            reload()
        } catch {
            message = "تعذّر التنزيل: " + error.localizedDescription
        }
    }

    /// فحص بسيط لترويسة الملف (mp4/mov: ftyp، webm/mkv: EBML)
    private static func looksLikeVideo(_ file: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 12)) ?? Data()
        if head.count >= 8, String(data: head[4..<8], encoding: .ascii) == "ftyp" { return true }
        return head.starts(with: [0x1A, 0x45, 0xDF, 0xA3])
    }

    func delete(_ file: DecoyFile) {
        try? FileManager.default.removeItem(at: file.url)
        reload()
    }

    func deleteAll() {
        for f in files { try? FileManager.default.removeItem(at: f.url) }
        reload()
    }

    private func uniqueURL(name: String, ext: String) -> URL {
        var url = Self.folder.appending(path: "\(name).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.folder.appending(path: "\(name) \(i).\(ext)")
            i += 1
        }
        return url
    }
}

struct DecoyRoot: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("تنزيل", systemImage: "arrow.down.circle.fill", value: 0) { DecoyHome() }
            Tab("الملفات", systemImage: "folder.fill", value: 1) { DecoyFiles() }
            Tab("الإعدادات", systemImage: "gearshape.fill", value: 2) { DecoySettings() }
        }
        .onAppear {
            #if DEBUG
            if ["decoy", "decoyUnlock"].contains(UserDefaults.standard.string(forKey: "smokeTab") ?? "") { tab = 2 }
            #endif
        }
    }
}

struct DecoyHome: View {
    @Environment(DecoyStore.self) private var store
    @State private var link = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.down.to.line.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.blue.gradient)
                        .padding(.top, 24)
                    Text("الصق رابط الفيديو للتنزيل").font(.title3.bold())
                    HStack(spacing: 8) {
                        ForEach(["يوتيوب", "تيك توك", "روابط مباشرة"], id: \.self) { t in
                            Text(t).font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.fill.tertiary, in: .capsule)
                        }
                    }

                    HStack(spacing: 10) {
                        TextField("https://", text: $link)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .environment(\.layoutDirection, .leftToRight)
                        if link.isEmpty {
                            Button("لصق") { link = UIPasteboard.general.string ?? "" }
                                .buttonStyle(.bordered)
                        } else {
                            Button { link = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 14))

                    Button {
                        focused = false
                        Task { await store.download(link) }
                    } label: {
                        Group {
                            if store.busy {
                                ProgressView(value: store.progress > 0 ? store.progress : nil)
                                    .tint(.white)
                            } else {
                                Label("تنزيل", systemImage: "arrow.down")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(link.isEmpty || store.busy)

                    if store.busy {
                        VStack(spacing: 4) {
                            if let st = store.status { Text(st).font(.footnote).lineLimit(2) }
                            if store.progress > 0 {
                                Text("\(Int(store.progress * 100))٪").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.center)
                    }
                    if let m = store.message {
                        Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("طريقة الاستخدام").font(.headline)
                        step(1, "من يوتيوب أو تيك توك: مشاركة ← نسخ الرابط.")
                        step(2, "الصق الرابط في الخانة بالأعلى.")
                        step(3, "اضغط «تنزيل» وستجد الفيديو في «الملفات».")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16))
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("محمّل الفيديو")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                #if DEBUG
                let links = ["decoyTikTok": "https://www.tiktok.com/@tiktok/video/7106594312292453675",
                             "decoyYouTube": "https://youtu.be/jNQXAC9IVRw"]
                if let l = links[UserDefaults.standard.string(forKey: "smokeTab") ?? ""], link.isEmpty {
                    link = l
                    Task { await store.download(l) }
                }
                #endif
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(.blue, in: .circle)
            Text(text).font(.subheadline)
        }
    }
}

struct DecoyFiles: View {
    @Environment(DecoyStore.self) private var store
    @State private var playing: DecoyFile?

    var body: some View {
        NavigationStack {
            Group {
                if store.files.isEmpty {
                    ContentUnavailableView("لا توجد ملفات", systemImage: "film.stack",
                                           description: Text("الفيديوهات التي تنزّلها تظهر هنا."))
                } else {
                    List {
                        ForEach(store.files) { f in
                            Button { playing = f } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(f.name).lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    ShareLink(item: f.url) { Image(systemName: "square.and.arrow.up") }
                                        .buttonStyle(.borderless)
                                }
                            }
                            .tint(.primary)
                        }
                        .onDelete { idx in idx.map { store.files[$0] }.forEach(store.delete) }
                    }
                }
            }
            .navigationTitle("الملفات")
            .onAppear { store.reload() }
            .fullScreenCover(item: $playing) { f in
                DecoyPlayer(url: f.url)
            }
        }
    }
}

struct DecoyPlayer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player).ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(12)
            }
            .buttonStyle(.glass)
            .padding()
        }
        .onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: url)); player.play() }
        .onDisappear { player.pause() }
    }
}

struct DecoySettings: View {
    @Environment(DecoyStore.self) private var store
    @AppStorage("decoy.quality") private var quality = "best"
    @AppStorage("decoy.cellular") private var cellular = false
    @State private var taps = 0
    @State private var lastTap = Date.distantPast
    @State private var askCode = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("التنزيل") {
                    Picker("الجودة", selection: $quality) {
                        Text("الأعلى").tag("best")
                        Text("متوسطة").tag("medium")
                        Text("منخفضة").tag("low")
                    }
                    Toggle("التنزيل عبر بيانات الجوال", isOn: $cellular)
                }
                Section("التخزين") {
                    LabeledContent("المساحة المستخدمة",
                                   value: ByteCountFormatter.string(fromByteCount: store.totalSize, countStyle: .file))
                    Button("حذف كل الملفات", role: .destructive) { confirmClear = true }
                        .disabled(store.files.isEmpty)
                }
                Section("حول") {
                    // المكان السري: خمس ضغطات متتالية على رقم الإصدار
                    LabeledContent("الإصدار", value: AppVersion.short)
                        .contentShape(.rect)
                        .onTapGesture { tapVersion() }
                    LabeledContent("المطوّر", value: "Studio")
                }
            }
            .navigationTitle("الإعدادات")
            .confirmationDialog("حذف كل الملفات؟", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("حذف", role: .destructive) { store.deleteAll() }
            }
            .sheet(isPresented: $askCode) {
                SecretCodeSheet()
                    .presentationDetents([.height(360)])
            }
            .onAppear {
                #if DEBUG
                if ["decoy", "decoyUnlock"].contains(UserDefaults.standard.string(forKey: "smokeTab") ?? "") { askCode = true }
                #endif
            }
        }
    }

    private func tapVersion() {
        let now = Date()
        taps = now.timeIntervalSince(lastTap) < 1.2 ? taps + 1 : 1
        lastTap = now
        if taps >= 5 {
            taps = 0
            askCode = true
        }
    }
}

struct SecretCodeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// enter: الكود · account: كلمة مرور الحساب (أول مرة أو «نسيت الكود») · create/confirm: كود جديد
    private enum Step { case enter, account, create, confirm }
    @State private var step: Step = ActivationCode.isSet ? .enter : .account
    @State private var forgot = false
    @State private var changing = false
    @State private var text = ""
    @State private var firstEntry = ""
    @State private var busy = false
    @State private var error: String?
    @State private var shake = 0
    @State private var failures = ActivationCode.failures
    @FocusState private var focused: Bool

    private var title: String {
        switch step {
        case .enter: changing ? "اكتب الكود الحالي" : "كود التفعيل"
        case .account: forgot ? "نسيت الكود" : "التفعيل لأول مرة"
        case .create: "اختر كود التفعيل الجديد"
        case .confirm: "أعد كتابة الكود"
        }
    }

    private var hint: String? {
        switch step {
        case .account: "اكتب كلمة مرور حسابك للتأكد أنك صاحبه"
        case .create: "\(ActivationCode.minLength) خانات أو أكثر — لا يعرفه أحد غيرك"
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline).padding(.top, 24)
            if let hint { Text(hint).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            SecureField(step == .account ? "كلمة المرور" : "الكود", text: $text)
                .textContentType(step == .create || step == .confirm ? .newPassword : .password)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(submit)
                .padding(14)
                .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                .phaseAnimator([0, 1], trigger: shake) { v, p in v.offset(x: p == 1 ? 8 : 0) }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button(action: submit) {
                Group { if busy { ProgressView() } else { Text(step == .enter && !changing ? "تفعيل" : "متابعة").font(.headline) } }
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(text.isEmpty || busy)

            if step == .enter {
                HStack {
                    Button(changing ? "إلغاء التغيير" : "تغيير الكود") {
                        changing.toggle(); error = nil; text = ""; focused = true
                    }
                    Spacer()
                    if failures >= ActivationCode.forgotAfter {
                        Button("نسيت الكود؟") {
                            forgot = true; changing = false; error = nil; text = ""; step = .account; focused = true
                        }
                        .fontWeight(.semibold)
                    }
                }
                .font(.footnote)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .animation(.smooth, value: step)
        .animation(.smooth, value: failures)
        .onAppear {
            focused = true
            #if DEBUG
            if UserDefaults.standard.string(forKey: "smokeTab") == "decoyUnlock",
               let pw = UserDefaults.standard.string(forKey: "smokePassword") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if step == .enter { text = "2468" } else { text = pw }
                    submit()
                    for code in ["2468", "2468"] {
                        try? await Task.sleep(for: .seconds(2))
                        guard step == .create || step == .confirm else { break }
                        text = code
                        submit()
                    }
                }
            }
            #endif
        }
    }

    private func submit() {
        guard !text.isEmpty, !busy else { return }
        let value = text
        error = nil
        switch step {
        case .enter:
            busy = true
            Task {
                // الاشتقاق يأخذ لحظة؛ يُشغَّل خارج الواجهة
                let ok = await Task.detached(priority: .userInitiated) { ActivationCode.matches(value) }.value
                busy = false
                guard ok else { fail("الكود غير صحيح"); return }
                ActivationCode.resetFailures()
                failures = 0
                if changing { text = ""; step = .create } else { open() }
            }
        case .account:
            busy = true
            Task {
                let problem = await ActivationCode.verifyAccountPassword(value)
                busy = false
                if let problem { fail(problem) } else { text = ""; step = .create }
            }
        case .create:
            guard value.count >= ActivationCode.minLength else { fail("الكود قصير"); return }
            firstEntry = value
            text = ""
            step = .confirm
        case .confirm:
            guard value == firstEntry else { firstEntry = ""; step = .create; fail("غير متطابق — أعد المحاولة"); return }
            busy = true
            Task {
                await Task.detached(priority: .userInitiated) { ActivationCode.set(value) }.value
                busy = false
                failures = 0
                open()
            }
        }
    }

    private func fail(_ message: String) {
        if step == .enter {
            ActivationCode.recordFailure()
            failures = ActivationCode.failures
        }
        error = message
        text = ""
        shake += 1
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func open() {
        focused = false
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            app.reveal()
        }
    }
}

/// تغيير الكود من داخل التطبيق الحقيقي
struct ChangeActivationCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var again = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("الكود الجديد", text: $code).textContentType(.newPassword)
                    SecureField("أعد كتابته", text: $again).textContentType(.newPassword)
                } footer: {
                    Text(error ?? "\(ActivationCode.minLength) خانات أو أكثر. لا يُحفظ الكود نفسه على الجهاز، فقط بصمة مشفّرة منه.")
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("كود التفعيل")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        guard code.count >= ActivationCode.minLength else { error = "الكود قصير"; return }
                        guard code == again else { error = "غير متطابق"; return }
                        ActivationCode.set(code)
                        AppModel.shared.show("تم حفظ كود التفعيل")
                        dismiss()
                    }
                    .disabled(code.isEmpty)
                }
            }
        }
    }
}
