import SwiftUI

/// صفحة القصة: الغلاف، الملخص، الفصول، الحفظ، المتابعة والتحميل.
struct StoryScreen: View {
    let item: StoryItem
    @Environment(Library.self) private var library
    @Environment(DownloadCenter.self) private var center
    @State private var detail: StoryDetail?
    @State private var error: String?
    @State private var query = ""
    @State private var ascending = false
    @State private var summaryExpanded = false

    private var story: StoryItem {
        var s = item
        if let d = detail { s.title = d.title; s.cover = d.cover ?? item.cover; s.latestChapter = d.latestChapter ?? item.latestChapter }
        return s
    }
    private var chapters: [ChapterLink] { detail?.chapters.values ?? [] }
    private var reading: [ChapterLink] { chapters.sorted { ($0.number ?? .infinity) < ($1.number ?? .infinity) } }
    private var shown: [ChapterLink] {
        let sorted = chapters.sorted { ascending ? ($0.number ?? -1) < ($1.number ?? -1) : ($0.number ?? -1) > ($1.number ?? -1) }
        let q = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !q.isEmpty else { return sorted }
        if let n = Double(q) { return sorted.filter { $0.number.map { abs($0 - n) < 0.000001 } ?? false } }
        return sorted.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
    private var lastRead: ChapterLink? {
        guard let h = library.storyHistory.first(where: { $0.url == item.url }), let u = h.lastChapterUrl else { return nil }
        return chapters.first { $0.url == u }
    }
    private var captured: CapturedStory { CapturedStory(title: story.title, url: story.url, cover: story.cover, chapters: chapters) }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    RemoteImage(urls: Site.mangaThumb(story.cover, ref: item.url), maxPixel: 600)
                        .frame(width: 118, height: 166)
                        .clipShape(.rect(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(story.title).font(.title3.bold()).lineLimit(4)
                        if detail != nil { Text("\(chapters.count) فصل").foregroundStyle(Theme.accent).font(.subheadline) }
                        Button { library.toggleSaved(story) } label: {
                            Label(library.isSaved(story) ? "محفوظة" : "حفظ", systemImage: library.isSaved(story) ? "star.fill" : "star")
                        }
                        .buttonStyle(.glass)
                    }
                }
                .listRowBackground(Color.clear)

                if let summary = detail?.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(summaryExpanded ? nil : 4)
                        .onTapGesture { withAnimation { summaryExpanded.toggle() } }
                }

