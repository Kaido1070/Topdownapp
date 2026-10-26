import SwiftUI

struct LibraryView: View {
    @Environment(DownloadCenter.self) private var center
    @Environment(AppModel.self) private var app
    @State private var section = 0
    @State private var query = ""
    @State private var playing: VideoDownload?

    private var videos: [VideoDownload] {
        center.videos.filter { $0.state == .completed && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }
    private var stories: [StoryDownload] {
        center.stories.filter { !$0.completedChapters.isEmpty && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("", selection: $section) {
                    Text("الفيديو (\(videos.count))").tag(0)
                    Text("القصص (\(stories.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if !app.isOnline {
                    Label("وضع عدم الاتصال — كل اللي هنا يشتغل بدون إنترنت", systemImage: "wifi.slash")
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .capsule)
                        .padding(.top, 6)
                }

                if section == 0 {
                    if videos.isEmpty {
                        EmptyLibrary(icon: "film", text: "ما فيه فيديوهات محمّلة.\nافتح أي فيديو في الموقع واضغط «تحميل».")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 16) {
                            ForEach(videos) { v in
                                VideoCard(video: v)
                                    .onTapGesture { playing = v }
                                    .contextMenu {
                                        Button("تشغيل", systemImage: "play.fill") { playing = v }
                                        if let url = v.localPath.map(Storage.absolute), v.kind == "mp4" {
                                            ShareLink(item: url) { Label("مشاركة", systemImage: "square.and.arrow.up") }
                                        }
                                        Button("حذف", systemImage: "trash", role: .destructive) { center.remove(video: v) }
                                    }
                            }
                        }
                        .padding()
                    }
                } else {
                    if stories.isEmpty {
                        EmptyLibrary(icon: "book", text: "ما فيه قصص محمّلة.\nافتح أي فصل في الموقع واضغط «تحميل».")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 14)], spacing: 18) {
                            ForEach(stories) { s in
                                NavigationLink(value: s.url) { StoryCard(story: s) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("حذف القصة", systemImage: "trash", role: .destructive) { center.remove(story: s) }
                                    }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("المكتبة")
            .searchable(text: $query, prompt: "ابحث في المحمّلات")
            .navigationDestination(for: String.self) { url in StoryDetailView(storyURL: url) }
            .fullScreenCover(item: $playing) { v in PlayerScreen(video: v) }
            .background(Theme.background.opacity(0.0001))
        }
    }
}

struct EmptyLibrary: View {
    let icon: String
    let text: String
    var body: some View {
        ContentUnavailableView {
            Label("فارغة", systemImage: icon)
        } description: {
            Text(text)
        }
        .padding(.top, 60)
    }
}

struct LocalImage: View {
    let path: String?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: path) {
            guard let path else { return }
            let url = Storage.absolute(path)
            image = await Task.detached { UIImage(contentsOfFile: url.path())?.preparingThumbnail(of: CGSize(width: 600, height: 600)) }.value
        }
    }
}

struct VideoCard: View {
    let video: VideoDownload
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalImage(path: video.thumbnailFile)
                .aspectRatio(16/9, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    Text(video.qualityLabel)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .padding(6)
                }
                .overlay {
                    Image(systemName: "play.fill").font(.title2)
                        .padding(14)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .overlay(alignment: .bottom) {
                    if let d = video.durationSeconds, d > 0, video.watchedSeconds > 5 {
                        GeometryReader { g in
                            Capsule().fill(Theme.accent)
                                .frame(width: g.size.width * min(1, video.watchedSeconds / d), height: 3)
                        }
                        .frame(height: 3)
                    }
                }
                .clipShape(.rect(cornerRadius: 16))
            Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(Storage.format(video.bytes)).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}

struct StoryCard: View {
    let story: StoryDownload
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalImage(path: story.coverFile)
                .aspectRatio(5/7, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 14))
                .overlay(alignment: .topLeading) {
                    Text("\(story.completedChapters.count)")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .padding(6)
                }
            Text(story.title).font(.footnote.weight(.semibold)).lineLimit(2)
        }
    }
}

struct StoryDetailView: View {
    let storyURL: String
    @Environment(DownloadCenter.self) private var center
    @Environment(AppModel.self) private var app

    var body: some View {
        if let story = center.story(storyURL) {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        LocalImage(path: story.coverFile)
                            .frame(width: 96, height: 134)
                            .clipShape(.rect(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(story.title).font(.title3.bold())
                            Text("\(story.completedChapters.count) فصل محمّل").foregroundStyle(.secondary)
                            if let resume = story.sortedChapters.last(where: { $0.lastReadPage > 0 && $0.state == .completed })
                                ?? story.completedChapters.first {
                                NavigationLink {
                                    ReaderView(storyURL: story.url, chapterURL: resume.url)
                                } label: {
                                    Label(resume.lastReadPage > 0 ? "متابعة " + resume.displayTitle : "ابدأ القراءة",
                                          systemImage: "book.fill")
                                }
                                .buttonStyle(.glassProminent)
                            }
                        }
                    }
                }
                Section("الفصول") {
                    ForEach(story.sortedChapters) { c in
                        ChapterRow(chapter: c, story: story)
                    }
                    .onDelete { idx in
                        for i in idx { center.remove(chapter: story.sortedChapters[i], from: story) }
                    }
                }
                let missing = story.allChapters.filter { link in !story.chapters.contains { $0.url == link.url } }
                if !missing.isEmpty && app.isOnline {
                    Section {
                        Button("تحميل باقي الفصول (\(missing.count))", systemImage: "arrow.down.circle") {
                            center.download(chapters: missing,
                                            of: CapturedStory(title: story.title, url: story.url, cover: nil, chapters: story.allChapters))
                        }
                    }
                }
            }
            .navigationTitle(story.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("القصة غير موجودة", systemImage: "book.closed")
        }
    }
}

private struct ChapterRow: View {
    let chapter: ChapterDownload
    let story: StoryDownload
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        if chapter.state == .completed {
            NavigationLink {
                ReaderView(storyURL: story.url, chapterURL: chapter.url)
            } label: {
                HStack {
                    Text(chapter.displayTitle)
                    Spacer()
                    if chapter.lastReadPage > 0 {
                        Text("ص \(chapter.lastReadPage + 1)/\(chapter.pages.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            HStack {
                Text(chapter.displayTitle)
                Spacer()
                if chapter.state == .failed {
                    Button("إعادة", systemImage: "arrow.clockwise") { center.retry(chapter: chapter, in: story) }
                        .buttonStyle(.glass)
                } else {
                    ProgressView(value: chapter.progress).frame(width: 80)
                }
            }
        }
    }
}
