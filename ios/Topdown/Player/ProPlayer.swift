import SwiftUI
import AVKit

/// سطح الفيديو (AVPlayerLayer) — مطلوب لصورة داخل صورة.
struct PlayerSurface: UIViewRepresentable {
    let model: PlayerModel
    var fill = false

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.player = model.player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        model.attachPiP(v.playerLayer)
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

/// زر AirPlay من النظام.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// المشغّل الاحترافي: أدوات زجاجية تختفي تلقائيًا، ضغطتين للتقديم/الترجيع، ضغط مطوّل ×2،
/// تخطّي المقدمة، الجودة والسرعة أثناء التشغيل، صورة داخل صورة، AirPlay، قفل الشاشة، والحلقة التالية.
struct ProPlayer: View {
    let model: PlayerModel
    var fullscreen = false
    var onFullscreen: () -> Void = {}
    var onClose: (() -> Void)? = nil

    @State private var controls = true
    @State private var locked = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var seekFlash: (forward: Bool, id: Int)?
    @State private var fill = false
    @AppStorage("player.skipSeconds") private var skipSeconds = 85.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                PlayerSurface(model: model, fill: fill)

                gestureLayer(width: geo.size.width)

                if model.isBuffering && model.error == nil && !model.ended {
                    ProgressView().controlSize(.large).tint(.white)
                        .padding(18).glassEffect(.regular, in: .circle)
                        .allowsHitTesting(false)
                }

                if let f = seekFlash {
                    HStack {
                        if f.forward { Spacer() }
                        Label(f.forward ? "+10" : "-10", systemImage: f.forward ? "goforward.10" : "gobackward.10")
                            .labelStyle(.iconOnly).font(.title).padding(22)
                            .glassEffect(.regular, in: .circle)
                            .padding(.horizontal, geo.size.width * 0.12)
                        if !f.forward { Spacer() }
                    }
                    .transition(.opacity.combined(with: .scale))
                    .allowsHitTesting(false)
                }

                if model.holdBoost {
                    VStack {
                        Label("×2", systemImage: "forward.fill").font(.subheadline.bold())
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                            .padding(.top, 14)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                if locked {
                    lockOverlay
                } else if controls || !model.isPlaying || model.error != nil {
                    controlsOverlay
                        .transition(.opacity)
                }

                if !locked { skipIntroButton }
                if let n = model.nextCountdown, let next = model.nextItem { nextCard(next, seconds: n) }
                if let e = model.error { errorOverlay(e) }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .animation(.easeInOut(duration: 0.2), value: controls)
        .animation(.easeInOut(duration: 0.2), value: locked)
        .animation(.spring(duration: 0.3), value: seekFlash?.id)
        .onAppear { scheduleHide() }
        .onChange(of: model.isPlaying) { _, playing in if playing { scheduleHide() } else { controls = true } }
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
    }

    // MARK: - الإيماءات

    private func gestureLayer(width: CGFloat) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture(count: 2, coordinateSpace: .local) { p in
                guard !locked else { return }
                let forward = p.x > width / 2
                model.skip(forward ? 10 : -10)
                seekFlash = (forward, (seekFlash?.id ?? 0) + 1)
                let id = seekFlash?.id
                Task { try? await Task.sleep(for: .milliseconds(650)); if seekFlash?.id == id { seekFlash = nil } }
            }
            .onTapGesture { if !locked { toggleControls() } else { controls.toggle() } }
            .onLongPressGesture(minimumDuration: 0.35, perform: {}, onPressingChanged: { pressing in
                guard !locked, model.isPlaying || model.holdBoost else { return }
                model.holdBoost = pressing
                if pressing { Haptics.tap() }
            })
            .gesture(MagnifyGesture().onEnded { v in
                guard fullscreen else { return }
                withAnimation { fill = v.magnification > 1 }
            })
    }

    // MARK: - الأدوات

