import SwiftUI

struct DownloadsList: View {
    @Environment(DownloadCenter.self) private var center
    @Environment(AppModel.self) private var app

    private var activeVideos: [VideoDownload] { center.videos.filter { $0.state != .completed } }
    private var activeChapters: [(StoryDownload, ChapterDownload)] {
        center.stories.flatMap { s in s.chapters.filter { $0.state != .completed }.map { (s, $0) } }
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

private struct ChapterProgressRow: View {
    let story: StoryDownload
    let chapter: ChapterDownload
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(story.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(chapter.displayTitle + (chapter.pageCount > 0 ? " • \(chapter.pageCount) صفحة" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if chapter.state == .failed {
                    Text(chapter.errorMessage ?? "فشل").font(.caption).foregroundStyle(.red)
                } else {
                    ProgressView(value: chapter.progress).tint(Theme.accent)
                }
            }
            if chapter.state == .failed {
                Button { center.retry(chapter: chapter, in: story) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass)
            }
            Button(role: .destructive) { center.cancel(chapter: chapter, in: story) } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
        }
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
