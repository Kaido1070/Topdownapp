import Foundation

enum DownloadState: String, Codable {
    case queued, downloading, paused, completed, failed
    var isActive: Bool { self == .queued || self == .downloading || self == .paused }
}

struct VideoDownload: Codable, Identifiable, Hashable {
    var id: String
    var providerId: String
    var itemId: String
    var title: String
    var sourceURL: String
    var kind: String            // hls | mp4
    var qualityLabel: String
    var thumbnailFile: String?  // مسار نسبي داخل مجلد التطبيق
    var localPath: String?      // مسار نسبي لملف الفيديو أو حزمة movpkg
    var durationSeconds: Double?
    var state: DownloadState
    var progress: Double
    var bytes: Int64
    var createdAt: Date
    var watchedSeconds: Double = 0
    var errorMessage: String?
}

struct ChapterDownload: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var title: String
    var number: Double?
    var folder: String          // مسار نسبي
    var pageCount: Int
    var pages: [String]         // أسماء الملفات بالترتيب
    var state: DownloadState
    var progress: Double
    var createdAt: Date
    var lastReadPage: Int = 0
    var errorMessage: String?
    // حقول اختيارية (متوافقة مع التحميلات القديمة)
    var sources: [String]? = nil      // روابط الصفحات الأصلية (للاستكمال بدون إعادة جلب)
    var pagesDone: Int? = nil         // الصفحات المكتملة
    var bytes: Int64? = nil           // الحجم على الجهاز
    var order: Double? = nil          // ترتيب الطابور (الأصغر أولًا)
    var quality: String? = nil        // جودة التحميل

    var displayTitle: String {
        if let n = number { return "الفصل " + Self.format(n) }
        return title.isEmpty ? "فصل" : title
    }

    static func format(_ n: Double) -> String {
        n.rounded() == n ? String(Int(n)) : String(n)
    }
}

struct StoryDownload: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var title: String
    var coverFile: String?
    var chapters: [ChapterDownload]
    var allChapters: [ChapterLink] = []
    var updatedAt: Date

    var sortedChapters: [ChapterDownload] {
        chapters.sorted { ($0.number ?? .infinity, $0.createdAt) < ($1.number ?? .infinity, $1.createdAt) }
    }
    var completedChapters: [ChapterDownload] { sortedChapters.filter { $0.state == .completed } }
}

struct LibrarySnapshot: Codable {
    var videos: [VideoDownload] = []
    var stories: [StoryDownload] = []
}

enum Storage {
    static let home = URL(filePath: NSHomeDirectory())
    static let documents = URL.documentsDirectory
    static let root = documents.appending(path: "Topdown", directoryHint: .isDirectory)
    static let videosDir = make(root.appending(path: "Videos", directoryHint: .isDirectory))
    static let storiesDir = make(root.appending(path: "Stories", directoryHint: .isDirectory))
    static let thumbsDir = make(root.appending(path: ".thumbs", directoryHint: .isDirectory))
    static let filesDir = make(root.appending(path: "Files", directoryHint: .isDirectory))
    static let libraryFile = URL.applicationSupportDirectory.appending(path: "library.json")

    @discardableResult
    static func make(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// المسارات تُحفظ نسبيًا لأن مسار حاوية التطبيق يتغيّر بين التحديثات.
    static func relative(_ url: URL) -> String {
        let h = home.standardizedFileURL.path()
        let p = url.standardizedFileURL.path()
        return p.hasPrefix(h) ? String(p.dropFirst(h.count)) : p
    }

    static func absolute(_ path: String) -> URL {
        path.hasPrefix("/") && !path.hasPrefix(home.path()) && FileManager.default.fileExists(atPath: path)
            ? URL(filePath: path)
            : home.appending(path: path)
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "topdown" : cleaned).prefix(80))
    }

    static func hash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path(), isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path())
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct CapturedVideo: Identifiable, Equatable {
    var id: String { providerId + ":" + itemId }
    let providerId: String
    let itemId: String
    let title: String
    let thumbnail: String?
    let durationSeconds: Double?
    let url: URL
    let kind: String // hls | mp4 | direct

    init(providerId: String, itemId: String, title: String, thumbnail: String?, durationSeconds: Double?, url: URL, kind: String) {
        self.providerId = providerId; self.itemId = itemId; self.title = title; self.thumbnail = thumbnail
        self.durationSeconds = durationSeconds; self.url = url; self.kind = kind
    }

    init?(_ item: MediaItem, _ resolved: Resolved) {
        guard let url = Site.url(resolved.url) else { return nil }
        self.init(providerId: item.providerId, itemId: item.id, title: item.title, thumbnail: item.thumbnail,
                  durationSeconds: item.durationSeconds, url: url, kind: resolved.kind)
    }
}

struct CapturedStory: Equatable {
    let title: String
    let url: String
    let cover: String?
    let chapters: [ChapterLink]
}

struct CapturedChapter: Equatable {
    let url: String
    let title: String
    let images: [String]
}
