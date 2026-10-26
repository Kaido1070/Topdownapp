import SwiftUI
import AVKit

struct PlayerScreen: View {
    let video: VideoDownload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let path = video.localPath {
                PlayerController(url: Storage.absolute(path), id: video.id, start: video.watchedSeconds)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView("الملف غير موجود", systemImage: "exclamationmark.triangle")
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(12)
            }
            .buttonStyle(.glass)
            .padding()
        }
        .persistentSystemOverlays(.hidden)
    }
}

/// مشغل النظام: صورة داخل صورة، AirPlay، تحكم كامل، ومتابعة من آخر نقطة.
struct PlayerController: UIViewControllerRepresentable {
    let url: URL
    let id: String
    let start: Double

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = true
        if start > 5 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        context.coordinator.observe(player, id: id)
        player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.save()
        vc.player?.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: Any?
        private weak var player: AVPlayer?
        private var id = ""

        func observe(_ player: AVPlayer, id: String) {
            self.player = player
            self.id = id
            token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
                self?.save()
            }
        }

        func save() {
            guard let t = player?.currentTime().seconds, t.isFinite else { return }
            let id = id
            MainActor.assumeIsolated { DownloadCenter.shared.savePosition(id, seconds: t) }
        }

        deinit { if let token { player?.removeTimeObserver(token) } }
    }
}