    private var controlsOverlay: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerControls
                Spacer()
                bottomBar
            }
            .padding(fullscreen ? 20 : 12)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if let onClose {
                circleButton("chevron.down", action: onClose)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.item.title).font(.subheadline.bold()).lineLimit(1)
                if let r = model.resumedFrom, model.current - r < 6 {
                    Text("متابعة من " + format(r)).font(.caption2).foregroundStyle(.white.opacity(0.75))
                } else if model.isLocal {
                    Label("من التحميلات", systemImage: "arrow.down.circle.fill").font(.caption2).foregroundStyle(Theme.accent)
                }
            }
            .foregroundStyle(.white)
            .environment(\.layoutDirection, .rightToLeft)
            Spacer()
            AirPlayButton().frame(width: 34, height: 34)
            if model.pipPossible {
                circleButton(model.pipActive ? "pip.exit" : "pip.enter") { model.togglePiP() }
            }
            optionsMenu
        }
    }

    private var centerControls: some View {
        HStack(spacing: fullscreen ? 56 : 34) {
            if model.previousItem != nil {
                bigButton("backward.end.fill", size: 22) { model.playPrevious() }
            }
            bigButton("gobackward.10", size: 26) { model.skip(-10); scheduleHide() }
            Button { model.toggle(); scheduleHide() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 74, height: 74)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.white)
            bigButton("goforward.10", size: 26) { model.skip(10); scheduleHide() }
            if model.nextItem != nil {
                bigButton("forward.end.fill", size: 22) { model.playNext() }
            }
        }
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Scrubber(value: scrubbing ? scrubValue : model.current,
                     buffered: model.buffered, duration: max(model.duration, 1)) { editing, v in
                scrubbing = editing
                scrubValue = v
                if !editing { model.seek(to: v, precise: true); scheduleHide() } else { hideTask?.cancel() }
            }
            HStack {
                Text(format(scrubbing ? scrubValue : model.current))
                Text("/").opacity(0.5)
                Text(format(model.duration)).opacity(0.8)
                Spacer()
                if model.rate != 1 {
                    Text("×" + String(format: "%g", model.rate)).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3).glassEffect(.regular, in: .capsule)
                }
                if model.quality.height > 0 {
                    Text(model.quality.label).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3).glassEffect(.regular, in: .capsule)
                }
                circleButton("lock.fill") { locked = true; controls = false; Haptics.tap() }
                circleButton(fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action: onFullscreen)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
    }

    private var optionsMenu: some View {
        Menu {
            if !model.qualities.isEmpty {
                Picker(selection: Binding(get: { model.quality }, set: { model.setQuality($0) })) {
                    ForEach(model.qualities) { Text($0.label).tag($0) }
                } label: { Label("الجودة: " + model.quality.label, systemImage: "4k.tv") }
                .pickerStyle(.menu)
            }
            Picker(selection: Binding(get: { model.rate }, set: { model.rate = $0 })) {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2] as [Float], id: \.self) { r in
                    Text(r == 1 ? "عادي" : "×" + String(format: "%g", r)).tag(r)
                }
            } label: { Label("السرعة", systemImage: "gauge.with.dots.needle.67percent") }
            .pickerStyle(.menu)
            Picker(selection: $skipSeconds) {
                ForEach([60.0, 85.0, 90.0, 120.0], id: \.self) { Text("\(Int($0)) ثانية").tag($0) }
            } label: { Label("مدة زر التخطّي", systemImage: "forward.frame") }
            .pickerStyle(.menu)
            Toggle("تشغيل الحلقة التالية تلقائيًا", systemImage: "play.square.stack", isOn: Binding(
                get: { model.autoplayNext }, set: { UserDefaults.standard.set($0, forKey: "player.autoNext") }))
            if fullscreen {
                Toggle("ملء الشاشة (قص الأطراف)", systemImage: "rectangle.expand.vertical", isOn: $fill)
            }
            if let u = model.externalURL {
                Section("فتح في مشغّل آخر") {
                    Button("VLC", systemImage: "play.rectangle") { openExternal("vlc-x-callback://x-callback-url/stream?url=", u) }
                    Button("Infuse", systemImage: "play.rectangle") { openExternal("infuse://x-callback-url/play?url=", u) }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.headline).frame(width: 34, height: 34)
                .glassEffect(.regular.interactive(), in: .circle)
                .foregroundStyle(.white)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    /// زر تخطّي المقدمة (مثل Sora): يظهر في أول دقائق الحلقة.
    @ViewBuilder private var skipIntroButton: some View {
        if !model.ended, model.duration > skipSeconds * 3, model.current > 3, model.current < min(240, model.duration * 0.25) {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { model.skip(skipSeconds) } label: {
                        Label("تخطّي +\(Int(skipSeconds))", systemImage: "forward.frame.fill")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .buttonStyle(.glass)
                    .tint(.white)
                    .padding(.trailing, fullscreen ? 28 : 14)
                    .padding(.bottom, controls ? (fullscreen ? 110 : 84) : 18)
                }
            }
            .transition(.opacity)
        }
    }

    private func nextCard(_ next: MediaItem, seconds: Int) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Text("الحلقة التالية خلال \(seconds)").font(.caption).foregroundStyle(.white.opacity(0.8))
                    Text(next.title).font(.subheadline.bold()).lineLimit(2).foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Button("إلغاء") { model.cancelNext() }.buttonStyle(.glass)
                        Button("شغّل الآن", systemImage: "play.fill") { model.playNext() }.buttonStyle(.glassProminent)
                    }
                }
                .padding(14)
                .frame(maxWidth: 300)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .environment(\.layoutDirection, .rightToLeft)
                .padding(fullscreen ? 28 : 12)
            }
        }
    }

    private var lockOverlay: some View {
        VStack {
            if controls {
                Button { locked = false; controls = true; scheduleHide(); Haptics.tap() } label: {
                    Label("فتح القفل", systemImage: "lock.open.fill").font(.subheadline.bold())
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .buttonStyle(.glass)
                .tint(.white)
                .padding(.top, 20)
                .transition(.opacity)
            }
            Spacer()
        }
    }

    private func errorOverlay(_ e: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text(e).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
            Button("إعادة المحاولة", systemImage: "arrow.clockwise") {
                Task { await model.load(localPath: DownloadCenter.shared.localPath(for: model.item.key)) }
            }
            .buttonStyle(.glassProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
    }

    // MARK: - أدوات مساعدة

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button { action(); scheduleHide() } label: {
            Image(systemName: icon).font(.subheadline.bold()).frame(width: 34, height: 34)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(.white)
    }

    private func bigButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold)).frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .contentShape(.circle)
    }

    private func toggleControls() {
        controls.toggle()
        if controls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, model.isPlaying, !scrubbing else { return }
            controls = false
        }
    }

    private func openExternal(_ prefix: String, _ url: URL) {
        let enc = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let u = URL(string: prefix + enc) else { return }
        model.pause()
        UIApplication.shared.open(u) { ok in
            if !ok { AppModel.shared.show("التطبيق غير مثبّت على جهازك") }
        }
    }

    private func format(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// شريط التقدّم: يعرض المحمّل مسبقًا، ويكبر عند السحب.
struct Scrubber: View {
    let value: Double
    let buffered: Double
    let duration: Double
    var onChange: (Bool, Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let p = CGFloat(min(1, max(0, value / duration)))
            let b = CGFloat(min(1, max(0, buffered / duration)))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.4)).frame(width: w * b)
                Capsule().fill(Theme.accent).frame(width: w * p)
                Circle().fill(.white)
                    .frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12)
                    .offset(x: w * p - (dragging ? 9 : 6))
                    .shadow(radius: 3)
            }
            .frame(height: dragging ? 8 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    onChange(true, Double(min(1, max(0, v.location.x / w))) * duration)
                }
                .onEnded { v in
                    dragging = false
                    onChange(false, Double(min(1, max(0, v.location.x / w))) * duration)
                })
        }
        .frame(height: 24)
        .animation(.spring(duration: 0.25), value: dragging)
    }
}

/// غلاف ملء الشاشة: يدور أفقيًا تلقائيًا ويرجع عند الإغلاق.
struct FullscreenPlayer: View {
    let model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ProPlayer(model: model, fullscreen: true, onFullscreen: { dismiss() }, onClose: { dismiss() })
            .ignoresSafeArea()
            .background(.black)
            .onAppear { Orientation.set(.landscapeRight) }
            .onDisappear { Orientation.set(.portrait) }
    }
}

enum Orientation {
    @MainActor static func set(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
