import SwiftUI
import AVKit
import LocalAuthentication

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

// MARK: - التحقق من الرمز

enum StealthKey {
    /// الرمز هو كلمة مرور الموقع: يُقارن محليًا إن كانت محفوظة، وإلا يُتحقق منه بتسجيل الدخول.
    @MainActor
    static func verify(_ code: String) async -> Result<Void, StealthError> {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return .failure(.wrong) }
        if let saved = Keychain.password, !saved.isEmpty {
            guard saved == code else { return .failure(.wrong) }
            if Auth.shared.state == .signedOut, AppModel.shared.isOnline { try? await Auth.shared.login(code) }
            return .success(())
        }
        guard AppModel.shared.isOnline else { return .failure(.offline) }
        do {
            try await Auth.shared.login(code)
            return .success(())
        } catch {
            return .failure(.wrong)
        }
    }

    enum StealthError: Error {
        case wrong, offline
        var message: String {
            switch self {
            case .wrong: "الرمز غير صحيح"
            case .offline: "يلزم اتصال بالإنترنت"
            }
        }
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
    @ObservationIgnored private var activeTask: URLSessionDownloadTask?

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

    func download(_ text: String) async {
        message = nil
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            message = "الرابط غير صالح"
            return
        }
        busy = true
        progress = 0
        defer { busy = false }
        let fm = FileManager.default
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let t = activeTask { progress = t.progress.fractionCompleted }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel(); activeTask = nil }
        do {
            let (tmp, response): (URL, URLResponse) = try await withCheckedThrowingContinuation { cont in
                let t = URLSession.shared.downloadTask(with: url) { location, response, error in
                    guard let location, let response else {
                        cont.resume(throwing: error ?? URLError(.badServerResponse)); return
                    }
                    // الملف المؤقت يُحذف بعد هذه الدالة، ننقله فورًا
                    let keep = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                    do { try FileManager.default.moveItem(at: location, to: keep); cont.resume(returning: (keep, response)) }
                    catch { cont.resume(throwing: error) }
                }
                activeTask = t
                t.resume()
            }
            let mime = (response.mimeType ?? "").lowercased()
            let ext = url.pathExtension.lowercased()
            guard mime.hasPrefix("video/") || Self.videoExtensions.contains(ext) else {
                try? fm.removeItem(at: tmp)
                message = "هذا الرابط لا يحتوي فيديو مباشر. انسخ رابط ملف الفيديو نفسه."
                return
            }
            let base = url.deletingPathExtension().lastPathComponent
            let target = uniqueURL(name: base.isEmpty || base == "/" ? "video" : base,
                                   ext: Self.videoExtensions.contains(ext) ? ext : "mp4")
            try fm.moveItem(at: tmp, to: target)
            progress = 1
            message = "تم الحفظ — تجده في «الملفات»"
            reload()
        } catch {
            message = "تعذّر التنزيل: " + error.localizedDescription
        }
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
            if UserDefaults.standard.string(forKey: "smokeTab")?.hasPrefix("decoy") == true { tab = 2 }
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

                    if let m = store.message {
                        Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("طريقة الاستخدام").font(.headline)
                        step(1, "انسخ رابط الفيديو من المتصفح.")
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
                    .presentationDetents([.height(300)])
            }
            .onAppear {
                #if DEBUG
                if UserDefaults.standard.string(forKey: "smokeTab")?.hasPrefix("decoy") == true { askCode = true }
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
    @AppStorage("stealth.faceID") private var useFaceID = false
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var shake = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Text("رمز المطوّر").font(.headline).padding(.top, 24)
            SecureField("الرمز", text: $code)
                .textContentType(.password)
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
                Group { if busy { ProgressView() } else { Text("تأكيد").font(.headline) } }
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(code.isEmpty || busy)
            Spacer()
        }
        .padding(.horizontal, 24)
        .onAppear {
            #if DEBUG
            if UserDefaults.standard.string(forKey: "smokeTab") == "decoyUnlock",
               let pw = UserDefaults.standard.string(forKey: "smokePassword") {
                code = pw
                Task { try? await Task.sleep(for: .seconds(3)); submit() }
                return
            }
            #endif
            if useFaceID && Keychain.password != nil { faceID() } else { focused = true }
        }
    }

    private func submit() {
        guard !code.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            let result = await StealthKey.verify(code)
            busy = false
            switch result {
            case .success: open()
            case .failure(let e):
                error = e.message
                code = ""
                shake += 1
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func faceID() {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { focused = true; return }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "تأكيد الهوية") { ok, _ in
            Task { @MainActor in if ok { open() } else { focused = true } }
        }
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
