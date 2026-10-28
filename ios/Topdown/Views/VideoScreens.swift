import SwiftUI
import AVKit

/// شاشة التشغيل: مشغّل احترافي + قائمة الحلقات + الحلقة التالية + المفضلة والتحميل.
struct VideoScreen: View {
    let item: MediaItem
    var playlist: [MediaItem] = []
    @Environment(Library.self) private var library
    @Environment(DownloadCenter.self) private var center
    @Environment(AppModel.self) private var app
    @State private var model: PlayerModel?
    @State private var related: [MediaItem] = []
    @State private var request: DownloadRequest?
    @State private var fullscreen = false

    private var playing: MediaItem { model?.item ?? item }
    private var episodes: [MediaItem] { model?.playlist ?? playlist }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if let model {
                        ProPlayer(model: model, onFullscreen: { fullscreen = true })
                    } else {
                        ZStack {
                            RemoteImage(urls: Site.videoThumb(item.thumbnail), maxPixel: 900).opacity(0.35)
                            ProgressView().controlSize(.large).tint(.white)
                        }
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .background(.black)
                .clipShape(.rect(cornerRadius: 22))
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 6) {
                    Text(playing.title).font(.title3.bold())
                    HStack(spacing: 8) {
                        Text(playing.sourceName)
                        if let d = playing.durationText { Text("•"); Text(d) }
                        if let i = episodes.firstIndex(where: { $0.key == playing.key }), episodes.count > 1 {
                            Text("•"); Text("حلقة \(i + 1) من \(episodes.count)")
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .animation(.smooth, value: playing.key)

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button { library.toggleFavorite(playing) } label: {
                            Label(library.isFavorite(playing) ? "محفوظ" : "حفظ",
                                  systemImage: library.isFavorite(playing) ? "star.fill" : "star")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .symbolEffect(.bounce, value: library.isFavorite(playing))

                        Button { startDownload() } label: {
                            Label(downloadLabel, systemImage: downloadIcon).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(model?.resolved == nil && center.localPath(for: playing.key) == nil)

                        if let next = model?.nextItem {
                            Button { model?.playNext() } label: {
                                Label("التالية", systemImage: "forward.end.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .accessibilityHint(next.title)
                        }
                    }
                    .controlSize(.large)
                }
                .padding(.horizontal)

                if episodes.count > 1 {
                    SectionHeader(title: "الحلقات", count: episodes.count)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 10) {
                                ForEach(Array(episodes.enumerated()), id: \.element.key) { i, ep in
                                    EpisodeChip(index: i + 1, item: ep, current: ep.key == playing.key) {
                                        Task { await model?.load(ep, localPath: center.localPath(for: ep.key)) }
                                    }
                                    .id(ep.key)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .onChange(of: playing.key, initial: true) { _, k in withAnimation { proxy.scrollTo(k, anchor: .center) } }
                    }
                }

                if let tags = playing.tags, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(tags, id: \.self) { Badge(text: $0) } }.padding(.horizontal)
                    }
                }

                let others = related.filter { r in !episodes.contains { $0.key == r.key } }
                if !others.isEmpty {
                    SectionHeader(title: "من نفس السلسلة", count: others.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(others, id: \.key) { VideoCard(item: $0, width: 190) }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(playing.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let m = PlayerModel(item: item, playlist: playlist)
            m.onRecord = { library.recordWatch($0) }
            model = m
            await m.load(localPath: center.localPath(for: item.key))
            if app.isOnline, let r = try? await API.shared.related(item) {
                related = r.filter { $0.key != item.key }
                // بدون قائمة حلقات: نبنيها من «نفس السلسلة» حسب رقم الحلقة في العنوان
                if playlist.isEmpty { m.updatePlaylist(EpisodeNumber.playlist(current: item, related: related)) }
            }
        }
        .onDisappear {
            if !fullscreen, model?.pipActive != true { model?.stop() }
        }
        .fullScreenCover(isPresented: $fullscreen) {
            if let model { FullscreenPlayer(model: model) }
        }
        .sheet(item: $request) { req in
            DownloadSheet(request: req)
                .presentationDetents([.medium, .large])
        }
    }

    private var downloadLabel: String {
        switch center.isDownloaded(key: playing.key)?.state {
        case .completed: "محمّل"
        case .downloading, .queued: "جارٍ التحميل"
        case .paused: "متوقف"
        default: "تحميل"
        }
    }

    private var downloadIcon: String {
        center.isDownloaded(key: playing.key)?.state == .completed ? "checkmark.circle.fill" : "arrow.down.circle.fill"
    }

    private func startDownload() {
        if center.localPath(for: playing.key) != nil {
            app.tab = .library
            return
        }
        guard let r = model?.resolved, let v = CapturedVideo(playing, r) else { return }
        request = .video(v)
    }
}

/// شريحة حلقة في قائمة الحلقات: الحالية مميزة، مع شريط المشاهدة وعلامة التحميل.
private struct EpisodeChip: View {
    let index: Int
    let item: MediaItem
    let current: Bool
    let action: () -> Void
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(Int(EpisodeNumber.of(item.title) ?? Double(index)))")
                        .font(.headline.monospacedDigit())
                    if current { Image(systemName: "waveform").symbolEffect(.variableColor.iterative) }
                    Spacer(minLength: 0)
                    if center.localPath(for: item.key) != nil {
                        Image(systemName: "arrow.down.circle.fill").font(.caption)
                    }
                }
                Text(item.title).font(.caption2).lineLimit(1).opacity(0.8)
                ProgressView(value: PlaybackPositions.fraction(item.key) ?? 0)
                    .tint(Theme.accent)
                    .opacity(PlaybackPositions.fraction(item.key) == nil ? 0 : 1)
            }
            .foregroundStyle(current ? Color.black : Color.primary)
            .padding(12)
            .frame(width: 130)
            .background(current ? Theme.accent : Color.clear, in: .rect(cornerRadius: 16))
            .glassEffect(current ? .identity : .regular.interactive(), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
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
            let p = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: API.shared.assetOptions(for: url))))
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
                        NavigationLink(value: Route.episode(ep, episodes)) {
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
