import SwiftUI

/// تشغيل فيديو محمّل بدون إنترنت بنفس المشغّل الاحترافي، مع الانتقال لحلقات السلسلة المحمّلة.
struct PlayerScreen: View {
    let video: VideoDownload
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadCenter.self) private var center
    @State private var model: PlayerModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                ProPlayer(model: model, fullscreen: true, onFullscreen: { dismiss() }, onClose: { dismiss() })
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            guard model == nil, let path = video.localPath else { return }
            let current = Self.item(video)
            let others = center.videos.filter { $0.state == .completed && $0.id != video.id }.map(Self.item)
            let m = PlayerModel(item: current, playlist: EpisodeNumber.playlist(current: current, related: others))
            model = m
            Orientation.set(.landscapeRight)
            await m.load(localPath: path)
        }
        .onDisappear {
            if model?.pipActive != true { model?.stop() }
            Orientation.set(.portrait)
        }
    }

    static func item(_ v: VideoDownload) -> MediaItem {
        MediaItem(providerId: v.providerId, id: v.itemId, title: v.title, durationSeconds: v.durationSeconds)
    }
}
