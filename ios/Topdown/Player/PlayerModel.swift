import SwiftUI
import AVKit
import MediaPlayer

/// موضع المشاهدة لكل حلقة (محلي على الجهاز؛ الخادم لا يحفظ التقدّم).
enum PlaybackPositions {
    private static let key = "playback.positions"

    struct Entry: Codable { var seconds: Double; var duration: Double; var updated: Double }

    private static var all: [String: Entry] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let v = try? JSONDecoder().decode([String: Entry].self, from: d) else { return [:] }
            return v
        }
        set {
            var v = newValue
            if v.count > 500 {
                let keep = v.sorted { $0.value.updated > $1.value.updated }.prefix(400)
                v = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
        }
    }

    static func entry(_ key: String) -> Entry? { all[key] }

    /// نسبة المشاهدة 0...1 (لشريط التقدّم على البطاقات)
    static func fraction(_ key: String) -> Double? {
        guard let e = all[key], e.duration > 0, e.seconds > 5 else { return nil }
        return min(1, e.seconds / e.duration)
    }

    /// من أين نكمل: لا نكمل إذا شاهد أقل من 10 ثوانٍ أو وصل للنهاية تقريبًا
    static func resumePoint(_ key: String) -> Double? {
        guard let e = all[key], e.seconds > 10 else { return nil }
        if e.duration > 0 && e.seconds > e.duration - 25 { return nil }
        return e.seconds
    }

    static func save(_ key: String, seconds: Double, duration: Double) {
        guard seconds.isFinite, duration.isFinite else { return }
        var a = all
        a[key] = Entry(seconds: seconds, duration: duration, updated: Date.now.timeIntervalSince1970)
        all = a
    }
}

/// خيار جودة أثناء التشغيل (يُطبَّق بحد أقصى للدقة/المعدّل دون إعادة تحميل الحلقة).
struct PlaybackQuality: Identifiable, Hashable {
    let id: String
    let label: String
    let height: Int
    let bitrate: Double
    static let auto = PlaybackQuality(id: "auto", label: "تلقائي", height: 0, bitrate: 0)
}

/// محرّك التشغيل: AVPlayer مع استئناف، جودة، سرعات، تخطّي، صورة داخل صورة،
/// إعادة جلب الرابط عند الفشل، والانتقال التلقائي للحلقة التالية.
@MainActor
@Observable
final class PlayerModel: NSObject {
    // ما يُشغَّل
    private(set) var item: MediaItem
    private(set) var playlist: [MediaItem]
    private(set) var resolved: Resolved?
    private(set) var isLocal = false

    // الحالة
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var isBuffering = true
    private(set) var current: Double = 0
    private(set) var duration: Double = 0
    private(set) var buffered: Double = 0
    private(set) var error: String?
    private(set) var qualities: [PlaybackQuality] = []
    private(set) var quality: PlaybackQuality = .auto
    private(set) var resumedFrom: Double?
    private(set) var pipActive = false
    private(set) var pipPossible = false
    private(set) var ended = false
    var rate: Float = 1 { didSet { if isPlaying { player.rate = rate } } }
    var holdBoost = false { didSet { player.rate = holdBoost ? 2 : (isPlaying ? rate : 0) } }

    /// العدّ التنازلي للحلقة التالية (ثوانٍ) — nil عند عدم الظهور
    private(set) var nextCountdown: Int?
    var autoplayNext: Bool { UserDefaults.standard.object(forKey: "player.autoNext") as? Bool ?? true }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var lastSaved: Double = 0
    @ObservationIgnored private var prefetched: [String: Resolved] = [:]
    @ObservationIgnored var pipController: AVPictureInPictureController?
    @ObservationIgnored var onRecord: ((MediaItem) -> Void)?

    init(item: MediaItem, playlist: [MediaItem] = []) {
        self.item = item
        self.playlist = playlist
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        observe()
        setupRemoteCommands()
    }

    // MARK: - التحميل

    var nextItem: MediaItem? {
        guard let i = playlist.firstIndex(where: { $0.key == item.key }), i + 1 < playlist.count else { return nil }
        return playlist[i + 1]
    }

    var previousItem: MediaItem? {
        guard let i = playlist.firstIndex(where: { $0.key == item.key }), i > 0 else { return nil }
        return playlist[i - 1]
    }

    func updatePlaylist(_ list: [MediaItem]) {
        if playlist.isEmpty || list.count > playlist.count { playlist = list }
    }

