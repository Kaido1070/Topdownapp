import SwiftUI

/// تشغيل فيديو محمّل بدون إنترنت بالمشغّل الأصلي، مع الانتقال لحلقات السلسلة المحمّلة.
struct PlayerScreen: View {
    let video: VideoDownload
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadCenter.self) private var center
    @AppStorage("player.skipSeconds") private var skipSeconds = 85.0
    @State private var model: PlayerModel?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Color.black
                    if let model {
                        NativePlayer(model: model)
                        if let e = model.error { PlayerErrorOverlay(model: model, message: e) }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                if let model { PlayerActionsRow(actions: model.contextualActions(skipSeconds: skipSeconds)) }

                Text(model?.item.title ?? video.title).font(.title3.bold()).padding(.horizontal)
                Label("من التحميلات — يعمل بدون إنترنت", systemImage: "arrow.down.circle.fill")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .task {
            guard model == nil, let path = video.localPath else { return }
            let current = Self.item(video)
            let others = center.videos.filter { $0.state == .completed && $0.id != video.id }.map(Self.item)
            let m = PlayerModel(item: current, playlist: EpisodeNumber.playlist(current: current, related: others))
            model = m
            await m.load(localPath: path)
        }
        .onDisappear {
            guard model?.inFullScreen != true else { return }
            if model?.pipActive != true { model?.stop() }
        }
    }

    static func item(_ v: VideoDownload) -> MediaItem {
        MediaItem(providerId: v.providerId, id: v.itemId, title: v.title, durationSeconds: v.durationSeconds)
    }
}
