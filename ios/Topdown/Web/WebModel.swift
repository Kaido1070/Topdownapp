import SwiftUI
import WebKit

struct CapturedVideo: Identifiable, Equatable {
    var id: String { providerId + ":" + itemId }
    let providerId: String
    let itemId: String
    let title: String
    let thumbnail: String?
    let durationSeconds: Double?
    let url: URL
    let kind: String // hls | mp4 | direct
}

struct ChapterLink: Codable, Hashable {
    let url: String
    let title: String
    let number: Double?
}

struct CapturedStory: Equatable {
    let title: String
    let url: String
    let cover: String?
    let chapters: [ChapterLink]
}

struct CapturedChapter: Equatable {
    let url: String
    let title: String
    let images: [String]
}

@MainActor
@Observable
final class WebModel: NSObject {
    static let shared = WebModel()
    static let homeURL = Site.home

    let webView: WKWebView

    var progress: Double = 0
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var title = ""
    var currentURL: URL?
    var failure: String?

    var capturedVideo: CapturedVideo?
    var capturedChapter: CapturedChapter?
    var story: CapturedStory?
    var captureToken = 0

    /// طلب عرض ورقة الجودة/التحميل
    var downloadRequest: DownloadRequest?

    @ObservationIgnored private var resolved: [String: CapturedVideo] = [:]
    @ObservationIgnored private var lastChapter: CapturedChapter?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private let refresh = UIRefreshControl()

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.applicationNameForUserAgent = "TopdownApp/1.0"

