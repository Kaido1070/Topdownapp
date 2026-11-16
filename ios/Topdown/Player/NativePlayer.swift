import SwiftUI
import AVKit

/// مشغّل iOS الأصلي (نفس مشغّل Safari والصور): السرعة، ±10 ث، صورة داخل صورة، AirPlay،
/// وملء الشاشة مع التدوير — بدون أدوات مخصّصة. «تخطّي المقدمة» و«الحلقة التالية» تحت المشغّل.
struct NativePlayer: UIViewControllerRepresentable {
    let model: PlayerModel

    struct Action: Identifiable {
        let id: String
        let title: String
        let icon: String
        let run: () -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = model.player
        vc.delegate = context.coordinator
        vc.allowsPictureInPicturePlayback = true
        // لا يبدأ «صورة داخل صورة» تلقائيًا عند الخروج من التطبيق (يكشف المحتوى فوق الشاشة الرئيسية)؛ الزر اليدوي موجود
        vc.canStartPictureInPictureAutomaticallyFromInline = false
        // معلومات «يُعرض الآن» يديرها PlayerModel
        vc.updatesNowPlayingInfoCenter = false
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = .black
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== model.player { vc.player = model.player }
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let model: PlayerModel
        init(_ model: PlayerModel) { self.model = model }

        func playerViewController(_ vc: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator c: UIViewControllerTransitionCoordinator) {
            MainActor.assumeIsolated {
                model.inFullScreen = true
                Orientation.set(.landscape)
            }
        }

        func playerViewController(_ vc: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator c: UIViewControllerTransitionCoordinator) {
            // النظام يوقف التشغيل عند الخروج من ملء الشاشة: نكمل إن كان يعمل
            let wasPlaying = MainActor.assumeIsolated { model.isPlaying }
            c.animate(alongsideTransition: nil) { ctx in
                MainActor.assumeIsolated {
                    guard !ctx.isCancelled else { return }
                    self.model.inFullScreen = false
                    Orientation.set(.portrait)
                    if wasPlaying { self.model.play() }
                }
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

enum Orientation {
    /// يطلب تدوير الواجهة (أفقي عند ملء الشاشة، عمودي عند الرجوع). على الآيباد لا نغيّر شيئًا.
    @MainActor static func set(_ mask: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
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

/// أزرار سريعة تحت المشغّل (تظهر فقط عند الحاجة)
struct PlayerActionsRow: View {
    let actions: [NativePlayer.Action]

    var body: some View {
        if !actions.isEmpty {
            HStack(spacing: 10) {
                ForEach(actions) { a in
                    Button(action: a.run) {
                        Label(a.title, systemImage: a.icon).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .controlSize(.large)
            .padding(.horizontal)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
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
