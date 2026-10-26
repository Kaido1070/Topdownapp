import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        @Bindable var app = app
        ZStack {
            TabView(selection: $app.tab) {
                Tab("الموقع", systemImage: "globe", value: AppTab.web) {
                    BrowserView()
                }
                Tab("المكتبة", systemImage: "square.stack.fill", value: AppTab.library) {
                    LibraryView()
                }
                Tab("التحميلات", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                    DownloadsView()
                }
                .badge(center.activeCount)
                Tab("الإعدادات", systemImage: "gearshape", value: AppTab.settings) {
                    SettingsView()
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory {
                BottomAccessory()
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
                LockView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: app.isObscured)
        .animation(.smooth, value: app.isLocked)
    }
}

/// شريط زجاجي فوق شريط التبويبات: تحكم المتصفح أو حالة التحميل.
struct BottomAccessory: View {
    @Environment(AppModel.self) private var app
    @Environment(WebModel.self) private var web
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        if app.tab == .web {
            HStack(spacing: 4) {
                Button { web.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!web.canGoBack)
                Button { web.goForward() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!web.canGoForward)
                Button { web.isLoading ? web.stop() : web.reload() } label: {
                    Image(systemName: web.isLoading ? "xmark" : "arrow.clockwise")
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { web.goHome() } label: { Image(systemName: "house") }
                Spacer(minLength: 8)
                if web.capturedVideo != nil || web.capturedChapter != nil {
                    Button { web.requestDownload() } label: {
                        Label("تحميل", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.bold))
                            .symbolEffect(.bounce, value: web.captureToken)
                    }
                    .buttonStyle(.glassProminent)
                    .transition(.scale.combined(with: .opacity))
                } else if let active = center.firstActive {
                    MiniProgress(title: active.title, progress: active.progress)
                }
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .padding(.horizontal, 14)
            .animation(.spring, value: web.capturedVideo?.id)
            .animation(.spring, value: web.capturedChapter?.url)
        } else if let active = center.firstActive {
            MiniProgress(title: active.title, progress: active.progress)
                .padding(.horizontal, 14)
        } else {
            HStack {
                Image(systemName: app.isOnline ? "wifi" : "wifi.slash")
                Text(app.isOnline ? "متصل" : "غير متصل — تصفّح المحمّل")
                    .font(.subheadline)
                Spacer()
                Text(center.storageSummary).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(Int(progress * 100))٪").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            if app.isLocked {
                VStack(spacing: 18) {
                    Image(systemName: "lock.fill").font(.system(size: 44))
                    Text("Topdown مقفل").font(.title3.bold())
                    Button("فتح القفل") { app.unlock() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            }
        }
    }
}
