import SwiftUI

struct AccountView: View {
    @Environment(Library.self) private var library
    @Environment(DownloadCenter.self) private var center
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        BrandMark(size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("حسابي").font(.title2.bold())
                            Label("حساب خاص", systemImage: "lock.fill").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        StatTile(title: "المفضلة", value: library.favorites.count, icon: "star.fill", route: .favorites)
                        StatTile(title: "سجل المشاهدة", value: library.history.count, icon: "clock.fill", route: .history)
                        StatTile(title: "القصص المحفوظة", value: library.savedStories.count, icon: "bookmark.fill", route: .savedStories)
                        StatTile(title: "سجل القراءة", value: library.storyHistory.count, icon: "book.fill", route: .storyHistory)
                    }
                    .padding(.horizontal)

                    if let e = library.error, library.favorites.isEmpty {
                        Label(e, systemImage: "exclamationmark.icloud").font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                    }

                    if !library.history.isEmpty {
                        SectionHeader(title: "تابع المشاهدة", route: .history)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(library.history.prefix(15), id: \.key) { VideoCard(item: $0, width: 200) }
                            }
                            .padding(.horizontal)
                        }
                    }
                    if !library.storyHistory.isEmpty {
                        SectionHeader(title: "تابع القراءة", route: .storyHistory)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(library.storyHistory.prefix(15)) { StoryCardView(item: $0, width: 112) }
                            }
                            .padding(.horizontal)
                        }
                    }
                    if !library.favorites.isEmpty {
                        SectionHeader(title: "الأنمي المحفوظ", count: library.favorites.count, route: .favorites)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(library.favorites.prefix(15), id: \.key) { VideoCard(item: $0, width: 200) }
                            }
                            .padding(.horizontal)
                        }
                    }
                    if !library.savedStories.isEmpty {
                        SectionHeader(title: "قصصي المحفوظة", count: library.savedStories.count, route: .savedStories)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(library.savedStories.prefix(15)) { StoryCardView(item: $0, width: 112) }
                            }
                            .padding(.horizontal)
                        }
                    }

                    VStack(spacing: 0) {
                        NavigationLink(value: Route.sources) { row("المصادر", icon: "square.stack.3d.up.fill") }
                        Divider().padding(.leading, 52)
                        Button { app.tab = .library } label: { row("التحميلات (\(center.storageSummary))", icon: "arrow.down.circle.fill") }
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("حسابي")
            .toolbarTitleDisplayMode(.inline)
            .refreshable { await library.refresh() }
            .topdownDestinations()
        }
    }

    private func row(_ title: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 24)
            Text(title)
            Spacer()
            Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .contentShape(.rect)
    }
}

private struct StatTile: View {
    let title: String
    let value: Int
    let icon: String
    let route: Route
    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text("\(value)").font(.title.bold()).contentTransition(.numericText())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

struct FavoritesScreen: View {
    @Environment(Library.self) private var library
    var body: some View {
        ScrollView {
            if library.favorites.isEmpty {
                ContentUnavailableView("لم تضف أي مقاطع إلى المفضلة بعد", systemImage: "star").padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 14)], spacing: 18) {
                ForEach(library.favorites, id: \.key) { VideoCard(item: $0) }
            }
            .padding()
        }
        .navigationTitle("المفضلة")
        .refreshable { await library.refresh() }
    }
}

struct HistoryScreen: View {
    @Environment(Library.self) private var library
    @State private var query = ""
    @State private var range = "all"
    @State private var confirm = false

