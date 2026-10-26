import SwiftUI
import WebKit

struct WebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @Environment(AppModel.self) private var app
    @Environment(WebModel.self) private var web

    var body: some View {
        @Bindable var web = web
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            WebContainer(webView: web.webView)
                .ignoresSafeArea(edges: .bottom)

            if web.isLoading && web.progress < 1 {
                ProgressView(value: web.progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(height: 2)
                    .transition(.opacity)
            }

            if web.failure != nil || !app.isOnline && web.currentURL == nil {
                OfflineCard(message: web.failure)
                    .padding(24)
                    .frame(maxHeight: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: web.isLoading)
        .sheet(item: $web.downloadRequest) { req in
            DownloadSheet(request: req)
                .presentationDetents([.medium, .large])
                .presentationBackground(.thinMaterial)
        }
    }
}

struct OfflineCard: View {
    @Environment(AppModel.self) private var app
    @Environment(WebModel.self) private var web
    let message: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: app.isOnline ? "exclamationmark.triangle" : "wifi.slash")
                .font(.system(size: 42))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, isActive: !app.isOnline)
            Text(app.isOnline ? "تعذّر فتح الصفحة" : "لا يوجد اتصال بالإنترنت")
                .font(.title3.bold())
            Text(app.isOnline ? (message ?? "") : "تقدر تتصفح وتشاهد كل اللي حمّلته من المكتبة بدون إنترنت.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("إعادة المحاولة", systemImage: "arrow.clockwise") { web.reload() }
                        .buttonStyle(.glass)
                    Button("المكتبة", systemImage: "square.stack.fill") { app.tab = .library }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(26)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }
}
