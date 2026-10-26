import Foundation
import AVFoundation
import UIKit
import UserNotifications
import SwiftUI

/// خيار جودة لعرضه في ورقة التحميل.
struct QualityOption: Identifiable, Hashable {
    let id: String
    let label: String
    let detail: String
    let height: Int
    let bitrate: Double
    let variant: AVAssetVariant?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
@Observable
final class DownloadCenter {
    static let shared = DownloadCenter()

    private(set) var videos: [VideoDownload] = []
    private(set) var stories: [StoryDownload] = []
    var backgroundCompletion: [String: () -> Void] = [:]

    @ObservationIgnored @AppStorage("preferredQuality") var preferredQuality = "ask"
    @ObservationIgnored @AppStorage("allowCellular") var allowCellular = true
    @ObservationIgnored @AppStorage("notifyOnFinish") var notifyOnFinish = true

    @ObservationIgnored private var hlsSession: AVAssetDownloadURLSession!
    @ObservationIgnored private var fileSession: URLSession!
    @ObservationIgnored private let delegate = SessionDelegate()
    @ObservationIgnored private var tasks: [String: URLSessionTask] = [:]
    @ObservationIgnored private var chapterJobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var restored = false

    private init() {
        load()
        makeSessions()
    }

    // MARK: - ملخصات للواجهة

    var activeCount: Int {
        videos.filter { $0.state.isActive }.count
            + stories.flatMap(\.chapters).filter { $0.state.isActive }.count
    }

    var firstActive: (title: String, progress: Double)? {
        if let v = videos.first(where: { $0.state == .downloading }) { return (v.title, v.progress) }
        for s in stories {
            if let c = s.chapters.first(where: { $0.state == .downloading }) {
                return (s.title + " • " + c.displayTitle, c.progress)
            }
        }
        return nil
    }

    var totalBytes: Int64 {
        videos.reduce(0) { $0 + $1.bytes } + Storage.size(of: Storage.storiesDir)
    }

    var storageSummary: String { Storage.format(totalBytes) }

    // MARK: - الجلسات

    private func makeSessions() {
        let hlsConfig = URLSessionConfiguration.background(withIdentifier: "com.topdown.app.hls")
        hlsConfig.allowsCellularAccess = allowCellular
        hlsConfig.sessionSendsLaunchEvents = true
        hlsSession = AVAssetDownloadURLSession(configuration: hlsConfig, assetDownloadDelegate: delegate,
                                               delegateQueue: .main)

        let fileConfig = URLSessionConfiguration.background(withIdentifier: "com.topdown.app.files")
        fileConfig.allowsCellularAccess = allowCellular
        fileConfig.sessionSendsLaunchEvents = true
        fileConfig.isDiscretionary = false
        fileSession = URLSession(configuration: fileConfig, delegate: delegate, delegateQueue: .main)
    }

    /// يعيد ربط التحميلات الجارية بعد إعادة تشغيل التطبيق.
    func restore() {
        guard !restored else { return }
        restored = true
        Task {
            let hls = await hlsSession.allTasks
            let files = await fileSession.allTasks
            for t in hls + files { if let id = t.taskDescription { tasks[id] = t } }
            for i in videos.indices where videos[i].state.isActive && tasks[videos[i].id] == nil {
                videos[i].state = .failed
                videos[i].errorMessage = "توقف التحميل — اضغط لإعادة المحاولة"
            }
            for s in stories.indices {
                for c in stories[s].chapters.indices where stories[s].chapters[c].state.isActive {
                    resumeChapter(storyURL: stories[s].url, chapterURL: stories[s].chapters[c].url)
                }
            }
            scheduleSave()
        }
    }

    // MARK: - الجودة