    private var filtered: [MediaItem] {
        let now = Date.now.timeIntervalSince1970 * 1000
        let cut: Double = switch range {
        case "today": Calendar.current.startOfDay(for: .now).timeIntervalSince1970 * 1000
        case "7d": now - 7 * 864e5
        case "30d": now - 30 * 864e5
        default: 0
        }
        return library.history.filter { ($0.watchedAt ?? 0) >= cut && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        List {
            Picker("الفترة", selection: $range) {
                Text("الكل").tag("all"); Text("اليوم").tag("today"); Text("7 أيام").tag("7d"); Text("30 يومًا").tag("30d")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            ForEach(filtered, id: \.key) { x in
                NavigationLink(value: x.opensDetails ? Route.work(x) : Route.video(x)) {
                    HStack(spacing: 12) {
                        RemoteImage(urls: Site.videoThumb(x.thumbnail), maxPixel: 300)
                            .frame(width: 104, height: 62).clipShape(.rect(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(x.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(x.sourceName)
                                if let w = x.watchedAt {
                                    Text(Date(timeIntervalSince1970: w / 1000), format: .relative(presentation: .named))
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions { Button("حذف", systemImage: "trash", role: .destructive) { library.removeHistory(x) } }
            }
            if filtered.isEmpty { Text("لا يوجد سجل مطابق.").foregroundStyle(.secondary) }
        }
        .navigationTitle("سجل المشاهدة")
        .searchable(text: $query, prompt: "تصفية بالعنوان")
        .toolbar {
            Button("مسح", systemImage: "trash") { confirm = true }.disabled(library.history.isEmpty)
        }
        .confirmationDialog("حذف سجل المشاهدة بالكامل؟", isPresented: $confirm, titleVisibility: .visible) {
            Button("حذف الكل", role: .destructive) { library.clearHistory() }
        }
        .refreshable { await library.refresh() }
    }
}

struct SavedStoriesScreen: View {
    @Environment(Library.self) private var library
    var body: some View {
        ScrollView {
            if library.savedStories.isEmpty {
                ContentUnavailableView("لا توجد قصص محفوظة", systemImage: "bookmark").padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 14)], spacing: 18) {
                ForEach(library.savedStories) { StoryCardView(item: $0) }
            }
            .padding()
        }
        .navigationTitle("القصص المحفوظة")
        .refreshable { await library.refresh() }
    }
}

struct StoryHistoryScreen: View {
    @Environment(Library.self) private var library
    @State private var confirm = false
    var body: some View {
        List {
            ForEach(library.storyHistory) { x in
                NavigationLink(value: Route.story(x)) {
                    HStack(spacing: 12) {
                        RemoteImage(urls: Site.mangaThumb(x.cover, ref: x.url), maxPixel: 200)
                            .frame(width: 54, height: 76).clipShape(.rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(x.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            if let c = x.lastChapterTitle { Text(c).font(.caption).foregroundStyle(Theme.accent) }
                            if let w = x.watchedAt {
                                Text(Date(timeIntervalSince1970: w / 1000), format: .relative(presentation: .named))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .swipeActions { Button("حذف", systemImage: "trash", role: .destructive) { library.removeStoryHistory(x) } }
            }
            if library.storyHistory.isEmpty { Text("سجل القصص فاضي.").foregroundStyle(.secondary) }
        }
        .navigationTitle("سجل القراءة")
        .toolbar { Button("مسح", systemImage: "trash") { confirm = true }.disabled(library.storyHistory.isEmpty) }
        .confirmationDialog("حذف سجل القراءة بالكامل؟", isPresented: $confirm, titleVisibility: .visible) {
            Button("حذف الكل", role: .destructive) { library.clearStoryHistory() }
        }
        .refreshable { await library.refresh() }
    }
}

struct SourcesScreen: View {
    @State private var sources: [DirectorySource] = []
    @State private var checks: [String: SourceCheck] = [:]
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if sources.isEmpty && error == nil { ProgressView() }
            ForEach(sources) { s in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(s.name.prefix(1)).uppercased())
                            .font(.headline).frame(width: 34, height: 34)
                            .glassEffect(.regular.tint(Theme.accent.opacity(0.3)), in: .circle)
                        VStack(alignment: .leading) {
                            Text(s.name).font(.headline)
                            Text(kindName(s.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await check(s.id) }
                        } label: {
                            if busy == s.id { ProgressView() } else { Text("فحص") }
                        }
                        .buttonStyle(.glass)
                        .disabled(busy != nil)
                    }
                    if let c = checks[s.id] {
                        Label(message(c), systemImage: c.reachable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(c.reachable ? .green : .red)
                    }
                    if let u = URL(string: s.url) {
                        Link(destination: u) { Text(s.url).font(.caption2).lineLimit(1) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("المصادر")
        .task {
            do { sources = try await API.shared.sourceDirectory() } catch { self.error = error.localizedDescription }
        }
    }

    private func check(_ id: String) async {
        busy = id
        if let c = try? await API.shared.sourceHealth(id) { checks[id] = c }
        busy = nil
    }

    private func kindName(_ k: String) -> String {
        switch k { case "anime": "أنمي"; case "manga": "مانجا / مانهوا"; case "mixed": "مختلط"; default: "غير مُتحقق" }
    }

    private func message(_ c: SourceCheck) -> String {
        if c.reachable { return "استجاب المصدر" + (c.latencyMs.map { " خلال \(Int($0)) ms" } ?? "") }
        switch c.code {
        case "SOURCE_TIMEOUT": return "انتهت مهلة الاتصال"
        case "SOURCE_NETWORK_ERROR": return "تعذّر الوصول إلى خادم المصدر"
        default: return c.httpStatus == 403 ? "رفض المصدر الطلب" : "خطأ HTTP \(c.httpStatus.map(String.init) ?? "غير معروف")"
        }
    }
}
