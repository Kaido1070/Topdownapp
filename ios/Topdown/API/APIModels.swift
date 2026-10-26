import Foundation

// نماذج تطابق واجهات موقع Topdown (functions/api/[[path]].ts و src/types.ts)

struct MediaItem: Codable, Hashable, Identifiable {
    var providerId: String
    var id: String
    var title: String
    var thumbnail: String?
    var durationSeconds: Double?
    var embed: String?
    var tags: [String]?
    var createdAt: Double?
    var watchedAt: Double?
    var progressSeconds: Double?

    var key: String { providerId + ":" + id }

    /// الأعمال من المصادر الجديدة تفتح تفاصيل وحلقات، والمصدر القديم يُشغَّل مباشرة.
    var opensDetails: Bool {
        providerId != "hentaitime" && AnimeSource.allCases.contains { $0.rawValue == providerId && $0 != .all && $0 != .legacy }
    }

    var sourceName: String {
        AnimeSource(rawValue: providerId)?.name ?? (providerId == "hentaitime" ? AnimeSource.legacy.name : providerId)
    }

    var durationText: String? {
        guard let d = durationSeconds, d > 0 else { return nil }
        return "\(Int(d) / 60) دقيقة"
    }

    /// جسم الطلب كما يرسله الموقع (بدون حقول المكتبة).
    var payload: MediaItem {
        MediaItem(providerId: providerId, id: id, title: title, thumbnail: thumbnail,
                  durationSeconds: durationSeconds, embed: embed, tags: tags)
    }
}

struct VideoPage: Decodable {
    var items: Lossy<MediaItem>
    var related: Lossy<MediaItem>?
    var nextPage: Int?
    var totalPages: Int?
    var stale: Bool?
    var cachedAt: String?
}

struct WorkDetails: Decodable {
    var title: String?
    var categoryName: String?
    var episodes: Lossy<MediaItem>?
    var episodesWarning: String?
}

struct Resolved: Decodable {
    var url: String
    var kind: String
}

struct ItemsResponse<T: Decodable>: Decodable { var items: Lossy<T> }

struct Tag: Decodable, Hashable, Identifiable { var id: String; var name: String }
struct TagsResponse: Decodable { var tags: [Tag]? }
struct GenresResponse: Decodable { var genres: [Tag]? }

struct StoryItem: Codable, Hashable, Identifiable {
    var title: String
    var url: String
    var cover: String?
    var meta: String?
    var latestChapter: Double?
    var views: Double?
    var popularity: Double?
    var updatedAt: String?
    var createdAt: Double?
    var lastChapterUrl: String?
    var lastChapterTitle: String?
    var watchedAt: Double?
    var id: String { url }

    var payload: StoryItem {
        StoryItem(title: title, url: url, cover: cover, latestChapter: latestChapter)
    }
}

struct StoryPage: Decodable {
    var items: Lossy<StoryItem>
    var nextPage: Int?
    var total: Int?
    var totalPages: Int?
    var stale: Bool?
    var cachedAt: String?
}

struct ChapterLink: Codable, Hashable, Identifiable {
    var url: String
    var title: String
    var number: Double?
    var publishedAt: String?
    var id: String { url }

    var displayTitle: String {
        if let n = number { return "الفصل " + ChapterDownload.format(n) }
        return title.isEmpty ? "فصل" : title
    }
}

struct StoryDetail: Decodable {
    var title: String
    var url: String
    var cover: String?
    var summary: String?
    var chapters: Lossy<ChapterLink>
    var firstChapter: Double?
    var latestChapter: Double?
    var chaptersWarning: String?
}

struct StoryChapter: Decodable {
    var title: String?
    var images: [String]
}

struct DirectorySource: Decodable, Identifiable {
    var id: String
    var name: String
    var url: String
    var kind: String
    var review: String?
}

struct SourceCheck: Decodable {
    var id: String
    var reachable: Bool
    var httpStatus: Int?
    var latencyMs: Double?
    var code: String?
}

enum AnimeSource: String, CaseIterable, Identifiable {
    case all
    case legacy
    case arabshentai = "arabshentai-net"
    case hentaixplanet, hentaibalo, saudihentai, ristohentai, nxxhentai
    var id: String { rawValue }
    var name: String {
        switch self {
        case .all: "كل المصادر"
        case .legacy: "المصدر القديم"
        case .arabshentai: "ArabSHentai.net"
        case .hentaixplanet: "HentaiXPlanet"
        case .hentaibalo: "HentaiBalo"
        case .saudihentai: "SaudiHentai"
        case .ristohentai: "RistoHentai"
        case .nxxhentai: "NxxHentai"
        }
    }
    static var concrete: [AnimeSource] { allCases.filter { $0 != .all } }
}

enum StorySource: String, CaseIterable, Identifiable {
    case all, legacy, arabtoons, arabtaku, hentaislayer
    var id: String { rawValue }
    var name: String {
        switch self {
        case .all: "كل المصادر"
        case .legacy: "المصدر القديم"
        case .arabtoons: "ArabToons"
        case .arabtaku: "Arabtaku"
        case .hentaislayer: "HentaiSlayer"
        }
    }
    static var concrete: [StorySource] { allCases.filter { $0 != .all } }
}

enum DurationFilter: String, CaseIterable, Identifiable {
    case all, short, medium, long
    var id: String { rawValue }
    var name: String {
        switch self {
        case .all: "كل المدد"
        case .short: "أقل من 10 دقائق"
        case .medium: "10 – 20 دقيقة"
        case .long: "20 دقيقة وأكثر"
        }
    }
    func matches(_ item: MediaItem) -> Bool {
        if self == .all { return true }
        guard let s = item.durationSeconds, s > 0 else { return false }
        switch self {
        case .short: return s < 600
        case .medium: return s >= 600 && s < 1200
        default: return s >= 1200
        }
    }
}

/// مصفوفة تتجاهل العناصر التالفة بدل أن تُفشل الصفحة كلها.
struct Lossy<T: Decodable>: Decodable {
    var values: [T]
    init(_ values: [T] = []) { self.values = values }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else { _ = try? c.decode(Skip.self) }
        }
        values = out
    }
    private struct Skip: Decodable {}
}

extension Lossy: Hashable where T: Hashable {}
extension Lossy: Equatable where T: Equatable {}

/// يدمج نتائج المصادر بالتناوب مثل interleave() في الموقع.
func interleave<T>(_ groups: [[T]]) -> [T] {
    var out: [T] = []
    let maxCount = groups.map(\.count).max() ?? 0
    for i in 0..<maxCount { for g in groups where i < g.count { out.append(g[i]) } }
    return out
}
