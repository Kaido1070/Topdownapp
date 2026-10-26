import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadCenter.self) private var center
    @Environment(AppModel.self) private var app

    private var activeVideos: [VideoDownload] { center.videos.filter { $0.state != .completed } }
    private var activeChapters: [(StoryDownload, ChapterDownload)] {
        center.stories.flatMap { s in s.chapters.filter { $0.state != .completed }.map { (s, $0) } }
    }

    var body: some View {
        NavigationStack {
            List {
                if activeVideos.isEmpty && activeChapters.isEmpty {
                    ContentUnavailableView {
                        Label("لا توجد تحميلات جارية", systemImage: "arrow.down.circle")
                    } description: {
                        Text("التحميلات المكتملة تجدها في المكتبة.")
                    } actions: {
                        Button("فتح المكتبة") { app.tab = .library }.buttonStyle(.glassProminent)
                    }
                    .listRowBackground(Color.clear)
                }
                if !activeVideos.isEmpty {
                    Section("الفيديو") {
                        ForEach(activeVideos) { v in VideoRow(video: v) }
                    }
                }
                if !activeChapters.isEmpty {
                    Section("القصص") {
                        ForEach(activeChapters, id: \.1.url) { s, c in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(c.displayTitle + (c.pageCount > 0 ? " • \(c.pageCount) صفحة" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if c.state == .failed {
                                        Text(c.errorMessage ?? "فشل").font(.caption).foregroundStyle(.red)
                                    } else {
                                        ProgressView(value: c.progress).tint(Theme.accent)
                                    }
                                }
                                if c.state == .failed {
                                    Button { center.retry(chapter: c, in: s) } label: { Image(systemName: "arrow.clockwise") }
                                        .buttonStyle(.glass)
                                }
                                Button(role: .destructive) { center.cancel(chapter: c, in: s) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.glass)
                            }
                        }
                    }
                }
                Section("المساحة") {
                    LabeledContent("المستخدم", value: center.storageSummary)
                    LabeledContent("فيديوهات", value: "\(center.videos.filter { $0.state == .completed }.count)")
                    LabeledContent("فصول", value: "\(center.stories.flatMap(\.completedChapters).count)")
                }
            }
            .navigationTitle("التحميلات")
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
