import SwiftUI

/// كتالوج الأنمي: نفس منطق UnifiedCatalog في الموقع (كل مصدر صفحاته الخاصة ثم دمج بالتناوب).
@MainActor
@Observable
final class AnimeFeed {
    var source: AnimeSource = .all
    var sort = "latest"           // latest | popular | most-viewed (المصدر القديم فقط)
    var duration: DurationFilter = .all
    var tag = ""
    var query = ""

    private(set) var items: [MediaItem] = []
    private(set) var related: [MediaItem] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var errors: [String] = []
    private(set) var staleNote: String?
    private(set) var hasNext = false

    private var pages: [AnimeSource: (items: [MediaItem], next: Int?)] = [:]
    private var generation = 0

    var allTags: [String] {
        Array(Set(pages.values.flatMap { $0.items.flatMap { $0.tags ?? [] } }.filter { !$0.isEmpty })).sorted()
    }

    var activeFilterCount: Int { (duration != .all ? 1 : 0) + (tag.isEmpty ? 0 : 1) + (sort != "latest" ? 1 : 0) }

    private var selected: [AnimeSource] { source == .all ? AnimeSource.concrete : [source] }

    func reload() async {
        generation += 1
        let gen = generation
        loading = true
        errors = []
        staleNote = nil
        pages = [:]
        rebuild()
        let q = queryValue, so = sortValue
        await withTaskGroup(of: (AnimeSource, Result<VideoPage, Error>).self) { group in
            for s in selected {
                group.addTask { (s, await Self.read(s, page: 1, query: q, sort: so)) }
            }
            for await (s, result) in group where gen == generation {
                apply(s, result)
            }
        }
        if gen == generation { loading = false }
    }

    func loadMore() async {
        guard !loading, !loadingMore, hasNext else { return }
        let gen = generation
        loadingMore = true
        let targets = selected.compactMap { s in pages[s]?.next.map { (s, $0) } }
        let q = queryValue, so = sortValue
        await withTaskGroup(of: (AnimeSource, Result<VideoPage, Error>).self) { group in
            for (s, page) in targets {
                group.addTask { (s, await Self.read(s, page: page, query: q, sort: so)) }
            }
            for await (s, result) in group where gen == generation {
                apply(s, result, append: true)
            }
        }
        loadingMore = false
    }

    private var queryValue: String { query.trimmingCharacters(in: .whitespaces) }
    private var sortValue: String { source == .legacy ? sort : "latest" }

    nonisolated private static func read(_ s: AnimeSource, page: Int, query: String, sort: String) async -> Result<VideoPage, Error> {
        do {
            if s == .legacy {
                return .success(query.isEmpty ? try await API.shared.home(page: page, sort: sort)
                                               : try await API.shared.search(query, page: page))
            }
            return .success(try await API.shared.providerCatalog(s.rawValue, page: page, q: query))
        } catch { return .failure(error) }
    }

    private func apply(_ s: AnimeSource, _ result: Result<VideoPage, Error>, append: Bool = false) {
        switch result {
        case .success(let page):
            let prior = append ? (pages[s]?.items ?? []) : []
            let fresh = page.items.values
            let duplicate = append && !fresh.isEmpty && fresh.allSatisfy { f in prior.contains { $0.key == f.key } }
            let requested = append ? (pages[s]?.next ?? 1) : 1
            let next = !duplicate && (page.nextPage ?? 0) > requested ? page.nextPage : nil
            pages[s] = (unique(prior + fresh), next)
            if s == .legacy, !queryValue.isEmpty { related = unique(related + (page.related?.values ?? [])) }
            if page.stale == true { staleNote = page.cachedAt ?? "محفوظ سابقًا" }
        case .failure(let e):
            if !append || source != .all { errors.append("\(s.name): \(e.localizedDescription)") }
            if !append { pages[s] = ([], nil) }
        }
        rebuild()
    }

    func rebuild() {
        let merged = unique(interleave(AnimeSource.concrete.map { pages[$0]?.items ?? [] }))
        items = merged.filter { duration.matches($0) && (tag.isEmpty || ($0.tags ?? []).contains(tag)) }
        hasNext = pages.values.contains { $0.next != nil }
    }

    private func unique(_ list: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.key).inserted }
    }
}

/// كتالوج القصص: نفس منطق Stories في الموقع.
@MainActor
@Observable
final class StoryFeed {
    var source: StorySource = .all
    var genre = ""
    var query = ""
    var order = "source"   // source | latest | popular | views

    private(set) var items: [StoryItem] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var errors: [String] = []
    private(set) var hasNext = false
    private(set) var genres: [Tag] = []
    private var page = 1
    private var exhausted = Set<StorySource>()
    private var generation = 0