        let script = WKUserScript(source: BridgeScript.source, injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true, in: .page)
        config.userContentController.addUserScript(script)

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        config.userContentController.add(WeakHandler(self), contentWorld: .page, name: "topdown")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isInspectable = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Theme.background)
        webView.scrollView.backgroundColor = UIColor(Theme.background)
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.keyboardDismissMode = .interactive

        refresh.tintColor = UIColor(Theme.accent)
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        observers = [
            webView.observe(\.estimatedProgress, options: [.new]) { wv, _ in
                Task { @MainActor in WebModel.shared.progress = wv.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { wv, _ in
                Task { @MainActor in WebModel.shared.isLoading = wv.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { wv, _ in
                Task { @MainActor in WebModel.shared.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { wv, _ in
                Task { @MainActor in WebModel.shared.canGoForward = wv.canGoForward }
            },
            webView.observe(\.title, options: [.new]) { wv, _ in
                Task { @MainActor in WebModel.shared.title = wv.title ?? "" }
            },
            webView.observe(\.url, options: [.new]) { wv, _ in
                Task { @MainActor in WebModel.shared.currentURL = wv.url }
            },
        ]

        webView.load(URLRequest(url: Self.homeURL))
    }

    // MARK: - التنقل

    func goBack() { webView.goBack(); Haptics.tap() }
    func goForward() { webView.goForward(); Haptics.tap() }
    func stop() { webView.stopLoading() }
    func goHome() { failure = nil; webView.load(URLRequest(url: Self.homeURL)); Haptics.tap() }

    func reload() {
        failure = nil
        if webView.url == nil { webView.load(URLRequest(url: Self.homeURL)) } else { webView.reload() }
        Haptics.tap()
    }

    func reloadIfFailed() { if failure != nil { reload() } }

    func open(_ url: URL) { failure = nil; webView.load(URLRequest(url: url)) }

    @objc private func pullToRefresh() {
        reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [refresh] in refresh.endRefreshing() }
    }

    // MARK: - الجسر

    fileprivate func receive(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "resolve":
            guard let urlString = msg["url"] as? String, let url = URL(string: urlString) else { return }
            let item = msg["item"] as? [String: Any] ?? [:]
            let video = CapturedVideo(
                providerId: item["providerId"] as? String ?? "web",
                itemId: item["id"] as? String ?? urlString,
                title: (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title,
                thumbnail: item["thumbnail"] as? String,
                durationSeconds: item["durationSeconds"] as? Double,
                url: url,
                kind: msg["kind"] as? String ?? "direct")
            resolved[url.absoluteString] = video
        case "story":
            let chapters = (msg["chapters"] as? [[String: Any]] ?? []).compactMap { c -> ChapterLink? in
                guard let u = c["url"] as? String else { return nil }
                return ChapterLink(url: u, title: c["title"] as? String ?? "", number: c["number"] as? Double)
            }
            story = CapturedStory(title: msg["title"] as? String ?? "", url: msg["url"] as? String ?? "",
                                  cover: (msg["cover"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                  chapters: chapters)
        case "chapter":
            lastChapter = CapturedChapter(url: msg["url"] as? String ?? "", title: msg["title"] as? String ?? "",
                                          images: msg["images"] as? [String] ?? [])
        case "state":
            let src = msg["playerSrc"] as? String ?? ""
            let video = src.isEmpty ? nil : resolved[src]
            let chapter = (msg["reader"] as? Bool ?? false) ? lastChapter : nil
            if video != capturedVideo || chapter != capturedChapter {
                capturedVideo = video
                capturedChapter = chapter
                if video != nil || chapter != nil { captureToken += 1 }
            }
        default: break
        }
    }

    // MARK: - التحميل

    func requestDownload() {
        Haptics.tap()
        if let v = capturedVideo {
            downloadRequest = .video(v)
        } else if let c = capturedChapter, let s = story {
            downloadRequest = .chapter(c, s)
        } else if let c = capturedChapter {
            downloadRequest = .chapter(c, CapturedStory(title: title, url: c.url, cover: nil, chapters: []))
        }
    }

    /// ملف لا تستطيع الصفحة عرضه يُحفظ في مجلد الملفات.
    fileprivate func save(download: WKDownload) { download.delegate = FileDownloadDelegate.shared }
}

enum DownloadRequest: Identifiable {
    case video(CapturedVideo)
    case chapter(CapturedChapter, CapturedStory)
    var id: String {
        switch self {
        case .video(let v): "v:" + v.id
        case .chapter(let c, _): "c:" + c.url
        }
    }
}

// MARK: - مندوبو WebKit

extension WebModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if action.shouldPerformDownload { return .download }
        if scheme == "http" || scheme == "https" {
            let host = url.host() ?? ""
            let home = Self.homeURL.host() ?? ""
            if action.targetFrame?.isMainFrame != false, action.navigationType == .linkActivated,
               host != home, !host.hasSuffix("." + home) {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }
        if ["about", "blob", "data"].contains(scheme) { return .allow }
        await UIApplication.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { save(download: download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { save(download: download) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { failure = nil }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failure = nil
        refresh.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }

    private func fail(_ error: Error) {
        refresh.endRefreshing()
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled || ns.code == 102 /* frame load interrupted */ { return }
        failure = ns.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await Dialogs.alert(message)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await Dialogs.confirm(message)
    }
}

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebModel?
    init(_ target: WebModel) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.receive(body) }
    }
}

/// حفظ تنزيلات WKDownload العامة (ملفات) في Documents/Files.
final class FileDownloadDelegate: NSObject, WKDownloadDelegate {
    static let shared = FileDownloadDelegate()

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = Storage.filesDir
        var dest = dir.appending(path: suggestedFilename)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path()) {
            let base = (suggestedFilename as NSString).deletingPathExtension
            let ext = (suggestedFilename as NSString).pathExtension
            dest = dir.appending(path: ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        }
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in AppModel.shared.show("تم حفظ الملف في مجلد Topdown داخل تطبيق الملفات") }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Task { @MainActor in AppModel.shared.show("فشل تحميل الملف") }
    }
}

enum Haptics {
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

@MainActor
enum Dialogs {
    static var presenter: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    static func alert(_ message: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "حسنًا", style: .default) { _ in c.resume() })
            guard let p = presenter else { c.resume(); return }
            p.present(a, animated: true)
        }
    }

    static func confirm(_ message: String) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in c.resume(returning: false) })
            a.addAction(UIAlertAction(title: "موافق", style: .default) { _ in c.resume(returning: true) })
            guard let p = presenter else { c.resume(returning: false); return }
            p.present(a, animated: true)
        }
    }
}
