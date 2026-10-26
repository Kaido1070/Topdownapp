import SwiftUI

enum Route: Hashable {
    case video(MediaItem)
    case work(MediaItem)
    case story(StoryItem)
    case reader(StoryItem, [ChapterLink], String)
    case favorites, history, savedStories, storyHistory, sources
}

extension View {
    func topdownDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .video(let item): VideoScreen(item: item)
            case .work(let item): WorkScreen(item: item)
            case .story(let item): StoryScreen(item: item)
            case .reader(let story, let chapters, let url): ReaderScreen(story: story, chapters: chapters, startURL: url)
            case .favorites: FavoritesScreen()
            case .history: HistoryScreen()
            case .savedStories: SavedStoriesScreen()
            case .storyHistory: StoryHistoryScreen()
            case .sources: SourcesScreen()
            }
        }
    }
}

// MARK: - مبدّل الأنمي / القصص

struct ModeSwitch: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var app = app
        Picker("المحتوى", selection: $app.mode.animation(.smooth)) {
            Label("الأنمي", systemImage: "play.rectangle.fill").tag(BrowseMode.anime)
            Label("القصص", systemImage: "book.fill").tag(BrowseMode.stories)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }
}

// MARK: - استكشف

struct ExploreView: View {
    @Environment(AppModel.self) private var app
    @State private var anime = AnimeFeed()
    @State private var stories = StoryFeed()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 14) {
                    ModeSwitch()
                    if !app.isOnline { OfflineBanner() }
                    if app.mode == .anime {
                        AnimeFilters(feed: anime, explore: true)
                        VideoGrid(feed: anime)
                    } else {
                        StoryFilters(feed: stories)
                        StoryGrid(feed: stories)
                    }
                }
                .padding(.bottom, 30)
            }
            .navigationTitle("استكشف")
            .refreshable {
                if app.mode == .anime { await anime.reload() } else { await stories.reload() }
            }
            .topdownDestinations()
            .task { if anime.items.isEmpty && !anime.loading { await anime.reload() } }
            .task(id: app.mode) {
                if app.mode == .stories && stories.items.isEmpty && !stories.loading {
                    await stories.loadGenres()
                    await stories.reload()
                }
            }
        }
    }
}

struct OfflineBanner: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Button { app.tab = .library } label: {
            Label("أنت غير متصل — افتح التحميلات لمشاهدة المحمّل", systemImage: "wifi.slash")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .tint(.orange)
    }
}

// MARK: - الفلاتر

