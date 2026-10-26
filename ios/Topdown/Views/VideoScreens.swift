import SwiftUI
import AVKit

/// شاشة تشغيل الفيديو: مشغّل النظام + مفضلة + تحميل بالجودة + من نفس السلسلة.
struct VideoScreen: View {
    let item: MediaItem
    @Environment(Library.self) private var library
    @Environment(DownloadCenter.self) private var center
    @Environment(AppModel.self) private var app
    @State private var player: AVPlayer?
    @State private var resolved: Resolved?
    @State private var error: String?
    @State private var related: [MediaItem] = []
    @State private var request: DownloadRequest?
    @State private var playingLocal = false

    private var local: VideoDownload? {
        center.isDownloaded(key: item.key).flatMap { $0.state == .completed ? $0 : nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Rectangle().fill(.black)
                    if let player {
                        InlinePlayer(player: player)
                    } else if let error {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                            Text(error).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                            Button("إعادة المحاولة", systemImage: "arrow.clockwise") { Task { await load() } }
                                .buttonStyle(.glass)
                        }
                        .padding()
                    } else {
                        RemoteImage(urls: Site.videoThumb(item.thumbnail), maxPixel: 900).opacity(0.35)
                        ProgressView().controlSize(.large).tint(.white)
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 22))
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title3.bold())
                    HStack(spacing: 8) {
                        Text(item.sourceName)
                        if let d = item.durationText { Text("•"); Text(d) }
                        if playingLocal { Text("•"); Label("من التحميلات", systemImage: "arrow.down.circle.fill").foregroundStyle(Theme.accent) }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button { library.toggleFavorite(item) } label: {
                            Label(library.isFavorite(item) ? "محفوظ" : "حفظ",
                                  systemImage: library.isFavorite(item) ? "star.fill" : "star")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .symbolEffect(.bounce, value: library.isFavorite(item))

                        Button { startDownload() } label: {
                            Label(downloadLabel, systemImage: downloadIcon).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(resolved == nil && local == nil)
                    }
                    .controlSize(.large)
                }
                .padding(.horizontal)

                if let tags = item.tags, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(tags, id: \.self) { Badge(text: $0) } }.padding(.horizontal)
                    }
                }

                if !related.isEmpty {
                    SectionHeader(title: "من نفس السلسلة", count: related.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(related, id: \.key) { VideoCard(item: $0, width: 190) }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { player?.pause() }
        .sheet(item: $request) { req in
            DownloadSheet(request: req)
                .presentationDetents([.medium, .large])
        }
    }

    private var downloadLabel: String {
        switch center.isDownloaded(key: item.key)?.state {
        case .completed: "محمّل"
        case .downloading, .queued: "جارٍ التحميل"
        case .paused: "متوقف"
        default: "تحميل"
        }
    }

    private var downloadIcon: String {
        center.isDownloaded(key: item.key)?.state == .completed ? "checkmark.circle.fill" : "arrow.down.circle.fill"
    }

    private func load() async {
        error = nil
        if let local, let path = local.localPath {
            playingLocal = true
            start(AVPlayer(url: Storage.absolute(path)), resume: local.watchedSeconds)
            library.recordWatch(item)
        } else {
            do {
                let r = try await API.shared.resolve(item)
                resolved = r
                guard let url = Site.url(r.url) else { throw APIError.server("رابط تشغيل غير صالح") }
                let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: API.shared.sessionCookies])
                start(AVPlayer(playerItem: AVPlayerItem(asset: asset)), resume: 0)
                library.recordWatch(item)
            } catch {
                self.error = error.localizedDescription
            }
        }
        if related.isEmpty, app.isOnline, let r = try? await API.shared.related(item) {
            related = r.filter { $0.key != item.key }
        }
    }

    private func start(_ p: AVPlayer, resume: Double) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if resume > 5 { p.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
        player = p
        p.play()
    }

    private func startDownload() {
        if let existing = center.isDownloaded(key: item.key), existing.state == .completed {
            app.tab = .library
            return
        }
        guard let r = resolved, let v = CapturedVideo(item, r) else { return }
        request = .video(v)
    }
}

struct InlinePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

/// معاينة صامتة عند الضغط المطوّل على البطاقة (مثل معاينة الموقع).
struct VideoPreview: View {
    let item: MediaItem
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urls: Site.videoThumb(item.thumbnail), maxPixel: 700)
            if let player { LoopingPlayer(player: player) }
            Text(item.title).font(.headline).lineLimit(2).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
        .frame(width: 340, height: 200)
        .task {
            guard !item.opensDetails, let r = try? await API.shared.resolve(item), let url = Site.url(r.url) else { return }
            let p = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: API.shared.sessionCookies])))
            p.isMuted = true
            p.play()
            player = p
        }
        .onDisappear { player?.pause() }
    }
}

struct LoopingPlayer: UIViewRepresentable {
    let player: AVPlayer
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PlayerView, context: Context) {}
}

/// تفاصيل عمل من المصادر الجديدة مع قائمة حلقاته.
struct WorkScreen: View {
    let item: MediaItem
    @Environment(DownloadCenter.self) private var center
    @Environment(Library.self) private var library
    @State private var details: WorkDetails?
    @State private var error: String?

    private var episodes: [MediaItem] { details?.episodes?.values ?? [] }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    RemoteImage(urls: Site.videoThumb(item.thumbnail), maxPixel: 500)
                        .frame(width: 140, height: 90)
                        .clipShape(.rect(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(details?.categoryName ?? details?.title ?? item.title).font(.headline)
                        Text(item.sourceName).font(.caption).foregroundStyle(.secondary)
                        if details != nil { Text("\(episodes.count) حلقة").font(.caption).foregroundStyle(Theme.accent) }
                    }
                }
                .listRowBackground(Color.clear)
                if let w = details?.episodesWarning { Text(w).font(.footnote).foregroundStyle(.secondary) }
            }
            if details == nil && error == nil {
                HStack { ProgressView(); Text("جاري قراءة الحلقات…").foregroundStyle(.secondary) }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("إعادة المحاولة") { Task { await load() } }
            }
            if !episodes.isEmpty {
                Section("الحلقات") {
                    ForEach(episodes, id: \.key) { ep in
                        NavigationLink(value: Route.video(ep)) {
                            HStack {
                                Text(ep.title).lineLimit(2)
                                Spacer()
                                if let d = center.isDownloaded(key: ep.key) {
                                    Image(systemName: d.state == .completed ? "arrow.down.circle.fill" : "arrow.down.circle.dotted")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { library.toggleFavorite(item) } label: {
                    Image(systemName: library.isFavorite(item) ? "star.fill" : "star")
                }
                if episodes.count > 1 {
                    Menu {
                        Button("تحميل كل الحلقات (\(episodes.count))", systemImage: "square.and.arrow.down.on.square") {
                            center.downloadAll(episodes)
                        }
                    } label: { Image(systemName: "arrow.down.circle") }
                }
            }
        }
        .task { if details == nil { await load() } }
    }

    private func load() async {
        error = nil
        do { details = try await API.shared.details(item) } catch { self.error = error.localizedDescription }
    }
}
