import SwiftUI
import AVKit

/// مشغّل iOS الأصلي (نفس مشغّل Safari والصور): السرعة، ±10 ث، صورة داخل صورة، AirPlay،
/// وملء الشاشة مع التدوير — بدون أدوات مخصّصة. نضيف فقط زرّي «تخطّي المقدمة» و«الحلقة التالية».
struct NativePlayer: UIViewControllerRepresentable {
    let model: PlayerModel
    /// أزرار تظهر داخل المشغّل نفسه (في الوضع العادي وملء الشاشة)
    var actions: [Action] = []

    struct Action: Equatable {
        let id: String
        let title: String
        let icon: String
        let run: () -> Void
        static func == (a: Action, b: Action) -> Bool { a.id == b.id && a.title == b.title }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = model.player
        vc.delegate = context.coordinator
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        // معلومات «يُعرض الآن» يديرها PlayerModel
        vc.updatesNowPlayingInfoCenter = false
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = .black
        context.coordinator.apply(actions, to: vc)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== model.player { vc.player = model.player }
        context.coordinator.apply(actions, to: vc)
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let model: PlayerModel
        private var shown: [Action] = []
        init(_ model: PlayerModel) { self.model = model }

        @MainActor func apply(_ actions: [Action], to vc: AVPlayerViewController) {
            guard actions != shown else { return }
            shown = actions
            vc.contextualActions = actions.map { a in
                UIAction(title: a.title, image: UIImage(systemName: a.icon)) { _ in a.run() }
            }
        }

        func playerViewController(_ vc: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator c: UIViewControllerTransitionCoordinator) {
            MainActor.assumeIsolated { model.inFullScreen = true }
        }

        func playerViewController(_ vc: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator c: UIViewControllerTransitionCoordinator) {
            c.animate(alongsideTransition: nil) { _ in
                MainActor.assumeIsolated { self.model.inFullScreen = false }
            }
        }

        func playerViewControllerWillStartPictureInPicture(_ vc: AVPlayerViewController) {
            MainActor.assumeIsolated { model.setPiP(true) }
        }

        func playerViewControllerDidStopPictureInPicture(_ vc: AVPlayerViewController) {
            MainActor.assumeIsolated { model.setPiP(false) }
        }

        func playerViewController(_ vc: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
            completion(true)
        }
    }
}

extension PlayerModel {
    /// «تخطّي المقدمة» في أول الحلقة، و«الحلقة التالية» قرب نهايتها.
    func contextualActions(skipSeconds: Double) -> [NativePlayer.Action] {
        var list: [NativePlayer.Action] = []
        if !ended, duration > skipSeconds * 3, current > 3, current < min(240, duration * 0.25) {
            list.append(.init(id: "skip", title: "تخطّي المقدمة", icon: "forward.frame.fill") { [weak self] in
                self?.skip(skipSeconds)
            })
        }
        if let next = nextItem, ended || nextCountdown != nil || (duration > 0 && current > duration - 90) {
            let n = EpisodeNumber.of(next.title).map { " " + String(format: "%g", $0) } ?? ""
            let title = nextCountdown.map { "الحلقة التالية\(n) (\($0))" } ?? "الحلقة التالية\(n)"
            list.append(.init(id: "next", title: title, icon: "forward.end.fill") { [weak self] in
                self?.playNext()
            })
        }
        return list
    }
}

/// رسالة الخطأ فوق المشغّل مع إعادة المحاولة.
struct PlayerErrorOverlay: View {
    let model: PlayerModel
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text(message).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
            Button("إعادة المحاولة", systemImage: "arrow.clockwise") {
                Task { await model.load(localPath: DownloadCenter.shared.localPath(for: model.item.key)) }
            }
            .buttonStyle(.glassProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.8))
    }
}
