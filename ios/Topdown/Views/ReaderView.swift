import SwiftUI

/// قارئ القصص بدون إنترنت: تمرير عمودي، تكبير، حفظ آخر صفحة، وانتقال للفصل التالي.
struct ReaderView: View {
    let storyURL: String
    @State var chapterURL: String
    @Environment(DownloadCenter.self) private var center
    @State private var page = 0
    @State private var chromeHidden = false
    @State private var zoom: CGFloat = 1

    init(storyURL: String, chapterURL: String) {
        self.storyURL = storyURL
        _chapterURL = State(initialValue: chapterURL)
    }

    private var story: StoryDownload? { center.story(storyURL) }
    private var chapter: ChapterDownload? { story?.chapters.first { $0.url == chapterURL } }
    private var completed: [ChapterDownload] { story?.completedChapters ?? [] }
    private var index: Int? { completed.firstIndex { $0.url == chapterURL } }
    private var previous: ChapterDownload? { index.flatMap { $0 > 0 ? completed[$0 - 1] : nil } }
    private var next: ChapterDownload? { index.flatMap { $0 + 1 < completed.count ? completed[$0 + 1] : nil } }

    var body: some View {
        if let chapter {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(chapter.pages.enumerated()), id: \.offset) { i, name in
                            ReaderPage(url: Storage.absolute(chapter.folder).appending(path: name))
                                .id(i)
                                .onAppear { page = i; center.saveReadingPosition(story: storyURL, chapter: chapterURL, page: i) }
                        }
                        footer.padding(.vertical, 40)
                    }
                    .scaleEffect(zoom, anchor: .top)
                }
                .scrollIndicators(.hidden)
                .background(.black)
                .onTapGesture { withAnimation(.smooth) { chromeHidden.toggle() } }
                .gesture(MagnifyGesture().onChanged { zoom = min(3, max(1, $0.magnification)) }
                    .onEnded { _ in withAnimation(.spring) { zoom = 1 } })
                .onAppear {
                    if chapter.lastReadPage > 0 { proxy.scrollTo(chapter.lastReadPage, anchor: .top) }
                }
                .onChange(of: chapterURL) { _, _ in proxy.scrollTo(0, anchor: .top) }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(chapter.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar, .tabBar)
            .statusBarHidden(chromeHidden)
            .overlay(alignment: .bottom) {
                if !chromeHidden {
                    Text("\(page + 1) / \(chapter.pages.count)")
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        } else {
            ContentUnavailableView("الفصل غير متاح", systemImage: "book.closed")
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Text("نهاية \(chapter?.displayTitle ?? "")").foregroundStyle(.secondary)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("السابق", systemImage: "chevron.backward") { if let p = previous { chapterURL = p.url } }
                        .buttonStyle(.glass).disabled(previous == nil)
                    Button("التالي", systemImage: "chevron.forward") { if let n = next { chapterURL = n.url } }
                        .buttonStyle(.glassProminent).disabled(next == nil)
                }
            }
        }
    }
}

private struct ReaderPage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.black).frame(height: 500).overlay(ProgressView())
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: url) {
            image = await Task.detached { UIImage(contentsOfFile: url.path())?.preparingForDisplay() }.value
        }
    }
}