    /// يبدأ تشغيل عنصر (من التحميلات إن وُجد، وإلا يجلب الرابط من الخادم).
    func load(_ newItem: MediaItem? = nil, localPath: String? = nil) async {
        if let newItem { item = newItem }
        countdownTask?.cancel(); nextCountdown = nil
        error = nil; ended = false; isBuffering = true; retried = false
        current = 0; duration = item.durationSeconds ?? 0; buffered = 0
        qualities = []; quality = .auto; resumedFrom = nil

        let url: URL
        if let localPath {
            isLocal = true
            url = Storage.absolute(localPath)
        } else {
            isLocal = false
            do {
                let r: Resolved
                if let p = prefetched.removeValue(forKey: item.key), p.kind != "pending" { r = p }
                else { r = try await API.shared.resolve(item) }
                resolved = r
                guard let u = Site.url(r.url) else { throw APIError.server("رابط تشغيل غير صالح") }
                url = u
            } catch {
                self.error = error.localizedDescription
                isBuffering = false
                return
            }
        }
        start(url)
        onRecord?(item)
    }

    private func start(_ url: URL) {
        let asset = AVURLAsset(url: url, options: isLocal ? nil : API.shared.assetOptions(for: url))
        let pi = AVPlayerItem(asset: asset)
        // تخزين مؤقت أمامي أكبر لتشغيل أنعم على الشبكات المتذبذبة
        pi.preferredForwardBufferDuration = 30
        player.replaceCurrentItem(with: pi)
        observeItem(pi)

        let resume = PlaybackPositions.resumePoint(item.key)
        if let resume {
            resumedFrom = resume
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        play()
        updateNowPlaying()
        Task { await loadQualities(asset) }
    }

    private func loadQualities(_ asset: AVURLAsset) async {
        guard resolved?.kind == "hls" || url(asset).pathExtension == "m3u8",
              let variants = try? await asset.load(.variants), variants.count > 1 else { return }
        var seen = Set<Int>()
        let list: [PlaybackQuality] = variants.compactMap { v in
            let h = Int(v.videoAttributes?.presentationSize.height ?? 0)
            guard h > 0, seen.insert(h).inserted else { return nil }
            let label = h >= 2160 ? "4K" : h >= 1440 ? "2K" : "\(h)p"
            return PlaybackQuality(id: "\(h)", label: label, height: h, bitrate: v.peakBitRate ?? v.averageBitRate ?? 0)
        }.sorted { $0.height > $1.height }
        qualities = list.isEmpty ? [] : [.auto] + list
        // تطبيق الجودة المفضّلة من الإعدادات إن وُجدت
        let pref = UserDefaults.standard.string(forKey: "preferredQuality") ?? "ask"
        if let target = Int(pref), let q = list.first(where: { $0.height <= target }) ?? list.last {
            setQuality(q)
        }
    }

    private func url(_ asset: AVURLAsset) -> URL { asset.url }

    /// جودة يدوية: نحدّ الدقة والمعدّل فيتحول AVPlayer للنسخة المناسبة بدون انقطاع.
    func setQuality(_ q: PlaybackQuality) {
        quality = q
        guard let pi = player.currentItem else { return }
        if q.height == 0 {
            pi.preferredMaximumResolution = .zero
            pi.preferredPeakBitRate = 0
        } else {
            pi.preferredMaximumResolution = CGSize(width: CGFloat(q.height) * 16 / 9 + 2, height: CGFloat(q.height) + 2)
            pi.preferredPeakBitRate = q.bitrate > 0 ? q.bitrate * 1.05 : 0
        }
        Haptics.tap()
    }

    // MARK: - التحكم

    func play() { player.playImmediately(atRate: holdBoost ? 2 : rate); isPlaying = true; ended = false }
    func pause() { player.pause(); isPlaying = false; savePosition(force: true) }
    func toggle() { isPlaying ? pause() : play(); Haptics.tap() }

    func seek(to seconds: Double, precise: Bool = false) {
        let t = max(0, min(seconds, duration > 0 ? duration - 0.5 : seconds))
        current = t
        let tol = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
        if ended { ended = false; countdownTask?.cancel(); nextCountdown = nil }
    }

    func skip(_ delta: Double) { seek(to: current + delta); Haptics.tap() }

    func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func playNext() {
        guard let n = nextItem else { return }
        countdownTask?.cancel(); nextCountdown = nil
        savePosition(force: true)
        Task { await load(n, localPath: DownloadCenter.shared.localPath(for: n.key)) }
    }

    func playPrevious() {
        guard let p = previousItem else { return }
        savePosition(force: true)
        Task { await load(p, localPath: DownloadCenter.shared.localPath(for: p.key)) }
    }

    func cancelNext() { countdownTask?.cancel(); nextCountdown = nil }

    func stop() {
        savePosition(force: true)
        countdownTask?.cancel()
        player.pause()
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - المراقبة

    private func observe() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                if status == .playing { self.isPlaying = true }
            }
        })
    }

    private func observeItem(_ pi: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: pi, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnd() }
        }
        itemObservations = []
        itemObservations.append(pi.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription
            Task { @MainActor in if failed { self?.failed(message) } }
        })
        itemObservations.append(pi.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            let end = item.loadedTimeRanges.last.map { $0.timeRangeValue.start.seconds + $0.timeRangeValue.duration.seconds } ?? 0
            Task { @MainActor in self?.buffered = end }
        })
        itemObservations.append(pi.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let d = item.duration.seconds
            Task { @MainActor in if d.isFinite, d > 0 { self?.duration = d; self?.updateNowPlaying() } }
        })
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        current = t
        savePosition(force: false)
        // تجهيز رابط الحلقة التالية مبكرًا عند 80٪ لبدء فوري
        if duration > 0, t / duration > 0.8, let n = nextItem, prefetched[n.key] == nil,
           DownloadCenter.shared.localPath(for: n.key) == nil {
            prefetched[n.key] = Resolved(url: "", kind: "pending")
            Task {
                if let r = try? await API.shared.resolve(n) { prefetched[n.key] = r } else { prefetched[n.key] = nil }
            }
        }
        updateNowPlayingTime()
    }

    /// فشل التشغيل: نجلب رابطًا جديدًا مرة واحدة (قد يختار الخادم مصدرًا آخر) ونكمل من نفس النقطة.
    private func failed(_ message: String?) {
        guard !retried, !isLocal else {
            error = message ?? "تعذّر تشغيل الفيديو"
            isBuffering = false
            return
        }
        retried = true
        let at = current
        Task {
            if let r = try? await API.shared.resolve(item), let u = Site.url(r.url) {
                resolved = r
                start(u)
                seek(to: at)
            } else {
                error = message ?? "تعذّر تشغيل الفيديو"
                isBuffering = false
            }
        }
    }

    private func didEnd() {
        isPlaying = false
        ended = true
        PlaybackPositions.save(item.key, seconds: duration, duration: duration)
        guard nextItem != nil, autoplayNext else { return }
        countdownTask?.cancel()
        countdownTask = Task {
            for s in stride(from: 6, through: 1, by: -1) {
                nextCountdown = s
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            nextCountdown = nil
            playNext()
        }
    }

    private func savePosition(force: Bool) {
        guard current > 0, force || abs(current - lastSaved) >= 5 else { return }
        lastSaved = current
        PlaybackPositions.save(item.key, seconds: current, duration: duration)
        if isLocal { DownloadCenter.shared.savePosition(item.key, seconds: current) }
    }

    // MARK: - مركز التشغيل (شاشة القفل والسماعات)

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(10) }; return .success }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(-10) }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.playNext() }; return .success }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: "Topdown",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = current
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = current
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(player.rate) : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - مشغّل خارجي (VLC / Infuse) لروابط HLS المباشرة

    var externalURL: URL? {
        guard !isLocal, let r = resolved, r.kind == "hls", let u = Site.url(r.url), u.host() != Site.home.host() else { return nil }
        return u
    }

    // MARK: - صورة داخل صورة

    func attachPiP(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), pipController == nil else { return }
        let pip = AVPictureInPictureController(playerLayer: layer)
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
        pip?.delegate = self
        pipController = pip
        pipPossible = pip != nil
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