                if !reading.isEmpty {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            if let last = lastRead {
                                NavigationLink(value: Route.reader(story, reading, last.url)) {
                                    Label("متابعة " + last.displayTitle, systemImage: "book.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent)
                            } else if let first = reading.first {
                                NavigationLink(value: Route.reader(story, reading, first.url)) {
                                    Label("ابدأ القراءة", systemImage: "book.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent)
                            }
                            if let latest = reading.last, latest.url != lastRead?.url {
                                NavigationLink(value: Route.reader(story, reading, latest.url)) {
                                    Label("الأحدث", systemImage: "sparkles").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                        .controlSize(.large)
                    }
                    .listRowBackground(Color.clear)
                }
            }

            if detail == nil && error == nil {
                HStack { ProgressView(); Text("جاري جلب الفصول…").foregroundStyle(.secondary) }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("إعادة المحاولة") { Task { await load() } }
            }
            if let w = detail?.chaptersWarning { Text(w).font(.footnote).foregroundStyle(.secondary) }

            if !chapters.isEmpty {
                Section {
                    ForEach(shown) { c in
                        NavigationLink(value: Route.reader(story, reading, c.url)) {
                            HStack(spacing: 12) {
                                Text(c.number.map { ChapterDownload.format($0) } ?? "—")
                                    .font(.headline.monospacedDigit()).foregroundStyle(Theme.accent)
                                    .frame(minWidth: 44)
                                Text(c.title.isEmpty ? c.displayTitle : c.title).lineLimit(1)
                                Spacer()
                                if let d = center.isDownloaded(chapter: c.url) {
                                    Image(systemName: d.state == .completed ? "arrow.down.circle.fill" : "arrow.down.circle.dotted")
                                        .foregroundStyle(Theme.accent)
                                } else if let p = c.publishedAt {
                                    Text(p).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("تحميل", systemImage: "arrow.down") { center.download(chapters: [c], of: captured) }
                                .tint(Theme.accent)
                        }
                    }
                } header: {
                    HStack {
                        Text("الفصول")
                        Spacer()
                        Button(ascending ? "الأقدم أولاً" : "الأحدث أولاً", systemImage: "arrow.up.arrow.down") {
                            withAnimation { ascending.toggle() }
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .navigationTitle(story.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "رقم الفصل")
        .keyboardType(.decimalPad)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    let missing = chapters.filter { center.isDownloaded(chapter: $0.url)?.state != .completed }
                    Button("تحميل كل الفصول (\(missing.count))", systemImage: "books.vertical") {
                        center.download(chapters: missing, of: captured)
                    }
                    .disabled(missing.isEmpty)
                    if let last = lastRead, let n = last.number {
                        let next = reading.filter { ($0.number ?? 0) > n }.prefix(10)
                        Button("تحميل الفصول العشرة التالية", systemImage: "forward.end") {
                            center.download(chapters: Array(next), of: captured)
                        }
                        .disabled(next.isEmpty)
                    }
                } label: { Image(systemName: "arrow.down.circle") }
                .disabled(chapters.isEmpty)
            }
        }
        .task { if detail == nil { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        error = nil
        do { detail = try await API.shared.story(item.url) }
        catch {
            // بدون إنترنت: نعرض الفصول المحمّلة
            if let offline = center.story(item.url) {
                detail = nil
                self.error = "أنت غير متصل — الفصول المحمّلة متاحة في التحميلات (\(offline.completedChapters.count))"
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}

/// قارئ الفصول: يقرأ من التحميلات إن وُجدت، وإلا من الإنترنت مع بدائل الصور مثل الموقع.
struct ReaderScreen: View {
    let story: StoryItem
    let chapters: [ChapterLink]
    @State private var url: String
    @Environment(Library.self) private var library
    @Environment(DownloadCenter.self) private var center
    @State private var images: [String] = []
    @State private var error: String?
    @State private var chromeHidden = false
    @State private var page = 0

    init(story: StoryItem, chapters: [ChapterLink], startURL: String) {
        self.story = story
        self.chapters = chapters
        _url = State(initialValue: startURL)
    }

    private var index: Int? { chapters.firstIndex { $0.url == url } }
    private var current: ChapterLink { index.map { chapters[$0] } ?? ChapterLink(url: url, title: "") }
    private var previous: ChapterLink? { index.flatMap { $0 > 0 ? chapters[$0 - 1] : nil } }
    private var next: ChapterLink? { index.flatMap { $0 + 1 < chapters.count ? chapters[$0 + 1] : nil } }
    private var local: ChapterDownload? { center.isDownloaded(chapter: url).flatMap { $0.state == .completed ? $0 : nil } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 1).id("top")
                    if let local {
                        ForEach(Array(local.pages.enumerated()), id: \.offset) { i, name in
                            LocalPage(url: Storage.absolute(local.folder).appending(path: name))
                                .onAppear { page = i }
                        }
                    } else if !images.isEmpty {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, src in
                            RemoteImage(urls: Site.mangaPage(src, chapter: url), maxPixel: 1800, contentMode: .fit)
                                .frame(minHeight: 300)
                                .onAppear { page = i }
                        }
                    } else if let error {
                        ContentUnavailableView {
                            Label("تعذّر فتح الفصل", systemImage: "exclamationmark.triangle")
                        } description: { Text(error) } actions: {
                            Button("إعادة المحاولة") { Task { await load() } }.buttonStyle(.glassProminent)
                        }
                        .padding(.top, 120)
                    } else {
                        ProgressView().controlSize(.large).padding(.top, 200)
                    }
                    footer.padding(.vertical, 40)
                }
            }
            .background(.black)
            .scrollIndicators(.hidden)
            .onTapGesture { withAnimation(.smooth) { chromeHidden.toggle() } }
            .onChange(of: url) { _, _ in proxy.scrollTo("top", anchor: .top) }
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(current.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar, .tabBar)
        .statusBarHidden(chromeHidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if local == nil {
                    Button {
                        center.download(chapters: [current], of: CapturedStory(title: story.title, url: story.url, cover: story.cover, chapters: chapters),
                                        current: CapturedChapter(url: url, title: current.title, images: images))
                    } label: { Image(systemName: center.isDownloaded(chapter: url) == nil ? "arrow.down.circle" : "arrow.down.circle.dotted") }
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !chromeHidden {
                let count = local?.pages.count ?? images.count
                if count > 0 {
                    Text("\(page + 1) / \(count)")
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 30)
                }
            }
        }
        .task(id: url) { await load() }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Text("نهاية " + current.displayTitle).foregroundStyle(.secondary)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("السابق", systemImage: "chevron.backward") { if let p = previous { url = p.url } }
                        .buttonStyle(.glass).disabled(previous == nil)
                    Button("التالي", systemImage: "chevron.forward") { if let n = next { url = n.url } }
                        .buttonStyle(.glassProminent).disabled(next == nil)
                }
                .controlSize(.large)
            }
        }
    }

    private func load() async {
        error = nil
        images = []
        page = 0
        library.recordRead(story, chapter: current)
        if let local {
            center.saveReadingPosition(story: story.url, chapter: local.url, page: 0)
            return
        }
        do { images = try await API.shared.chapter(url).images }
        catch { self.error = error.localizedDescription }
    }
}

private struct LocalPage: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Color.black.frame(height: 400).overlay(ProgressView()) }
        }
        .frame(maxWidth: .infinity)
        .task(id: url) {
            image = await Task.detached { UIImage(contentsOfFile: url.path())?.preparingForDisplay() }.value
        }
    }
}
