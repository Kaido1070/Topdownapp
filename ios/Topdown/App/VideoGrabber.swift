import Foundation
import AVFoundation

/// يستخرج رابط الفيديو الفعلي من روابط يوتيوب وتيك توك (نفس طريقة تطبيقات التنزيل):
/// - يوتيوب: واجهة InnerTube الرسمية بعميل أندرويد VR/iOS (روابط مباشرة بدون فك تشفير)،
///   ثم ندمج الفيديو والصوت على الجهاز بدون إعادة ترميز.
/// - تيك توك: خدمة tikwm.com (بدون العلامة المائية).
enum VideoGrabber {
    struct Source {
        var title: String
        var video: URL
        /// صوت منفصل (يوتيوب بجودة أعلى من 360p)
        var audio: URL?
        var headers: [String: String] = [:]
        /// روابط googlevideo تُنزَّل على دفعات لتجنّب الإبطاء
        var chunked = false
        var videoLength: Int64?
        var audioLength: Int64?
    }

    enum GrabError: LocalizedError {
        case unsupported, blocked(String), noFormat, photoPost
        var errorDescription: String? {
            switch self {
            case .unsupported: "تعذّر قراءة الرابط"
            case .blocked(let r): "يوتيوب رفض الطلب: " + r
            case .noFormat: "لا توجد صيغة قابلة للتنزيل لهذا الفيديو"
            case .photoPost: "هذا المنشور صور وليس فيديو"
            }
        }
    }

    enum Kind { case youtube(String), tiktok, direct }

    static func kind(of url: URL) -> Kind {
        let host = (url.host() ?? "").lowercased()
        if host.hasSuffix("youtu.be") || host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com"),
           let id = youtubeID(url) {
            return .youtube(id)
        }
        if host.hasSuffix("tiktok.com") { return .tiktok }
        return .direct
    }

