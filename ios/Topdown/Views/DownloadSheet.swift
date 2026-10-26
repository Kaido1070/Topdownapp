import SwiftUI

struct DownloadSheet: View {
    let request: DownloadRequest
    @Environment(DownloadCenter.self) private var center
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch request {
                case .video(let v): VideoQualityList(video: v, done: { dismiss() })
                case .chapter(let c, let s): ChapterOptions(chapter: c, story: s, done: { dismiss() })
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

private struct VideoQualityList: View {
    let video: CapturedVideo
    let done: () -> Void
    @Environment(DownloadCenter.self) private var center
    @State private var options: [QualityOption]?
    @AppStorage("preferredQuality") private var preferred = "ask"
    @State private var remember = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "film.stack").font(.title2).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(video.title).font(.headline).lineLimit(2)
                        Text(video.kind == "hls" ? "بث HLS — يُحفظ للمشاهدة بدون إنترنت" : "ملف MP4")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let existing = center.isDownloaded(video), existing.state == .completed {
                    Label("محمّل مسبقًا بجودة \(existing.qualityLabel)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            Section("اختر الجودة") {
                if let options {
                    ForEach(options) { opt in
                        Button { pick(opt) } label: {
                            HStack {
                                Text(opt.label)
                                    .font(.headline.monospacedDigit())
                                    .frame(minWidth: 64)
                                    .padding(.vertical, 6)
                                    .glassEffect(.regular.tint(Theme.accent.opacity(0.35)), in: .capsule)
                                VStack(alignment: .leading) {
                                    Text(opt.height >= 1080 ? "عالية الدقة" : opt.height >= 720 ? "HD" : opt.height > 0 ? "حجم أصغر" : "الافتراضي")
                                    if !opt.detail.isEmpty {
                                        Text(opt.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } else {
                    HStack { ProgressView(); Text("جاري قراءة الجودات المتاحة…").foregroundStyle(.secondary) }
                }
            }
            if (options?.count ?? 0) > 1 {
                Section {
                    Toggle("استخدم هذه الجودة دائمًا", isOn: $remember)
                }
            }
        }
        .navigationTitle("تحميل الفيديو")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let opts = await center.qualityOptions(for: video)
            if let auto = center.autoPick(opts), preferred != "ask" {
                pick(auto)
            } else {
                withAnimation { options = opts }
            }
        }
    }

    private func pick(_ opt: QualityOption) {
        if remember, opt.height > 0 { preferred = String(opt.height) }
        center.download(video, quality: opt)
        done()
    }
}

private struct ChapterOptions: View {
    let chapter: CapturedChapter
    let story: CapturedStory
    let done: () -> Void
    @Environment(DownloadCenter.self) private var center

    private var link: ChapterLink {
        story.chapters.first { $0.url == chapter.url } ?? ChapterLink(url: chapter.url, title: chapter.title, number: nil)
    }

    private var remaining: [ChapterLink] {
        story.chapters.filter { center.isDownloaded(chapter: $0.url)?.state != .completed }
    }

    private var following: [ChapterLink] {
        guard let n = link.number else { return [] }
        return story.chapters.filter { ($0.number ?? -1) > n }.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(story.title).font(.headline)
                    Text(link.number.map { "الفصل " + ChapterDownload.format($0) } ?? chapter.title)
                        .foregroundStyle(.secondary)
                    Text("\(chapter.images.count) صفحة").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("التحميل للقراءة بدون إنترنت") {
                Button {
                    center.download(chapters: [link], of: story, current: chapter); done()
                } label: {
                    Label("تحميل هذا الفصل", systemImage: "arrow.down.doc.fill")
                }
                if following.count > 0 {
                    Button {
                        center.download(chapters: Array(following.prefix(10)), of: story); done()
                    } label: {
                        Label("تحميل الفصول التالية (\(min(10, following.count)))", systemImage: "forward.end.fill")
                    }
                }
                if remaining.count > 1 {
                    Button {
                        center.download(chapters: remaining, of: story, current: chapter); done()
                    } label: {
                        Label("تحميل كل الفصول (\(remaining.count))", systemImage: "books.vertical.fill")
                    }
                }
            }
        }
        .navigationTitle("تحميل القصة")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum DownloadRequest: Identifiable {
    case video(CapturedVideo)
    case chapter(CapturedChapter, CapturedStory)
    var id: String {
        switch self {
        case .video(let v): "v:" + v.id
        case .chapter(let c, _): "c:" + c.url
        }
    }
}