struct FilterChip<Content: View>: View {
    let title: String
    let value: String
    var active = false
    @ViewBuilder let content: Content

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                Text(value).fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.caption2.bold())
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassEffect(active ? .regular.tint(Theme.accent.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

struct AnimeFilters: View {
    @Bindable var feed: AnimeFeed
    var explore: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    FilterChip(title: "المصدر", value: feed.source.name, active: feed.source != .all) {
                        Picker("المصدر", selection: $feed.source) {
                            ForEach(AnimeSource.allCases) { Text($0.name).tag($0) }
                        }
                    }
                    if explore {
                        FilterChip(title: "الترتيب", value: sortName, active: feed.sort != "latest") {
                            Picker("الترتيب", selection: $feed.sort) {
                                Text("الأحدث").tag("latest")
                                Text("الأكثر شهرة").tag("popular")
                                Text("الأكثر متابعة").tag("most-viewed")
                            }
                        }
                        .disabled(feed.source != .legacy)
                        FilterChip(title: "المدة", value: feed.duration.name, active: feed.duration != .all) {
                            Picker("المدة", selection: $feed.duration) {
                                ForEach(DurationFilter.allCases) { Text($0.name).tag($0) }
                            }
                        }
                        FilterChip(title: "التصنيف", value: feed.tag.isEmpty ? "الكل" : feed.tag, active: !feed.tag.isEmpty) {
                            Picker("التصنيف", selection: $feed.tag) {
                                Text("كل التصنيفات").tag("")
                                ForEach(feed.allTags, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        if feed.activeFilterCount > 0 {
                            Button("مسح", systemImage: "xmark.circle.fill") {
                                feed.sort = "latest"; feed.duration = .all; feed.tag = ""
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .onChange(of: feed.source) { _, s in
            if s != .legacy { feed.sort = "latest" }
            feed.tag = ""
            if explore || !feed.query.isEmpty { Task { await feed.reload() } }
        }
        .onChange(of: feed.sort) { _, _ in if explore { Task { await feed.reload() } } }
        .onChange(of: feed.duration) { _, _ in feed.rebuild() }
        .onChange(of: feed.tag) { _, _ in feed.rebuild() }
    }

    private var sortName: String {
        switch feed.sort { case "popular": "الأكثر شهرة"; case "most-viewed": "الأكثر متابعة"; default: "الأحدث" }
    }
}

struct StoryFilters: View {
    @Bindable var feed: StoryFeed
    var explore = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    FilterChip(title: "المصدر", value: feed.source.name, active: feed.source != .all) {
                        Picker("المصدر", selection: $feed.source) {
                            ForEach(StorySource.allCases) { Text($0.name).tag($0) }
                        }
                    }
                    FilterChip(title: "الترتيب", value: orderName, active: feed.order != "source") {
                        Picker("الترتيب", selection: $feed.order) {
                            Text("ترتيب المصدر").tag("source")
                            if feed.supports("latest") { Text("الأحدث").tag("latest") }
                            if feed.supports("popular") { Text("الأكثر شهرة").tag("popular") }
                            if feed.supports("views") { Text("الأكثر مشاهدة").tag("views") }
                        }
                    }
                    if feed.source == .legacy && !feed.genres.isEmpty {
                        FilterChip(title: "التصنيف", value: feed.genres.first { $0.id == feed.genre }?.name ?? "الكل", active: !feed.genre.isEmpty) {
                            Picker("التصنيف", selection: $feed.genre) {
                                Text("كل التصنيفات").tag("")
                                ForEach(feed.genres) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .onChange(of: feed.source) { _, _ in
            feed.order = "source"
            if explore || !feed.query.isEmpty { Task { await feed.reload() } }
        }
        .onChange(of: feed.genre) { _, _ in if explore || !feed.query.isEmpty { Task { await feed.reload() } } }
    }

    private var orderName: String {
        switch feed.order { case "latest": "الأحدث"; case "popular": "الأكثر شهرة"; case "views": "الأكثر مشاهدة"; default: "المصدر" }
    }
}

// MARK: - الشبكات

struct FeedStatus: View {
    let loading: Bool
    let errors: [String]
    let empty: Bool
    let retry: () async -> Void

    var body: some View {
        if loading && empty {
            VStack(spacing: 12) { ProgressView().controlSize(.large).tint(Theme.accent); Text("جاري التحميل…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity).padding(.top, 80)
        } else if empty {
            ContentUnavailableView {
                Label(errors.isEmpty ? "لا توجد نتائج" : "تعذّر التحميل", systemImage: errors.isEmpty ? "tray" : "exclamationmark.icloud")
            } description: {
                Text(errors.joined(separator: "\n"))
            } actions: {
                Button("إعادة المحاولة", systemImage: "arrow.clockwise") { Task { await retry() } }
                    .buttonStyle(.glassProminent)
            }
            .padding(.top, 40)
        } else if !errors.isEmpty {
            DisclosureGroup("بعض المصادر لم تستجب (\(errors.count))") {
                Text(errors.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
            }
            .font(.footnote)
            .padding(.horizontal)
        }
    }
}

struct VideoGrid: View {
    var feed: AnimeFeed

    var body: some View {
        FeedStatus(loading: feed.loading, errors: feed.errors, empty: feed.items.isEmpty) { await feed.reload() }
        if !feed.items.isEmpty {
            Text("\(feed.items.count) نتيجة").font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 14)], spacing: 18) {
            ForEach(feed.items, id: \.key) { item in
                VideoCard(item: item)
                    .onAppear { if item.key == feed.items.last?.key { Task { await feed.loadMore() } } }
            }
        }
        .padding(.horizontal)
        if feed.loadingMore { ProgressView().padding() }
        if !feed.related.isEmpty {
            SectionHeader(title: "نتائج مرتبطة")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 14)], spacing: 18) {
                ForEach(feed.related, id: \.key) { VideoCard(item: $0) }
            }
            .padding(.horizontal)
        }
    }
}

struct StoryGrid: View {
    var feed: StoryFeed

    var body: some View {
        FeedStatus(loading: feed.loading, errors: feed.errors, empty: feed.items.isEmpty) { await feed.reload() }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 14)], spacing: 18) {
            ForEach(feed.sorted) { item in
                StoryCardView(item: item)
                    .onAppear { if item.url == feed.items.last?.url { Task { await feed.loadMore() } } }
            }
        }
        .padding(.horizontal)
        if feed.loadingMore { ProgressView().padding() }
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var route: Route? = nil
    var body: some View {
        HStack {
            Text(title).font(.title3.bold())
            if let count { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
            if let route {
                NavigationLink(value: route) { Text("عرض الكل").font(.subheadline) }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// MARK: - البطاقات

struct VideoCard: View {
    let item: MediaItem
    var width: CGFloat? = nil
    @Environment(Library.self) private var library
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        NavigationLink(value: item.opensDetails ? Route.work(item) : Route.video(item)) {
            VStack(alignment: .leading, spacing: 7) {
                RemoteImage(urls: Site.videoThumb(item.thumbnail), maxPixel: 520)
                    .aspectRatio(16/10, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 4) {
                            if let d = item.durationText { Badge(text: d) }
                            if center.isDownloaded(key: item.key)?.state == .completed { Badge(text: "محمّل", icon: "arrow.down.circle.fill") }
                        }
                        .padding(6)
                    }
                    .overlay(alignment: .topTrailing) {
                        if item.opensDetails { Badge(text: "حلقات", icon: "list.bullet").padding(6) }
                    }
                    .clipShape(.rect(cornerRadius: 16))
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Text(item.sourceName).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: width)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(library.isFavorite(item) ? "إزالة من المفضلة" : "إضافة للمفضلة",
                   systemImage: library.isFavorite(item) ? "star.slash" : "star") { library.toggleFavorite(item) }
            if let u = item.embed.flatMap(URL.init(string:)) {
                ShareLink(item: u) { Label("مشاركة الرابط", systemImage: "square.and.arrow.up") }
            }
        } preview: {
            VideoPreview(item: item)
        }
    }
}

struct Badge: View {
    let text: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 7).padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }
}

struct StoryCardView: View {
    let item: StoryItem
    var width: CGFloat? = nil
    @Environment(Library.self) private var library
    @State private var fallback: [URL] = []

    var body: some View {
        NavigationLink(value: Route.story(item)) {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(urls: Site.mangaThumb(item.cover, ref: item.url) + fallback, maxPixel: 420)
                    .aspectRatio(5/7, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 14))
                    .task(id: item.url) {
                        guard item.cover == nil || item.cover?.isEmpty == true, fallback.isEmpty,
                              let covers = try? await API.shared.storyCovers(item.url) else { return }
                        fallback = covers.flatMap { Site.mangaThumb($0, ref: item.url) }
                    }
                    .overlay(alignment: .topLeading) {
                        if library.isSaved(item) {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.accent)
                                .padding(6).glassEffect(.regular, in: .circle).padding(5)
                        }
                    }
                Text(item.title).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                if let n = item.latestChapter {
                    Text("أحدث فصل: " + ChapterDownload.format(n)).font(.caption2).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: width)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(library.isSaved(item) ? "إزالة من المحفوظات" : "حفظ القصة",
                   systemImage: library.isSaved(item) ? "star.slash" : "star") { library.toggleSaved(item) }
        }
    }
}

// MARK: - البحث

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var anime = AnimeFeed()
    @State private var stories = StoryFeed()
    @State private var text = ""
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ModeSwitch()
                    if app.mode == .anime {
                        AnimeFilters(feed: anime, explore: false)
                        if submitted { VideoGrid(feed: anime) } else { hint }
                    } else {
                        StoryFilters(feed: stories, explore: false)
                        if submitted { StoryGrid(feed: stories) } else { hint }
                    }
                }
                .padding(.bottom, 30)
            }
            .navigationTitle("البحث")
            .searchable(text: $text, prompt: app.mode == .anime ? "ابحث باسم العمل" : "ابحث عن قصة")
            .onSubmit(of: .search) { run() }
            .onChange(of: app.mode) { _, _ in if submitted { run() } }
            .topdownDestinations()
        }
    }

    private var hint: some View {
        ContentUnavailableView("ابحث في كل المصادر", systemImage: "magnifyingglass",
                               description: Text(app.mode == .anime ? "الأنمي من المصدر القديم والمصادر الجديدة" : "القصص من كل المصادر"))
            .padding(.top, 60)
    }

    private func run() {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        submitted = true
        Task {
            if app.mode == .anime { anime.query = q; await anime.reload() }
            else { stories.query = q; await stories.reload() }
        }
    }
}
