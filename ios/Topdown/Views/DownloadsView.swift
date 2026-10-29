import SwiftUI

struct DownloadsList: View {
    @Environment(DownloadCenter.self) private var center
    @Environment(AppModel.self) private var app

    private var activeVideos: [VideoDownload] { center.videos.filter { $0.state != .completed } }
    private var activeChapters: [(StoryDownload, ChapterDownload)] {
        center.chapterQueue + center.stories.flatMap { s in s.chapters.filter { $0.state == .failed }.map { (s, $0) } }
    }

    var body: some View {
        VStack(spacing: 12) {
            if activeVideos.isEmpty && activeChapters.isEmpty {
                ContentUnavailableView("لا توجد تحميلات جارية", systemImage: "arrow.down.circle",
                                       description: Text("التحميلات المكتملة تظهر في تبويب الفيديو والقصص."))
                    .padding(.top, 40)
            }
            ForEach(activeVideos) { v in
                VideoRow(video: v).padding(14).glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            if !activeChapters.isEmpty { ChapterQueueHeader() }
            ForEach(activeChapters, id: \.1.url) { pair in
                ChapterProgressRow(story: pair.0, chapter: pair.1)
                    .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            HStack {
                Label(center.storageSummary, systemImage: "internaldrive")
                Spacer()
                Text("\(center.videos.filter { $0.state == .completed }.count) فيديو • \(center.stories.flatMap(\.completedChapters).count) فصل")
            }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .padding(.horizontal)
    }
}

/// تحكم بالطابور: عدد التحميلات المتزامنة + إيقاف/استئناف الكل + جودة التحميل الحالية.
private struct ChapterQueueHeader: View {
    @Environment(DownloadCenter.self) private var center
    @AppStorage("stories.parallel") private var parallel = 2
    @AppStorage("stories.quality") private var quality = StoryImageQuality.balanced.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("فصول القصص", systemImage: "books.vertical.fill").font(.headline)
                Spacer()
                let anyRunning = center.chapterQueue.contains { $0.1.state != .paused }
                Button(anyRunning ? "إيقاف الكل" : "استئناف الكل", systemImage: anyRunning ? "pause.fill" : "play.fill") {
                    anyRunning ? center.pauseAllChapters() : center.resumeAllChapters()
                }
                .buttonStyle(.glass)
                .font(.footnote)
            }
            HStack {
                Stepper(value: $parallel, in: 1...3) {
                    Text("تحميل \(parallel) \(parallel == 1 ? "فصل" : "فصول") في نفس الوقت").font(.subheadline)
                }
                .onChange(of: parallel) { _, _ in center.pumpChapters() }
            }
            Text("الجودة: " + (StoryImageQuality(rawValue: quality) ?? .balanced).name + " — تغيّرها من الإعدادات")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// صف فصل: نسبة حقيقية (صفحات مكتملة/الكل) + الحجم + السرعة + أولوية/إيقاف/إلغاء.
private struct ChapterProgressRow: View {
    let story: StoryDownload
    let chapter: ChapterDownload
    @Environment(DownloadCenter.self) private var center

    private var running: Bool { center.isRunning(chapter.url) }
    private var percent: Int { Int((chapter.progress * 100).rounded(.down)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                LocalImage(path: story.coverFile)
                    .frame(width: 44, height: 62)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(story.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(chapter.displayTitle).font(.caption).foregroundStyle(.secondary)
                    Text(status).font(.caption2).foregroundStyle(statusColor)
                }
                Spacer(minLength: 4)
                Text("\(percent)٪")
                    .font(.title2.bold().monospacedDigit())
                    .contentTransition(.numericText(value: Double(percent)))
                    .foregroundStyle(chapter.state == .failed ? .red : running ? Theme.accent : .secondary)
                    .animation(.smooth, value: percent)
            }

            ProgressView(value: chapter.progress)
                .tint(chapter.state == .failed ? .red : Theme.accent)
                .animation(.smooth, value: chapter.progress)

            HStack(spacing: 8) {
                Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if chapter.state == .failed {
                    small("إعادة", "arrow.clockwise") { center.retry(chapter: chapter, in: story) }
                } else {
                    if !running || chapter.state == .paused {
                        small("حمّل الآن", "arrow.up.to.line") { center.prioritize(chapter: chapter.url) }
                    }
                    if chapter.state == .paused {
                        small("استئناف", "play.fill") { center.resume(chapter: chapter.url) }
                    } else {
                        small("إيقاف", "pause.fill") { center.pause(chapter: chapter.url) }
                    }
                }
                Button(role: .destructive) { center.cancel(chapter: chapter, in: story) } label: {
                    Image(systemName: "xmark").font(.caption.bold()).frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
        }
    }

    private var status: String {
        switch chapter.state {
        case .failed: return chapter.errorMessage ?? "فشل التحميل"
        case .paused: return "متوقف مؤقتًا"
        case .completed: return "مكتمل"
        default:
            if running { return "جارٍ التحميل" }
            if let p = center.queuePosition(chapter.url) { return "في الانتظار — الدور \(p)" }
            return "في الانتظار"
        }
    }

    private var statusColor: Color {
        switch chapter.state {
        case .failed: .red
        case .paused: .orange
        default: running ? Theme.accent : .secondary
        }
    }

    private var detail: String {
        var parts: [String] = []
        if chapter.pageCount > 0 { parts.append("\(chapter.pagesDone ?? 0)/\(chapter.pageCount) صفحة") }
        if let b = chapter.bytes, b > 0 { parts.append(Storage.format(b)) }
        if running, let sp = center.chapterSpeed[chapter.url], sp > 0 {
            parts.append(Storage.format(Int64(sp)) + "/ث")
            if chapter.pageCount > 0, let done = chapter.pagesDone, done > 0, let b = chapter.bytes {
                let remaining = Double(b) / Double(done) * Double(chapter.pageCount - done)
                let secs = Int(remaining / sp)
                if secs > 0 { parts.append("باقي " + (secs >= 60 ? "\(secs / 60) د" : "\(secs) ث")) }
            }
        }
        if let q = chapter.quality, let qq = StoryImageQuality(rawValue: q) { parts.append(qq.name) }
        return parts.joined(separator: " • ")
    }

    private func small(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.caption.bold()) }
            .buttonStyle(.glass)
            .controlSize(.small)
    }
}

private struct VideoRow: View {
    let video: VideoDownload
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        HStack(spacing: 12) {
            LocalImage(path: video.thumbnailFile)
                .frame(width: 88, height: 50)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack {
                    Text(video.qualityLabel)
                    Text(status)
                }
                .font(.caption).foregroundStyle(video.state == .failed ? .red : .secondary)
                if video.state != .failed {
                    ProgressView(value: video.progress).tint(Theme.accent)
                }
            }
            Group {
                switch video.state {
                case .downloading, .queued:
                    Button { center.pause(video) } label: { Image(systemName: "pause.fill") }
                case .paused:
                    Button { center.resume(video) } label: { Image(systemName: "play.fill") }
                case .failed:
                    Button { center.retry(video) } label: { Image(systemName: "arrow.clockwise") }
                case .completed:
                    EmptyView()
                }
            }
            .buttonStyle(.glass)
            Button(role: .destructive) { center.remove(video: video) } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
        }
    }

    private var status: String {
        switch video.state {
        case .queued: "في الانتظار"
        case .downloading: "\(Int(video.progress * 100))٪" + (video.bytes > 0 ? " • " + Storage.format(video.bytes) : "")
        case .paused: "متوقف مؤقتًا"
        case .failed: video.errorMessage ?? "فشل"
        case .completed: "مكتمل"
        }
    }
}
