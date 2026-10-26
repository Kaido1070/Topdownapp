import SwiftUI

/// قارئ الفصول بملء الشاشة. شريط زجاجي واحد ملتصق بأعلى الشاشة:
/// الصف الأول رجوع + عنوان الفصل وعدّاد الصفحات + الخيارات،
/// والصف الثاني السابق | الفصول | التالي. يختفي عند النزول ويعود بتمرير مقصود للأعلى.
struct ReaderScreen: View {
    let request: ReaderRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @Environment(DownloadCenter.self) private var center
    @Environment(AppModel.self) private var app

    @State private var url: String
    @State private var images: [String] = []
    @State private var error: String?
    @State private var page = 0
    @State private var controls = true
    @State private var direction = ReaderScrollDirection()
    @State private var headerHeight: CGFloat = 120
    @State private var choosingChapter = false
    @State private var chapterQuery = ""
    @State private var initialPage = 0
    @State private var ready = false

    @AppStorage("reader.keepAwake") private var keepAwake = true
    @AppStorage("reader.dim") private var dim = 0.0

    init(request: ReaderRequest) {
        self.request = request
        _url = State(initialValue: request.url)
    }

    private var chapters: [ChapterLink] { request.chapters }
    private var index: Int? { chapters.firstIndex { $0.url == url } }
    private var current: ChapterLink { index.map { chapters[$0] } ?? ChapterLink(url: url, title: "") }
    private var previous: ChapterLink? { index.flatMap { $0 > 0 ? chapters[$0 - 1] : nil } }
    private var next: ChapterLink? { index.flatMap { $0 + 1 < chapters.count ? chapters[$0 + 1] : nil } }
    private var local: ChapterDownload? { center.isDownloaded(chapter: url).flatMap { $0.state == .completed ? $0 : nil } }

    /// «الفصل 12 · العنوان» إذا كان للفصل عنوان غير الرقم (مثل Rany)
    private var headerTitle: String {
        let base = current.displayTitle
        let t = current.title.trimmingCharacters(in: .whitespaces)
        guard current.number != nil, !t.isEmpty, t != base,
              !t.contains(ChapterDownload.format(current.number ?? 0)) else { return base }
        return base + " · " + t
    }

    private var pages: [ReaderPageSource] {
        if let local {
            let folder = Storage.absolute(local.folder)
            return local.pages.map { .local(folder.appending(path: $0)) }
        }
        return images.map { .remote(Site.mangaPage($0, chapter: url)) }
    }