    var sorted: [StoryItem] {
        func score(_ x: StoryItem) -> Double? {
            switch order {
            case "latest": x.updatedAt.flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 }
            case "views": x.views
            case "popular": x.popularity
            default: nil
            }
        }
        guard order != "source", !items.isEmpty, items.allSatisfy({ score($0) != nil }) else { return items }
        return items.sorted { (score($0) ?? 0) > (score($1) ?? 0) }
    }

    func supports(_ order: String) -> Bool {
        switch order {
        case "latest": !items.isEmpty && items.allSatisfy { $0.updatedAt != nil }
        case "views": !items.isEmpty && items.allSatisfy { $0.views != nil }
        case "popular": !items.isEmpty && items.allSatisfy { $0.popularity != nil }
        default: true
        }
    }

    /// آخر حالة لكل مصدر (عدد النتائج أو الخطأ) لعرضها للمستخدم.
    private(set) var sourceStatus: [StorySource: String] = [:]
    /// اكتمل تحميل ورد فيه كل مصدر بنتيجة أو خطأ (لا نعرض «لا توجد نتائج» قبله)
    private(set) var didLoad = false

    /// التحميل يملكه الكتالوج نفسه وليس الشاشة، فلا تلغيه SwiftUI عند إعادة بناء الواجهة.
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskID = UUID()
    @ObservationIgnored private var autoRetries = 0

    func loadGenres() async {
        if genres.isEmpty, let g = try? await API.shared.storyGenres() { genres = g }
    }

    /// يبدأ التحميل إن لم يكن هناك محتوى ولا تحميل جارٍ. آمن للاستدعاء مرات كثيرة.
    func start() {
        guard items.isEmpty, !loading, task == nil else { return }
        refresh()
    }

    /// تحميل جديد من الصفحة الأولى (يلغي أي تحميل سابق).
    func refresh() {
        task?.cancel()
        autoRetries = 0
        let id = UUID()
        taskID = id
        task = Task { [weak self] in
            await self?.reload()
            // لا نمسح مرجع تحميل أحدث بدأ بعدنا
            if self?.taskID == id { self?.task = nil }
        }
    }

    /// للسحب للتحديث: ينتظر انتهاء التحميل بدون أن يرتبط إلغاؤه بالواجهة.
    func refreshAndWait() async {
        refresh()
        await task?.value
    }

    func reload() async {
        generation += 1
        page = 1
        exhausted = []
        sourceStatus = [:]
        didLoad = false
        await fetch(page: 1, append: false)
    }

    func loadMore() async {
        guard !loading, !loadingMore, hasNext else { return }
        await fetch(page: page + 1, append: true)
    }

    /// سجل مختصر لما حدث أثناء التحميل (يظهر في «فحص المصادر»).
    private(set) var log: [String] = []
    private func note(_ m: String) {
        let t = Date().formatted(.dateTime.hour().minute().second())
        log.append(t + " " + m)
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }

    private func fetch(page p: Int, append: Bool) async {
        let gen = generation
        if append { loadingMore = true } else { loading = true; errors = [] }
        defer {
            if gen == generation { loading = false; loadingMore = false }
        }
        let targets = (source == .all ? StorySource.concrete : [source]).filter { !exhausted.contains($0) }
        let q = query.trimmingCharacters(in: .whitespaces), g = genre
        note("تحميل ص\(p) من \(targets.count) مصادر")

        // نفس طريقة «فحص المصادر» التي تعمل على الجهاز: طلبات مستقلة لا تُلغى بإلغاء الواجهة،
        // تنطلق كلها معًا ثم نستلم نتيجة كل مصدر بالترتيب.
        let jobs: [(StorySource, Task<StoryPage, Error>)] = targets.map { s in
            (s, Task.detached { try await API.shared.stories(page: p, q: q, genre: g, source: s) })
        }

        let base = append ? items : []
        var groups: [StorySource: [StoryItem]] = [:]
        var anyNext = false
        var newErrors: [String] = []
        for (s, job) in jobs {
            let result = await job.result
            guard gen == generation else { note("تجاهل نتيجة قديمة"); return }
            switch result {
            case .success(let pg):
                let list = pg.items.values
                groups[s] = list
                sourceStatus[s] = "\(list.count)"
                if pg.nextPage == nil { exhausted.insert(s) } else { anyNext = true }
                note("\(s.name): \(list.count)")
            case .failure(let e):
                newErrors.append("\(s.name): \(e.localizedDescription)")
                sourceStatus[s] = "خطأ"
                exhausted.insert(s)
                note("\(s.name): خطأ \(e.localizedDescription)")
            }
            var seen = Set(base.map(\.url))
            let merged = interleave(targets.compactMap { groups[$0] }).filter { seen.insert($0.url).inserted }
            if !merged.isEmpty || append { items = base + merged }
        }
        if !append { errors = newErrors }
        var seenAll = Set(base.map(\.url))
        items = base + interleave(targets.compactMap { groups[$0] }).filter { seenAll.insert($0.url).inserted }
        page = p
        hasNext = anyNext
        didLoad = true
        note("انتهى: \(items.count) قصة")

        // لم يصل شيء والمصادر لم ترجع خطأ: نعيد المحاولة تلقائيًا
        if !append, items.isEmpty, newErrors.isEmpty, autoRetries < 2 {
            autoRetries += 1
            note("إعادة تلقائية \(autoRetries)")
            didLoad = false
            try? await Task.sleep(for: .milliseconds(500))
            guard gen == generation else { return }
            await reload()
        }
    }
}