    func qualityOptions(for video: CapturedVideo) async -> [QualityOption] {
        if video.kind == "hls" {
            let asset = AVURLAsset(url: video.url, options: API.shared.assetOptions(for: video.url))
            if let variants = try? await asset.load(.variants), !variants.isEmpty {
                var seen = Set<Int>()
                let opts: [QualityOption] = variants.compactMap { v in
                    let h = Int(v.videoAttributes?.presentationSize.height ?? 0)
                    let br = v.peakBitRate ?? v.averageBitRate ?? 0
                    let key = h > 0 ? h : Int(br)
                    if seen.contains(key) { return nil }
                    seen.insert(key)
                    let label = h >= 2160 ? "4K" : h >= 1440 ? "2K" : h > 0 ? "\(h)p" : "صوت فقط"
                    let mbps = br > 0 ? String(format: "%.1f Mbps", br / 1_000_000) : ""
                    let est = (video.durationSeconds ?? 0) > 0 && br > 0
                        ? " • ≈ " + Storage.format(Int64(br / 8 * (video.durationSeconds ?? 0))) : ""
                    return QualityOption(id: "\(key)", label: label, detail: mbps + est, height: h, bitrate: br, variant: v)
                }
                return opts.sorted { ($0.height, $0.bitrate) > ($1.height, $1.bitrate) }
            }
            return [QualityOption(id: "auto", label: "تلقائي", detail: "أفضل جودة متاحة", height: 0, bitrate: 0, variant: nil)]
        }
        var size = ""
        var req = Self.request(video.url)
        req.httpMethod = "HEAD"
        if let result = try? await API.shared.session.data(for: req), result.1.expectedContentLength > 0 {
            size = Storage.format(result.1.expectedContentLength)
        }
        return [QualityOption(id: "original", label: "الأصلية", detail: ["MP4", size].filter { !$0.isEmpty }.joined(separator: " • "),
                              height: 0, bitrate: 0, variant: nil)]
    }

    /// يختار الجودة تلقائيًا حسب الإعداد، أو nil إذا كان "اسأل كل مرة".
    func autoPick(_ options: [QualityOption]) -> QualityOption? {
        if options.count <= 1 { return options.first }
        let video = options.filter { $0.height > 0 }
        switch preferredQuality {
        case "ask": return nil
        case "best": return options.first
        case "smallest": return video.last ?? options.last
        default:
            guard let target = Int(preferredQuality), !video.isEmpty else { return options.first }
            return video.first { $0.height <= target } ?? video.last
        }
    }

    // MARK: - تحميل فيديو

    func isDownloaded(_ v: CapturedVideo) -> VideoDownload? { videos.first { $0.id == v.id } }

    func download(_ video: CapturedVideo, quality: QualityOption, quiet: Bool = false) {
        if let existing = videos.firstIndex(where: { $0.id == video.id }) {
            if videos[existing].state.isActive { AppModel.shared.show("الفيديو قيد التحميل"); return }
            remove(video: videos[existing], deleteFiles: true)
        }
        let record = VideoDownload(
            id: video.id, providerId: video.providerId, itemId: video.itemId, title: video.title,
            sourceURL: video.url.absoluteString, kind: video.kind == "hls" ? "hls" : "mp4",
            qualityLabel: quality.label, thumbnailFile: nil, localPath: nil,
            durationSeconds: video.durationSeconds, state: .queued, progress: 0, bytes: 0, createdAt: .now)
        videos.insert(record, at: 0)
        requestNotificationPermission()
        if !quiet {
            Haptics.success()
            AppModel.shared.show("بدأ التحميل: \(video.title)")
        }

        Task {
            if let thumb = video.thumbnail { await fetchThumbnail(thumb, for: video.id) }
            if record.kind == "hls" {
                let asset = AVURLAsset(url: video.url, options: API.shared.assetOptions(for: video.url))
                let config = AVAssetDownloadConfiguration(asset: asset, title: video.title)
                if let v = quality.variant {
                    config.primaryContentConfiguration.variantQualifiers = [AVAssetVariantQualifier(variant: v)]
                }
                if let file = videos.first(where: { $0.id == video.id })?.thumbnailFile,
                   let data = try? Data(contentsOf: Storage.absolute(file)) {
                    config.artworkData = data
                }
                let task = hlsSession.makeAssetDownloadTask(downloadConfiguration: config)
                start(task, id: video.id)
            } else {
                let req = Self.request(video.url)
                start(fileSession.downloadTask(with: req), id: video.id)
            }
        }
    }