    var body: some View {
        GeometryReader { screen in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                if ready, !pages.isEmpty {
                    ChapterScroll(
                        id: url,
                        pages: pages,
                        initialPage: initialPage,
                        endTitle: "نهاية " + current.displayTitle,
                        nextTitle: next.map { n in n.number.map { "الفصل التالي " + ChapterDownload.format($0) } ?? "الفصل التالي" },
                        onNext: { if let n = next { open(n) } },
                        onBack: { dismiss() },
                        onTap: { withAnimation(.easeInOut(duration: 0.22)) { controls.toggle() } },
                        onPosition: { p in
                            page = p
                            ReaderPositions.save(p, for: url)
                            if local != nil { center.saveReadingPosition(story: request.story.url, chapter: url, page: p) }
                        },
                        onScroll: { offset, moving in
                            if let visible = direction.update(offset: offset, userScrolling: moving), visible != controls {
                                withAnimation(.easeInOut(duration: 0.22)) { controls = visible }
                            }
                        })
                    .id(url)
                    .ignoresSafeArea()
                } else if let error {
                    VStack(spacing: 16) {
                        ContentUnavailableView("تعذّر فتح الفصل", systemImage: "wifi.slash", description: Text(error))
                        Button("إعادة المحاولة", systemImage: "arrow.clockwise") { Task { await load() } }
                            .buttonStyle(.glassProminent)
                        Button("العودة") { dismiss() }.buttonStyle(.glass)
                    }
                    .padding()
                    .frame(maxHeight: .infinity)
                } else {
                    ProgressView("تجهيز الفصل…")
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Color.black.opacity(dim).ignoresSafeArea().allowsHitTesting(false)

                HStack(spacing: 0) {
                    Spacer()
                    Color.clear
                        .frame(width: 22)
                        .contentShape(.rect)
                        .gesture(DragGesture(minimumDistance: 12).onEnded { v in
                            if v.translation.width < -70 && abs(v.translation.height) < 120 { dismiss() }
                        })
                }
                .environment(\.layoutDirection, .leftToRight)
                .ignoresSafeArea()

                header(top: screen.safeAreaInsets.top)
                    .offset(y: controls ? 0 : -(headerHeight + 12))
                    .opacity(controls ? 1 : 0)
                    .allowsHitTesting(controls)
            }
        }
        .statusBarHidden(!controls)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .rightToLeft)
        .task(id: url) { await load() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: keepAwake) { _, v in UIApplication.shared.isIdleTimerDisabled = v }
        .sheet(isPresented: $choosingChapter) { chapterPicker }
    }

    // MARK: - الشريط العلوي

    private func header(top: CGFloat) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.right").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).contentShape(.rect)
                }
                .accessibilityLabel("العودة")

                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.8)
                    if ready, !pages.isEmpty {
                        Text("\(page + 1) / \(pages.count)").monospacedDigit()
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)

                if ready { Menu {
                    if local == nil {
                        Button(center.isDownloaded(chapter: url) == nil ? "تحميل الفصل" : "جارٍ التحميل…",
                               systemImage: "arrow.down.circle") { downloadCurrent() }
                            .disabled(images.isEmpty || center.isDownloaded(chapter: url) != nil)
                    } else {
                        Label("الفصل محمّل", systemImage: "checkmark.circle.fill")
                    }
                    if let n = current.number {
                        let following = chapters.filter { ($0.number ?? 0) > n && center.isDownloaded(chapter: $0.url) == nil }.prefix(5)
                        Button("تحميل الفصول الخمسة التالية", systemImage: "forward.end") {
                            center.download(chapters: Array(following), of: capturedStory)
                        }
                        .disabled(following.isEmpty || !app.isOnline)
                    }
                    Button("إعادة تحميل الفصل", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(!app.isOnline)
                    Divider()
                    Toggle("إبقاء الشاشة مضاءة", systemImage: "sun.max", isOn: $keepAwake)
                    Picker("تعتيم الشاشة", systemImage: "moon", selection: $dim) {
                        Text("بدون تعتيم").tag(0.0)
                        Text("تعتيم خفيف").tag(0.2)
                        Text("تعتيم متوسط").tag(0.4)
                        Text("تعتيم قوي").tag(0.6)
                    }
                    .pickerStyle(.menu)
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).contentShape(.rect)
                }
                .accessibilityLabel("الخيارات") }
            }

            HStack(spacing: 0) {
                Button { if let p = previous { open(p) } } label: {
                    Label("السابق", systemImage: "chevron.right").frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                }
                .disabled(previous == nil)
                Button { chapterQuery = ""; choosingChapter = true } label: {
                    Label("الفصول", systemImage: "list.bullet").frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                }
                Button { if let n = next { open(n) } } label: {
                    Label("التالي", systemImage: "chevron.left").frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                }
                .disabled(next == nil)
            }
            .font(.subheadline)
            .lineLimit(1)
        }
        .tint(Theme.accent)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .padding(.top, top)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var chapterPicker: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(chapters.filter { chapterQuery.isEmpty || $0.displayTitle.contains(chapterQuery) || $0.title.localizedCaseInsensitiveContains(chapterQuery) }) { c in
                        Button { choosingChapter = false; open(c) } label: {
                            HStack {
                                Text(c.displayTitle).foregroundStyle(.primary)
                                    .fontWeight(c.url == url ? .bold : .regular)
                                Spacer()
                                if c.url == url { Image(systemName: "book.fill").foregroundStyle(Theme.accent) }
                                if center.isDownloaded(chapter: c.url)?.state == .completed {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .id(c.url)
                    }
                }
                .onAppear { proxy.scrollTo(url, anchor: .center) }
            }
            .searchable(text: $chapterQuery, prompt: "رقم الفصل أو عنوانه")
            .navigationTitle("اختيار الفصل")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("إغلاق") { choosingChapter = false } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.medium, .large])
    }

    // MARK: - المنطق

    private var capturedStory: CapturedStory {
        CapturedStory(title: request.story.title, url: request.story.url, cover: request.story.cover, chapters: chapters)
    }

    private func open(_ link: ChapterLink) {
        guard link.url != url else { return }
        Haptics.tap()
        direction = ReaderScrollDirection()
        withAnimation(.easeInOut(duration: 0.22)) { controls = true }
        url = link.url
    }

    private func downloadCurrent() {
        center.download(chapters: [current], of: capturedStory,
                        current: CapturedChapter(url: url, title: current.title, images: images))
    }

    private func load() async {
        error = nil
        ready = false
        images = []
        page = 0
        if request.recordHistory { library.recordRead(request.story, chapter: current) }
        if let local {
            initialPage = min(max(0, local.lastReadPage), max(0, local.pages.count - 1))
            page = initialPage
            ready = true
            return
        }
        do {
            let loaded = try await API.shared.chapter(url).images
            guard !Task.isCancelled else { return }
            images = loaded
            initialPage = min(ReaderPositions.page(for: url), max(0, loaded.count - 1))
            page = initialPage
            ready = true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

/// آخر صفحة في كل فصل (للقراءة من الإنترنت؛ الفصول المحمّلة تحفظ موضعها في التحميلات).
enum ReaderPositions {
    private static let key = "reader.positions"

    static func page(for url: String) -> Int {
        (UserDefaults.standard.dictionary(forKey: key)?[url] as? Int) ?? 0
    }

    static func save(_ page: Int, for url: String) {
        var d = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        d[url] = page
        if d.count > 400 { d = Dictionary(uniqueKeysWithValues: d.suffix(300).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(d, forKey: key)
    }
}
