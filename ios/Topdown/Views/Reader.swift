import SwiftUI

/// قارئ الفصول بملء الشاشة: بدون شريط التبويبات، وأدوات زجاجية تظهر بلمسة وتختفي مع القراءة.
struct ReaderScreen: View {
    let request: ReaderRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @Environment(DownloadCenter.self) private var center

    @State private var url: String
    @State private var images: [String] = []
    @State private var error: String?
    @State private var loading = true
    @State private var page: Int? = 0
    @State private var chrome = true
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var sliderValue: Double = 0
    @State private var dragging = false

    @AppStorage("reader.mode") private var mode = "vertical"        // vertical | paged
    @AppStorage("reader.keepAwake") private var keepAwake = true
    @AppStorage("reader.autoHide") private var autoHide = true
    @AppStorage("reader.dim") private var dim = 0.0
    @AppStorage("reader.gapless") private var gapless = true

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

    private var pages: [ReaderPageSource] {
        if let local {
            let folder = Storage.absolute(local.folder)
            return local.pages.map { .local(folder.appending(path: $0)) }
        }
        return images.map { .remote(Site.mangaPage($0, chapter: url)) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .ignoresSafeArea()

            Color.black.opacity(dim).ignoresSafeArea().allowsHitTesting(false)

            if chrome {
                VStack(spacing: 0) {
                    topBar.transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                    if !pages.isEmpty { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
            }
        }
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .animation(.smooth(duration: 0.25), value: chrome)
        .task(id: url) { await load() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: page) { _, p in
            guard let p else { return }
            if !dragging { sliderValue = Double(p) }
            if local != nil { center.saveReadingPosition(story: request.story.url, chapter: url, page: p) }
        }
        .sheet(isPresented: $showChapters) {
            ChapterListSheet(chapters: chapters, current: url) { picked in
                showChapters = false
                go(to: picked)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(mode: $mode, keepAwake: $keepAwake, autoHide: $autoHide, dim: $dim, gapless: $gapless)
                .presentationDetents([.medium])
        }
        .onChange(of: keepAwake) { _, v in UIApplication.shared.isIdleTimerDisabled = v }
    }

    // MARK: - المحتوى

    @ViewBuilder
    private var content: some View {
        if pages.isEmpty {
            VStack(spacing: 16) {
                if let error {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    Text("تعذّر فتح الفصل").font(.headline)
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("إعادة المحاولة", systemImage: "arrow.clockwise") { Task { await load() } }
                        .buttonStyle(.glassProminent)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(current.displayTitle).foregroundStyle(.secondary)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .onTapGesture { toggleChrome() }
        } else if mode == "paged" {
            pagedReader
        } else {
            verticalReader
        }
    }

    private var verticalReader: some View {
        ScrollView {
            LazyVStack(spacing: gapless ? 0 : 8) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, src in
                    ReaderPage(source: src, fill: .width)
                        .id(i)
                }
                chapterEnd
                    .id(pages.count)
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $page, anchor: .top)
        .scrollIndicators(.hidden)
        .onScrollPhaseChange { _, phase in
            if autoHide, phase == .interacting, chrome { chrome = false }
        }
        .onTapGesture { toggleChrome() }
    }

    private var pagedReader: some View {
        TabView(selection: Binding(get: { page ?? 0 }, set: { page = $0 })) {
            ForEach(Array(pages.enumerated()), id: \.offset) { i, src in
                ZoomablePage { ReaderPage(source: src, fill: .screen) }
                    .tag(i)
            }
            chapterEnd
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tag(pages.count)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onTapGesture { toggleChrome() }
    }

    /// نهاية الفصل: انتقال مباشر للفصل التالي.
    private var chapterEnd: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text("انتهى " + current.displayTitle).font(.headline)
            if let next {
                Button { go(to: next) } label: {
                    VStack(spacing: 4) {
                        Text("الفصل التالي").font(.caption).foregroundStyle(.secondary)
                        Text(next.displayTitle).font(.title3.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .padding(.horizontal, 30)
            } else {
                Text("هذا آخر فصل متاح").foregroundStyle(.secondary)
            }
            if let previous {
                Button("الفصل السابق: " + previous.displayTitle) { go(to: previous) }
                    .buttonStyle(.glass)
            }
            Button("رجوع للقصة") { dismiss() }
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
    }

    // MARK: - الأدوات

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(request.story.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(current.displayTitle).font(.headline).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { downloadCurrent() } label: {
                Image(systemName: local != nil ? "checkmark.circle.fill"
                      : center.isDownloaded(chapter: url) != nil ? "arrow.down.circle.dotted" : "arrow.down.circle")
                    .font(.title3).frame(width: 40, height: 40)
                    .foregroundStyle(local != nil ? Theme.accent : .primary)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(local != nil || images.isEmpty)

            Button { showChapters = true } label: {
                Image(systemName: "list.bullet").font(.title3).frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            // عربي: السابق يمين والتالي يسار، والصفحة الأولى من اليمين
            HStack(spacing: 10) {
                Button { if let p = previous { go(to: p) } } label: {
                    Image(systemName: "chevron.right.2").frame(width: 36, height: 36)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .disabled(previous == nil)
                .opacity(previous == nil ? 0.3 : 1)
                .accessibilityLabel("الفصل السابق")

                Slider(value: $sliderValue, in: 0...Double(max(pages.count - 1, 1)), step: 1,
                       onEditingChanged: { editing in
                           dragging = editing
                           if !editing { page = Int(sliderValue) }
                       })
                .tint(Theme.accent)

                Button { if let n = next { go(to: n) } } label: {
                    Image(systemName: "chevron.left.2").frame(width: 36, height: 36)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .disabled(next == nil)
                .opacity(next == nil ? 0.3 : 1)
                .accessibilityLabel("الفصل التالي")
            }

            HStack {
                Button { showSettings = true } label: {
                    Label("الإعدادات", systemImage: "textformat.size").font(.footnote)
                }
                .buttonStyle(.glass)

                Spacer()
                Text("\(min(Int(sliderValue), pages.count - 1) + 1) / \(pages.count)")
                    .font(.subheadline.monospacedDigit().bold())
                    .contentTransition(.numericText())
                Spacer()

                Button {
                    withAnimation { mode = mode == "paged" ? "vertical" : "paged" }
                } label: {
                    Label(mode == "paged" ? "صفحات" : "تمرير", systemImage: mode == "paged" ? "book.pages" : "scroll")
                        .font(.footnote)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - المنطق

    private func toggleChrome() {
        withAnimation(.smooth(duration: 0.25)) { chrome.toggle() }
    }

    private func go(to link: ChapterLink) {
        Haptics.tap()
        page = 0
        sliderValue = 0
        url = link.url
        chrome = true
    }

    private func downloadCurrent() {
        center.download(chapters: [current],
                        of: CapturedStory(title: request.story.title, url: request.story.url, cover: request.story.cover, chapters: chapters),
                        current: CapturedChapter(url: url, title: current.title, images: images))
    }

    private func load() async {
        error = nil
        images = []
        loading = true
        if request.recordHistory { library.recordRead(request.story, chapter: current) }
        if let local {
            let resume = local.lastReadPage
            page = resume
            sliderValue = Double(resume)
            loading = false
            return
        }
        page = 0
        do { images = try await API.shared.chapter(url).images }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

// MARK: - صفحة

enum ReaderPageSource {
    case local(URL)
    case remote([URL])
}

private struct ReaderPage: View {
    enum Fill { case width, screen }
    let source: ReaderPageSource
    let fill: Fill
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(image.size, contentMode: .fit)
            } else {
                ZStack {
                    Color.black
                    if failed {
                        Button("إعادة تحميل الصفحة", systemImage: "arrow.clockwise") { failed = false; attempt += 1 }
                            .buttonStyle(.glass)
                    } else {
                        ProgressView().tint(.white.opacity(0.6))
                    }
                }
                .frame(height: fill == .width ? 520 : nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fill == .screen ? .infinity : nil)
        .task(id: attempt) {
            switch source {
            case .local(let url):
                image = await Task.detached { UIImage(contentsOfFile: url.path())?.preparingForDisplay() }.value
            case .remote(let urls):
                image = await ImagePipeline.shared.image(urls, maxPixel: 2200)
            }
            failed = image == nil
        }
    }
}

/// تكبير بالقرص وضغطتين في وضع الصفحات.
private struct ZoomablePage<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .gesture(MagnifyGesture()
                .onChanged { scale = min(4, max(1, base * $0.magnification)) }
                .onEnded { _ in base = scale; if scale <= 1.01 { reset() } })
            .simultaneousGesture(scale > 1 ? DragGesture()
                .onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width, height: lastOffset.height + $0.translation.height) }
                .onEnded { _ in lastOffset = offset } : nil)
            .onTapGesture(count: 2) { withAnimation(.spring) { if scale > 1 { reset() } else { scale = 2.2; base = 2.2 } } }
    }

    private func reset() {
        withAnimation(.spring) { scale = 1; base = 1; offset = .zero; lastOffset = .zero }
    }
}

// MARK: - الأوراق

private struct ChapterListSheet: View {
    let chapters: [ChapterLink]
    let current: String
    let pick: (ChapterLink) -> Void
    @Environment(DownloadCenter.self) private var center

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(chapters.reversed()) { c in
                    Button { pick(c) } label: {
                        HStack {
                            Text(c.displayTitle).fontWeight(c.url == current ? .bold : .regular)
                            Spacer()
                            if center.isDownloaded(chapter: c.url)?.state == .completed {
                                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                            }
                            if c.url == current { Image(systemName: "book.fill").foregroundStyle(Theme.accent) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .id(c.url)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("الفصول (\(chapters.count))")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ReaderSettingsSheet: View {
    @Binding var mode: String
    @Binding var keepAwake: Bool
    @Binding var autoHide: Bool
    @Binding var dim: Double
    @Binding var gapless: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("طريقة القراءة") {
                    Picker("الوضع", selection: $mode) {
                        Label("تمرير عمودي", systemImage: "scroll").tag("vertical")
                        Label("صفحات", systemImage: "book.pages").tag("paged")
                    }
                    .pickerStyle(.segmented)
                    if mode == "vertical" { Toggle("بدون فواصل بين الصفحات", isOn: $gapless) }
                }
                Section("العرض") {
                    VStack(alignment: .leading) {
                        Label("تعتيم الشاشة", systemImage: "sun.min")
                        Slider(value: $dim, in: 0...0.7)
                    }
                    Toggle("إبقاء الشاشة مضاءة", isOn: $keepAwake)
                    Toggle("إخفاء الأدوات عند التمرير", isOn: $autoHide)
                }
            }
            .navigationTitle("إعدادات القارئ")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