    static func youtubeID(_ url: URL) -> String? {
        let host = (url.host() ?? "").lowercased()
        let parts = url.pathComponents.filter { $0 != "/" }
        var id: String?
        if host.hasSuffix("youtu.be") {
            id = parts.first
        } else if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            id = v
        } else if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
            id = parts[1]
        }
        guard let id, id.count == 11 else { return nil }
        return id
    }

    // MARK: يوتيوب

    private struct Client {
        let name: String, id: String, version: String, ua: String
        let extra: [String: Any]
    }

    private static let clients: [Client] = [
        Client(name: "ANDROID_VR", id: "28", version: "1.65.10",
               ua: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
               extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32,
                       "osName": "Android", "osVersion": "12L"]),
        Client(name: "IOS", id: "5", version: "20.10.4",
               ua: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
               extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2",
                       "osName": "iPhone", "osVersion": "18.3.2.22D82"]),
    ]

    static func youtube(_ id: String, maxHeight: Int) async throws -> Source {
        var lastReason = "غير معروف"
        for client in clients {
            var ctx: [String: Any] = ["clientName": client.name, "clientVersion": client.version, "hl": "ar", "gl": "SA"]
            ctx.merge(client.extra) { a, _ in a }
            let body: [String: Any] = ["context": ["client": ctx], "videoId": id,
                                       "contentCheckOk": true, "racyCheckOk": true]
            var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(client.ua, forHTTPHeaderField: "User-Agent")
            req.setValue(client.id, forHTTPHeaderField: "X-YouTube-Client-Name")
            req.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let status = json["playabilityStatus"] as? [String: Any]
            if (status?["status"] as? String) != "OK" {
                lastReason = status?["reason"] as? String ?? lastReason
                continue
            }
            let title = ((json["videoDetails"] as? [String: Any])?["title"] as? String) ?? id
            let streaming = json["streamingData"] as? [String: Any] ?? [:]
            if let src = pick(streaming, title: title, maxHeight: maxHeight, ua: client.ua) { return src }
        }
        throw lastReason == "غير معروف" ? GrabError.noFormat : GrabError.blocked(lastReason)
    }

    private static func pick(_ streaming: [String: Any], title: String, maxHeight: Int, ua: String) -> Source? {
        typealias F = [String: Any]
        func url(_ f: F) -> URL? { (f["url"] as? String).flatMap(URL.init(string:)) }
        func height(_ f: F) -> Int { f["height"] as? Int ?? 0 }
        func bitrate(_ f: F) -> Int { f["bitrate"] as? Int ?? 0 }
        func length(_ f: F) -> Int64? { (f["contentLength"] as? String).flatMap { Int64($0) } }
        func mime(_ f: F) -> String { f["mimeType"] as? String ?? "" }

        let adaptive = (streaming["adaptiveFormats"] as? [F] ?? []).filter { url($0) != nil }
        let muxed = (streaming["formats"] as? [F] ?? []).filter { url($0) != nil && mime($0).hasPrefix("video/mp4") }

        // H.264 فقط (يعمل على كل الأجهزة ويُدمج بدون إعادة ترميز)
        let videos = adaptive.filter { mime($0).hasPrefix("video/mp4") && mime($0).contains("avc1") && height($0) <= maxHeight }
            .sorted { (height($0), bitrate($0)) > (height($1), bitrate($1)) }
        let audios = adaptive.filter { mime($0).hasPrefix("audio/mp4") }.sorted { bitrate($0) > bitrate($1) }
        let bestMuxed = muxed.filter { height($0) <= maxHeight }.max { height($0) < height($1) } ?? muxed.first

        if let v = videos.first, let a = audios.first, height(v) > (bestMuxed.map(height) ?? 0) {
            return Source(title: title, video: url(v)!, audio: url(a)!, headers: ["User-Agent": ua], chunked: true,
                          videoLength: length(v), audioLength: length(a))
        }
        if let m = bestMuxed {
            return Source(title: title, video: url(m)!, headers: ["User-Agent": ua], chunked: true, videoLength: length(m))
        }
        return nil
    }

    // MARK: تيك توك

    static func tiktok(_ link: URL) async throws -> Source {
        var comps = URLComponents(string: "https://www.tikwm.com/api/")!
        comps.queryItems = [URLQueryItem(name: "url", value: link.absoluteString), URLQueryItem(name: "hd", value: "1")]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any] else {
            throw GrabError.unsupported
        }
        if let images = d["images"] as? [Any], !images.isEmpty { throw GrabError.photoPost }
        func abs(_ s: String?) -> URL? {
            guard let s, !s.isEmpty else { return nil }
            return URL(string: s.hasPrefix("/") ? "https://www.tikwm.com" + s : s)
        }
        guard let video = abs(d["hdplay"] as? String) ?? abs(d["play"] as? String) else { throw GrabError.noFormat }
        let title = (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "TikTok \(d["id"] as? String ?? "")"
        return Source(title: title, video: video)
    }

    // MARK: التنزيل والدمج

    /// ينزّل رابطًا إلى ملف مؤقت. الروابط المقسّمة تُجلب على دفعات 8MB.
    static func fetch(_ url: URL, headers: [String: String], chunked: Bool, length: Int64?,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let target = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        if chunked {
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            let chunk: Int64 = 8 * 1024 * 1024
            var start: Int64 = 0
            var total = length
            while total == nil || start < total! {
                try Task.checkCancellation()
                var req = URLRequest(url: url)
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                req.setValue("bytes=\(start)-\(start + chunk - 1)", forHTTPHeaderField: "Range")
                let (data, response) = try await URLSession.shared.data(for: req)
                let http = response as? HTTPURLResponse
                guard let code = http?.statusCode, (200..<300).contains(code) else {
                    throw URLError(.badServerResponse)
                }
                if total == nil, let range = http?.value(forHTTPHeaderField: "Content-Range"),
                   let size = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                    total = size
                }
                try handle.write(contentsOf: data)
                start += Int64(data.count)
                if let total, total > 0 { progress(Double(start) / Double(total)) }
                if data.isEmpty || code == 200 || (total == nil && Int64(data.count) < chunk) { break }
            }
            return target
        }
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let delegate = ProgressDelegate(progress)
        let (tmp, response) = try await URLSession.shared.download(for: req, delegate: delegate)
        if let code = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }

    /// يدمج مسار الفيديو ومسار الصوت في ملف mp4 بدون إعادة ترميز
    static func mux(video: URL, audio: URL, to output: URL) async throws {
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: video, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let a = AVURLAsset(url: audio)
        guard let vSrc = try await v.loadTracks(withMediaType: .video).first,
              let vDst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw GrabError.noFormat
        }
        let vRange = try await vSrc.load(.timeRange)
        try vDst.insertTimeRange(vRange, of: vSrc, at: .zero)
        vDst.preferredTransform = try await vSrc.load(.preferredTransform)
        if let aSrc = try await a.loadTracks(withMediaType: .audio).first,
           let aDst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aRange = try await aSrc.load(.timeRange)
            let range = CMTimeRange(start: aRange.start, duration: min(aRange.duration, vRange.duration))
            try aDst.insertTimeRange(range, of: aSrc, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw GrabError.noFormat
        }
        try await export.export(to: output, as: .mp4)
    }

    static func safeName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "video" : String(cleaned.prefix(80))
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
