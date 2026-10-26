import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(Auth.self) private var auth

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch auth.state {
            case .checking:
                SplashView()
            case .signedOut:
                LoginView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .signedIn:
                MainTabs()
                    .transition(.opacity)
            }

            if let toast = app.toast {
                VStack {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if app.isObscured || app.isLocked {
                LockView().transition(.opacity)
            }
        }
        .animation(.smooth, value: app.isObscured)
        .animation(.smooth, value: app.isLocked)
        .task { await auth.bootstrap() }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab("استكشف", systemImage: "safari.fill", value: AppTab.explore) {
                ExploreView()
            }
            Tab("التحميلات", systemImage: "arrow.down.circle.fill", value: AppTab.library) {
                LibraryView()
            }
            .badge(center.activeCount)
            Tab("حسابي", systemImage: "person.crop.circle.fill", value: AppTab.account) {
                AccountView()
            }
            Tab("الإعدادات", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            BottomAccessory()
        }
    }
}

/// شريط زجاجي فوق التبويبات: تقدّم التحميل أو حالة الاتصال.
struct BottomAccessory: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        Button { app.tab = .library } label: {
            if let active = center.firstActive {
                MiniProgress(title: active.title, progress: active.progress)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: app.isOnline ? "checkmark.icloud" : "wifi.slash")
                        .foregroundStyle(app.isOnline ? Theme.accent : .orange)
                    Text(app.isOnline ? "متصل" : "بدون إنترنت — شاهد المحمّل")
                        .font(.subheadline)
                    Spacer()
                    Text(center.storageSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

struct MiniProgress: View {
    let title: String
    let progress: Double
    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: max(progress, 0.01))
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(Int(progress * 100))٪").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.down.circle").foregroundStyle(Theme.accent)
                .symbolEffect(.pulse)
        }
    }
}

struct SplashView: View {
    var body: some View {
        VStack(spacing: 16) {
            BrandMark(size: 72)
            ProgressView().tint(Theme.accent)
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 44
    var body: some View {
        Text("T")
            .font(.system(size: size * 0.55, weight: .semibold, design: .serif))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(Theme.accent.opacity(0.18)), in: .rect(cornerRadius: size * 0.28))
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                BrandMark(size: 64)
                if app.isLocked {
                    Text("Topdown مقفل").font(.title3.bold())
                    Button("فتح القفل", systemImage: "faceid") { app.unlock() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            }
        }
    }
}

struct LoginView: View {
    @Environment(Auth.self) private var auth
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            BrandMark(size: 76)
            VStack(spacing: 6) {
                Text("Topdown").font(.largeTitle.bold())
                Text("مساحتك الخاصة").foregroundStyle(.secondary)
            }
            VStack(spacing: 14) {
                SecureField("كلمة المرور", text: $password)
                    .textContentType(.password)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .padding(16)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                        .transition(.opacity)
                }
                Button(action: submit) {
                    Group {
                        if busy { ProgressView() } else { Text("دخول").font(.headline) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(password.isEmpty || busy)
                Text("تسجّل دخولك مرة واحدة فقط — التطبيق يتذكّرك.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
            .padding(.horizontal, 20)
            Spacer()
            Spacer()
        }
        .onAppear { focused = true }
        .animation(.smooth, value: error)
    }

    private func submit() {
        guard !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            do { try await auth.login(password) }
            catch { self.error = error.localizedDescription; Haptics.tap() }
            busy = false
        }
    }
}
