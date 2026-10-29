import Foundation
import ImageIO
import UniformTypeIdentifiers

/// جودة صور القصص للتحميل والقراءة.
enum StoryImageQuality: String, CaseIterable, Identifiable {
    case original, high, balanced, saver
    var id: String { rawValue }

    var name: String {
        switch self {
        case .original: "الأصلية"
        case .high: "عالية"
        case .balanced: "متوازنة"
        case .saver: "موفّر البيانات"
        }
    }

    var detail: String {
        switch self {
        case .original: "بدون أي ضغط — أكبر حجم"
        case .high: "عرض 1440 • وضوح ممتاز • توفير ~40٪"
        case .balanced: "عرض 1080 • مناسب للجوال • توفير ~60٪"
        case .saver: "عرض 720 • للنت البطيء • توفير ~80٪"
        }
    }

    /// أقصى عرض للصفحة بالبكسل (nil = بدون تغيير)
    var maxWidth: CGFloat? {
        switch self {
        case .original: nil
        case .high: 1440
        case .balanced: 1080
        case .saver: 720
        }
    }

    var compression: Double {
        switch self {
        case .original: 1
        case .high: 0.8
        case .balanced: 0.68
        case .saver: 0.5
        }
    }

    /// نسخة مضغوطة من الصورة عبر خدمة wsrv.nl (مفتوحة المصدر) لتوفير البيانات قبل وصولها للجهاز.
    func remote(_ raw: String) -> URL? {
        guard let w = maxWidth, raw.hasPrefix("http"), !WsrvPolicy.isBlocked(raw) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let enc = raw.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://wsrv.nl/?url=\(enc)&w=\(Int(w))&q=\(Int(compression * 100))&output=webp&we")
    }

    static var download: StoryImageQuality {
        StoryImageQuality(rawValue: UserDefaults.standard.string(forKey: "stories.quality") ?? "") ?? .balanced
    }

    static var reading: StoryImageQuality {
        StoryImageQuality(rawValue: UserDefaults.standard.string(forKey: "reader.quality") ?? "") ?? .original
    }
}

/// إعادة ضغط الصور على الجهاز إلى HEIC (أو JPEG) بعرض مناسب للشاشة.
enum ImageCompressor {
    struct Output { let data: Data; let ext: String }

    static func compress(_ data: Data, maxWidth: CGFloat?, quality: Double) -> Output? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        let scale = min(1, (maxWidth ?? CGFloat(w)) / CGFloat(w))
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(w, h) * scale]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        for (type, ext) in [(UTType.heic, "heic"), (UTType.jpeg, "jpg")] {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(dest), out.length > 0 {
                // نحتفظ بالمضغوط فقط إذا كان أصغر فعلًا
                return out.length < data.count ? Output(data: out as Data, ext: ext) : nil
            }
        }
        return nil
    }
}

/// بعض المواقع ترفضها خدمة الضغط؛ نتذكرها فلا نضيّع طلبًا عليها مرة ثانية.
enum WsrvPolicy {
    nonisolated(unsafe) private static var blocked: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "wsrv.blocked") ?? [])
    private static let lock = NSLock()

    static func isBlocked(_ raw: String) -> Bool {
        guard let h = URL(string: raw)?.host() else { return true }
        return lock.withLock { blocked.contains(h) }
    }

    /// يُستدعى عند فشل رابط wsrv: نستخرج موقع الصورة الأصلية ونضيفه للقائمة.
    static func failed(_ wsrvURL: URL) {
        guard wsrvURL.host() == "wsrv.nl",
              let raw = URLComponents(url: wsrvURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let h = URL(string: raw)?.host() else { return }
        lock.withLock {
            blocked.insert(h)
            UserDefaults.standard.set(Array(blocked), forKey: "wsrv.blocked")
        }
    }
}