    private func start(_ task: URLSessionTask, id: String) {
        task.taskDescription = id
        tasks[id] = task
        update(video: id) { $0.state = .downloading }
        task.resume()
    }

    func pause(_ v: VideoDownload) {
        tasks[v.id]?.suspend()
        update(video: v.id) { $0.state = .paused }
    }

    func resume(_ v: VideoDownload) {
        guard let t = tasks[v.id] else { retry(v); return }
        t.resume()
        update(video: v.id) { $0.state = .downloading }
    }

    func retry(_ v: VideoDownload) {
        guard let url = URL(string: v.sourceURL) else { return }
        let captured = CapturedVideo(providerId: v.providerId, itemId: v.itemId, title: v.title, thumbnail: nil,
                                     durationSeconds: v.durationSeconds, url: url, kind: v.kind)
        Task {
            let options = await qualityOptions(for: captured)
            let pick = options.first { $0.label == v.qualityLabel } ?? options.first
            guard let pick else { return }
            download(captured, quality: pick)
        }
    }

    func remove(video v: VideoDownload, deleteFiles: Bool = true) {
        tasks[v.id]?.cancel()
        tasks[v.id] = nil
        if deleteFiles {
            if let p = v.localPath { try? FileManager.default.removeItem(at: Storage.absolute(p)) }
            if let t = v.thumbnailFile { try? FileManager.default.removeItem(at: Storage.absolute(t)) }
        }
        videos.removeAll { $0.id == v.id }
        scheduleSave()
    }

    func savePosition(_ id: String, seconds: Double) {
        update(video: id) { $0.watchedSeconds = seconds }
    }

    private func update(video id: String, _ change: (inout VideoDownload) -> Void) {
        guard let i = videos.firstIndex(where: { $0.id == id }) else { return }
        change(&videos[i])
        scheduleSave()
    }