extension PlayerModel: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.pipActive = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.pipActive = false }
    }
}

/// رقم الحلقة من العنوان (لترتيب «من نفس السلسلة» واستنتاج الحلقة التالية).
enum EpisodeNumber {
    static func of(_ title: String) -> Double? {
        let digits = title.replacingOccurrences(of: "٠", with: "0").replacingOccurrences(of: "١", with: "1")
            .replacingOccurrences(of: "٢", with: "2").replacingOccurrences(of: "٣", with: "3")
            .replacingOccurrences(of: "٤", with: "4").replacingOccurrences(of: "٥", with: "5")
            .replacingOccurrences(of: "٦", with: "6").replacingOccurrences(of: "٧", with: "7")
            .replacingOccurrences(of: "٨", with: "8").replacingOccurrences(of: "٩", with: "9")
        let patterns = [#"(?:الحلقة|حلقة|episode|ep\.?)\s*(\d+(?:\.\d+)?)"#, #"(\d+(?:\.\d+)?)\s*$"#, #"\b(\d{1,3})\b(?!.*\b\d{1,3}\b)"#]
        for p in patterns {
            if let r = digits.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let m = String(digits[r])
                if let n = m.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) { return Double(m[n]) }
            }
        }
        return nil
    }

    /// يبني قائمة تشغيل مرتبة للسلسلة من العنصر الحالي ومن «من نفس السلسلة».
    static func playlist(current: MediaItem, related: [MediaItem]) -> [MediaItem] {
        let all = [current] + related.filter { $0.key != current.key }
        let numbered = all.compactMap { x in of(x.title).map { (x, $0) } }
        guard numbered.count >= 2, numbered.contains(where: { $0.0.key == current.key }) else { return [] }
        var seen = Set<Double>()
        return numbered.sorted { $0.1 < $1.1 }.filter { seen.insert($0.1).inserted || $0.0.key == current.key }.map(\.0)
    }
}
