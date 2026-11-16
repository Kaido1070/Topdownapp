import SwiftUI
import ImageIO

/// تحميل الصور عبر جلسة الموقع (مع الكوكيز) وتصغيرها وحفظها مؤقتًا.
actor ImagePipeline {
    static let shared = ImagePipeline()
    private let cache = NSCache<NSString, UIImage>()
    /// روابط رفضها الخادم (404/403…) مع وقت الرفض؛ الأخطاء المؤقتة والإلغاء لا تُسجَّل
    private var failed: [URL: Date] = [:]

    init() { cache.totalCostLimit = 120 << 20 }

    func image(_ candidates: [URL], maxPixel: CGFloat) async -> UIImage? {
        for url in candidates {
            if let at = failed[url] {
                if Date().timeIntervalSince(at) < 300 { continue }
                failed[url] = nil
            }
            let key = "\(url.absoluteString)#\(Int(maxPixel))" as NSString
            if let hit = cache.object(forKey: key) { return hit }
            // التمرير السريع يلغي الطلب: لا نعتبره فشلًا وإلا اختفت الصورة حتى إعادة فتح التطبيق
            guard let (data, resp) = try? await API.shared.session.data(for: API.shared.authorized(url)) else {
                if Task.isCancelled { return nil }
                continue
            }
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = Self.downsample(data, maxPixel: maxPixel) else {
                failed[url] = Date()
                continue
            }
            cache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4))
            return img
        }
        return nil
    }

    func clear() { cache.removeAllObjects(); failed.removeAll() }

    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

struct RemoteImage: View {
    let urls: [URL]
    var maxPixel: CGFloat = 700
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.06))
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: urls) {
            let img = await ImagePipeline.shared.image(urls, maxPixel: maxPixel)
            if Task.isCancelled && img == nil { return }
            withAnimation(.easeOut(duration: 0.2)) { image = img; failed = img == nil }
        }
    }
}