    private func fetchThumbnail(_ raw: String, for id: String) async {
        for url in Site.videoThumb(raw) {
            let req = Self.request(url)
            guard let got = await Self.get(req), case let (data, resp) = got,
                  (resp as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else { continue }
            let dest = Storage.thumbsDir.appending(path: Storage.hash(id) + ".jpg")
            try? data.write(to: dest)
            update(video: id) { $0.thumbnailFile = Storage.relative(dest) }
            return
        }
    }

    // MARK: - أحداث الجلسة (تأتي من SessionDelegate على الخيط الرئيسي)

    fileprivate func progress(id: String, fraction: Double, bytes: Int64?) {
        update(video: id) {
            $0.progress = min(max(fraction, 0), 1)
            if let bytes { $0.bytes = bytes }
            if $0.state == .queued { $0.state = .downloading }
        }
    }

    fileprivate func finished(id: String, location: URL) {
        update(video: id) {
            $0.localPath = Storage.relative(location)
            $0.bytes = Storage.size(of: location)
        }
    }

    fileprivate func completed(id: String, error: Error?) {
        tasks[id] = nil
        guard let v = videos.first(where: { $0.id == id }) else { return }
        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled { return }
            update(video: id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
            notify("فشل التحميل", v.title)
            return
        }
        guard v.localPath != nil else {
            update(video: id) { $0.state = .failed; $0.errorMessage = "لم يُحفظ الملف" }
            return
        }
        update(video: id) {
            $0.state = .completed; $0.progress = 1
            if let p = $0.localPath { $0.bytes = Storage.size(of: Storage.absolute(p)) }
        }
        Haptics.success()
        notify("اكتمل التحميل", v.title)
    }

    fileprivate func sessionFinishedEvents(_ identifier: String?) {
        guard let identifier, let done = backgroundCompletion.removeValue(forKey: identifier) else { return }
        done()
    }

    // MARK: - تحميل فصول القصص

    func isDownloaded(chapter url: String) -> ChapterDownload? {
        stories.lazy.flatMap(\.chapters).first { $0.url == url }
    }

    func story(_ url: String) -> StoryDownload? { stories.first { $0.url == url } }

    func download(chapters links: [ChapterLink], of story: CapturedStory, current: CapturedChapter? = nil) {
        requestNotificationPermission()
        var sIndex = stories.firstIndex { $0.url == story.url }
        if sIndex == nil {
            stories.insert(StoryDownload(url: story.url, title: story.title, coverFile: nil, chapters: [],
                                         allChapters: story.chapters, updatedAt: .now), at: 0)
            sIndex = 0
            if let cover = story.cover { Task { await fetchCover(cover, story: story.url) } }
        }
        guard let s = sIndex else { return }
        if !story.chapters.isEmpty { stories[s].allChapters = story.chapters }
        stories[s].updatedAt = .now

        var added = 0
        for link in links {
            if let existing = stories[s].chapters.firstIndex(where: { $0.url == link.url }) {
                if stories[s].chapters[existing].state != .failed { continue }
                stories[s].chapters.remove(at: existing)
            }
            let folder = Storage.storiesDir
                .appending(path: Storage.hash(story.url), directoryHint: .isDirectory)
                .appending(path: Storage.hash(link.url), directoryHint: .isDirectory)
            stories[s].chapters.append(ChapterDownload(
                url: link.url, title: link.title, number: link.number, folder: Storage.relative(folder),
                pageCount: 0, pages: [], state: .queued, progress: 0, createdAt: .now))
            added += 1
            let images = current?.url == link.url ? current?.images : nil
            resumeChapter(storyURL: story.url, chapterURL: link.url, knownImages: images)
        }
        scheduleSave()
        Haptics.success()
        AppModel.shared.show(added == 1 ? "بدأ تحميل الفصل" : added > 1 ? "بدأ تحميل \(added) فصل" : "الفصول محمّلة مسبقًا")
    }

    private func resumeChapter(storyURL: String, chapterURL: String, knownImages: [String]? = nil) {
        guard chapterJobs[chapterURL] == nil else { return }
        chapterJobs[chapterURL] = Task { [weak self] in
            await self?.runChapter(storyURL: storyURL, chapterURL: chapterURL, knownImages: knownImages)
            self?.chapterJobs[chapterURL] = nil
        }
    }

    private func runChapter(storyURL: String, chapterURL: String, knownImages: [String]?) async {
        // لا نحمّل أكثر من فصلين في نفس الوقت حتى لا نُثقل المصدر
        while chapterJobs.count > 2, chapterJobs.keys.sorted().prefix(2).contains(chapterURL) == false {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
        updateChapter(storyURL, chapterURL) { $0.state = .downloading }
        do {
            var images = knownImages ?? []
            if images.isEmpty {
                images = try await API.shared.chapter(chapterURL).images
            }
            guard !images.isEmpty else { throw URLError(.zeroByteResource) }
            guard let folderPath = chapter(storyURL, chapterURL)?.folder else { return }
            let folder = Storage.make(Storage.absolute(folderPath))
            updateChapter(storyURL, chapterURL) { $0.pageCount = images.count }

            var pages = [String?](repeating: nil, count: images.count)
            var done = 0
            await withTaskGroup(of: (Int, String?).self) { group in
                var next = 0
                while next < min(4, images.count) {
                    let i = next, src = images[i]
                    group.addTask { (i, await Self.fetchPage(src, chapterURL: chapterURL, index: i, folder: folder)) }
                    next += 1
                }
                while let result = await group.next() {
                    if Task.isCancelled { group.cancelAll(); return }
                    pages[result.0] = result.1
                    done += 1
                    let fraction = Double(done) / Double(images.count)
                    updateChapter(storyURL, chapterURL) { $0.progress = fraction }
                    if next < images.count {
                        let i = next, src = images[i]
                        group.addTask { (i, await Self.fetchPage(src, chapterURL: chapterURL, index: i, folder: folder)) }
                        next += 1
                    }
                }
            }
            if Task.isCancelled { return }
            let saved = pages.compactMap { $0 }
            if saved.count < max(1, images.count * 9 / 10) { throw URLError(.cannotLoadFromNetwork) }
            updateChapter(storyURL, chapterURL) {
                $0.pages = saved; $0.state = .completed; $0.progress = 1; $0.errorMessage = nil
            }
            if let s = story(storyURL), !s.chapters.contains(where: { $0.state.isActive }) {
                notify("اكتمل التحميل", s.title)
            }
        } catch {
            if Task.isCancelled { return }
            updateChapter(storyURL, chapterURL) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
        }
    }

    /// يجرب الرابط الأصلي ثم بروكسي الموقع (/api/manga-image) مثل ما يفعل الموقع نفسه.
    nonisolated private static func fetchPage(_ src: String, chapterURL: String, index: Int, folder: URL) async -> String? {
        for url in Site.mangaPage(src, chapter: chapterURL) {
            let req = Self.request(url)
            guard let got = await Self.get(req), case let (data, resp) = got,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  data.count > 200, UIImage(data: data) != nil else { continue }
            let ext = (http.mimeType ?? "").contains("png") ? "png" : (http.mimeType ?? "").contains("webp") ? "webp" : "jpg"
            let name = String(format: "%04d.%@", index, ext)
            do { try data.write(to: folder.appending(path: name)); return name } catch { return nil }
        }
        return nil
    }

    private func fetchCover(_ raw: String, story url: String) async {
        for c in Site.mangaThumb(raw, ref: url) {
            let req = Self.request(c)
            guard let got = await Self.get(req), case let (data, resp) = got,
                  (resp as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else { continue }
            let dest = Storage.thumbsDir.appending(path: "s_" + Storage.hash(url) + ".jpg")
            try? data.write(to: dest)
            if let i = stories.firstIndex(where: { $0.url == url }) { stories[i].coverFile = Storage.relative(dest) }
            scheduleSave()
            return
        }
    }

    private func chapter(_ storyURL: String, _ chapterURL: String) -> ChapterDownload? {
        story(storyURL)?.chapters.first { $0.url == chapterURL }
    }

    private func updateChapter(_ storyURL: String, _ chapterURL: String, _ change: (inout ChapterDownload) -> Void) {
        guard let s = stories.firstIndex(where: { $0.url == storyURL }),
              let c = stories[s].chapters.firstIndex(where: { $0.url == chapterURL }) else { return }
        change(&stories[s].chapters[c])
        scheduleSave()
    }

    func retry(chapter: ChapterDownload, in story: StoryDownload) {
        updateChapter(story.url, chapter.url) { $0.state = .queued; $0.progress = 0 }
        resumeChapter(storyURL: story.url, chapterURL: chapter.url)
    }

    func cancel(chapter: ChapterDownload, in story: StoryDownload) {
        chapterJobs[chapter.url]?.cancel()
        chapterJobs[chapter.url] = nil
        remove(chapter: chapter, from: story)
    }

    func remove(chapter: ChapterDownload, from story: StoryDownload) {
        chapterJobs[chapter.url]?.cancel()
        try? FileManager.default.removeItem(at: Storage.absolute(chapter.folder))
        guard let s = stories.firstIndex(where: { $0.url == story.url }) else { return }
        stories[s].chapters.removeAll { $0.url == chapter.url }
        if stories[s].chapters.isEmpty { remove(story: stories[s]) } else { scheduleSave() }
    }

    func remove(story: StoryDownload) {
        for c in story.chapters { chapterJobs[c.url]?.cancel(); chapterJobs[c.url] = nil }
        try? FileManager.default.removeItem(at: Storage.storiesDir.appending(path: Storage.hash(story.url)))
        if let cover = story.coverFile { try? FileManager.default.removeItem(at: Storage.absolute(cover)) }
        stories.removeAll { $0.url == story.url }
        scheduleSave()
    }

    func saveReadingPosition(story: String, chapter: String, page: Int) {
        updateChapter(story, chapter) { $0.lastReadPage = page }
        if let s = stories.firstIndex(where: { $0.url == story }) { stories[s].updatedAt = .now }
    }

    func deleteEverything() {
        for v in videos { remove(video: v) }
        for s in stories { remove(story: s) }
    }

    nonisolated private static func get(_ req: URLRequest) async -> (Data, URLResponse)? {
        try? await API.shared.session.data(for: req)
    }

    /// طلب يحمل كوكيز جلسة الموقع (لازم لروابط /api/stream والبروكسي).
    nonisolated static func request(_ url: URL) -> URLRequest {
        API.shared.authorized(url)
    }

    /// تحميل حلقات عمل كامل بالجودة المفضّلة (أو الأعلى).
    func downloadAll(_ episodes: [MediaItem]) {
        AppModel.shared.show("جاري تجهيز \(episodes.count) حلقة للتحميل…")
        Task {
            for ep in episodes where isDownloaded(key: ep.key) == nil {
                guard let r = try? await API.shared.resolve(ep), let v = CapturedVideo(ep, r) else { continue }
                let options = await qualityOptions(for: v)
                if let pick = autoPick(options) ?? options.first { download(v, quality: pick, quiet: true) }
            }
        }
    }

    func isDownloaded(key: String) -> VideoDownload? { videos.first { $0.id == key } }

    // MARK: - الحفظ

    private func load() {
        guard let data = try? Data(contentsOf: Storage.libraryFile),
              let snap = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) else { return }
        videos = snap.videos
        stories = snap.stories
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let snap = LibrarySnapshot(videos: videos, stories: stories)
            guard let data = try? JSONEncoder().encode(snap) else { return }
            Storage.make(Storage.libraryFile.deletingLastPathComponent())
            try? data.write(to: Storage.libraryFile, options: .atomic)
        }
    }

    // MARK: - الإشعارات

    private func requestNotificationPermission() {
        guard notifyOnFinish else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String) {
        guard notifyOnFinish else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - مندوب الجلسات (خارج الـ MainActor)

final class SessionDelegate: NSObject, AVAssetDownloadDelegate, URLSessionDownloadDelegate {

    // HLS
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        let id = assetDownloadTask.taskDescription ?? ""
        Task { @MainActor in DownloadCenter.shared.finished(id: id, location: location) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        let id = assetDownloadTask.taskDescription ?? ""
        Task { @MainActor in DownloadCenter.shared.finished(id: id, location: location) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        let id = assetDownloadTask.taskDescription ?? ""
        var loaded = 0.0
        for v in loadedTimeRanges { loaded += v.timeRangeValue.duration.seconds }
        let total = timeRangeExpectedToLoad.duration.seconds
        let fraction = total > 0 ? loaded / total : 0
        Task { @MainActor in DownloadCenter.shared.progress(id: id, fraction: fraction, bytes: nil) }
    }

    // ملفات MP4
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription ?? ""
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in DownloadCenter.shared.progress(id: id, fraction: fraction, bytes: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskDescription ?? UUID().uuidString
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
        // يجب نقل الملف قبل أن تعود هذه الدالة
        let dest = Storage.videosDir.appending(path: Storage.hash(id) + ".mp4")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in DownloadCenter.shared.finished(id: id, location: dest) }
        } catch {}
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskDescription ?? ""
        var err = error
        if err == nil, let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            err = NSError(domain: "Topdown", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: http.statusCode == 401 ? "سجّل الدخول في الموقع أولًا" : "خطأ من الخادم \(http.statusCode)"])
        }
        let final = err
        Task { @MainActor in DownloadCenter.shared.completed(id: id, error: final) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier
        Task { @MainActor in DownloadCenter.shared.sessionFinishedEvents(identifier) }
    }
}
