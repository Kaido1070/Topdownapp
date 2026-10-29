import SwiftUI

/// صفحة القصة: الغلاف، الملخص، الفصول، الحفظ، المتابعة والتحميل.
struct StoryScreen: View {
    let item: StoryItem
    @Environment(Library.self) private var library
    @Environment(DownloadCenter.self) private var center
    @Environment(AppModel.self) private var app
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
                                Button { open(last.url) } label: {
                                    Label("متابعة " + last.displayTitle, systemImage: "book.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent)
                            } else if let first = reading.first {
                                Button { open(first.url) } label: {
                                    Label("ابدأ القراءة", systemImage: "book.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent)
                            }
                            if let latest = reading.last, latest.url != lastRead?.url {
                                Button { open(latest.url) } label: {
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
                        Button { open(c.url) } label: {
                            HStack(spacing: 12) {
                                Text(c.number.map { ChapterDownload.format($0) } ?? "—")
                                    .font(.headline.monospacedDigit()).foregroundStyle(Theme.accent)
                                    .frame(minWidth: 44)
                                Text(c.title.isEmpty ? c.displayTitle : c.title).lineLimit(1)
                                Spacer()
                                if let d = center.isDownloaded(chapter: c.url) {
                                    if d.state == .completed {
                                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                                    } else if d.state == .failed {
                                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                                    } else {
                                        Text("\(Int(d.progress * 100))٪").font(.caption.bold().monospacedDigit())
                                            .foregroundStyle(d.state == .paused ? .orange : Theme.accent)
                                    }
                                } else if let p = c.publishedAt {
                                    Text(p).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
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

    private func open(_ url: String) {
        Haptics.tap()
        app.reader = ReaderRequest(story: story, chapters: reading, url: url)
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

