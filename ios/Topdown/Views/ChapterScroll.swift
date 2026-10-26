import SwiftUI
import UIKit
import ImageIO

/// مصدر صفحة: ملف محمّل أو روابط بديلة من الإنترنت (الأصل ثم بروكسي الموقع).
enum ReaderPageSource: Equatable {
    case local(URL)
    case remote([URL])
}

/// سطح تمرير واحد للفصل كله (UIScrollView) مع تكبير أصلي بالقرص وضغطتين.
/// الصفحات تُفك فقط عند اقترابها من الشاشة وتُحرَّر عند الابتعاد لتوفير الذاكرة.
struct ChapterScroll: UIViewRepresentable {
    let id: String
    let pages: [ReaderPageSource]
    let initialPage: Int
    let endTitle: String
    let nextTitle: String?
    var onNext: () -> Void
    var onBack: () -> Void
    var onTap: () -> Void
    var onPosition: (Int) -> Void
    var onScroll: (CGFloat, Bool) -> Void

    func makeUIView(context: Context) -> ChapterScrollView {
        let v = ChapterScrollView()
        updateUIView(v, context: context)
        return v
    }

    func updateUIView(_ v: ChapterScrollView, context: Context) {
        v.onNext = onNext; v.onBack = onBack; v.onTap = onTap
        v.onPosition = onPosition; v.onScroll = onScroll
        v.configure(id: id, pages: pages, initialPage: initialPage, endTitle: endTitle, nextTitle: nextTitle)
    }

    static func dismantleUIView(_ v: ChapterScrollView, coordinator: ()) {
        v.stop()
        v.onPosition = nil; v.onScroll = nil
    }
}

final class ChapterScrollView: UIScrollView, UIScrollViewDelegate {
    private let canvas = UIView()
    private var tiles: [UIImageView] = []
    private var spinners: [UIActivityIndicatorView] = []
    private var retries: [UIButton] = []
    private var failed = Set<Int>()
    private var ratios: [CGFloat] = []
    private var pending: [Int: CGFloat] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var pages: [ReaderPageSource] = []
    private var chapterID: String?
    private var generation = UUID()
    private var initialPage = 0
    private var restored = false
    private var layoutWidth: CGFloat = 0
    private var applying = false
    private var lastPage = -1

    private let footer = UIStackView()
    private let endLabel = UILabel()
    private let nextButton = UIButton(configuration: .filled())
    private let backButton = UIButton(configuration: .gray())

    var onNext: (() -> Void)?
    var onBack: (() -> Void)?
    var onTap: (() -> Void)?
    var onPosition: ((Int) -> Void)?
    var onScroll: ((CGFloat, Bool) -> Void)?

    private var busy: Bool { isTracking || isDragging || isDecelerating || isZooming || isZoomBouncing }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        canvas.backgroundColor = .black
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        addSubview(canvas)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)

        // بطاقة نهاية الفصل: التالي هو الإجراء الأساسي، والعودة ثانوية
        let gold = UIColor(red: 0.79, green: 0.69, blue: 0.56, alpha: 1)
        footer.axis = .vertical
        footer.spacing = 12
        footer.isLayoutMarginsRelativeArrangement = true
        footer.directionalLayoutMargins = .init(top: 22, leading: 18, bottom: 22, trailing: 18)
        footer.backgroundColor = UIColor(white: 1, alpha: 0.07)
        footer.layer.cornerRadius = 24
        footer.layer.cornerCurve = .continuous
        footer.layer.borderWidth = 1
        footer.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        endLabel.textColor = .white
        endLabel.textAlignment = .center
        endLabel.numberOfLines = 0
        endLabel.font = .preferredFont(forTextStyle: .headline)
        var next = UIButton.Configuration.filled()
        next.baseBackgroundColor = gold
        next.baseForegroundColor = .black
        next.cornerStyle = .large
        next.image = UIImage(systemName: "chevron.left")
        next.imagePlacement = .trailing
        next.imagePadding = 8
        nextButton.configuration = next
        var back = UIButton.Configuration.gray()
        back.baseForegroundColor = gold
        back.cornerStyle = .large
        back.title = "العودة للفصول"
        back.image = UIImage(systemName: "list.bullet")
        back.imagePlacement = .trailing
        back.imagePadding = 8
        backButton.configuration = back
        nextButton.addAction(UIAction { [weak self] _ in self?.onNext?() }, for: .touchUpInside)
        backButton.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        [nextButton, backButton].forEach { $0.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true }
        [endLabel, nextButton, backButton].forEach { footer.addArrangedSubview($0) }
        footer.setCustomSpacing(18, after: endLabel)
        canvas.addSubview(footer)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - الإعداد

    func configure(id: String, pages: [ReaderPageSource], initialPage: Int, endTitle: String, nextTitle: String?) {
        endLabel.text = endTitle
        nextButton.configuration?.title = nextTitle
        nextButton.isHidden = nextTitle == nil
        guard chapterID != id || self.pages != pages else { return }
        stop()
        chapterID = id
        self.pages = pages
        self.initialPage = initialPage
        restored = false
        layoutWidth = 0
        lastPage = -1
        failed = []
        pending = [:]
        ratios = Array(repeating: 1.45, count: pages.count)
        setZoomScale(1, animated: false)
        tiles.forEach { $0.removeFromSuperview() }
        spinners.forEach { $0.removeFromSuperview() }
        retries.forEach { $0.removeFromSuperview() }
        tiles = []; spinners = []; retries = []
        for i in pages.indices {
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFit
            iv.isAccessibilityElement = true
            iv.accessibilityLabel = "الصفحة \(i + 1)"
            canvas.addSubview(iv)
            tiles.append(iv)
            let sp = UIActivityIndicatorView(style: .medium)
            sp.color = .secondaryLabel
            sp.hidesWhenStopped = true
            canvas.addSubview(sp)
            spinners.append(sp)
            var cfg = UIButton.Configuration.gray()
            cfg.title = "إعادة تحميل الصفحة \(i + 1)"
            cfg.image = UIImage(systemName: "arrow.clockwise")
            cfg.imagePadding = 6
            cfg.cornerStyle = .capsule
            let b = UIButton(configuration: cfg)
            b.isHidden = true
            b.addAction(UIAction { [weak self] _ in self?.retry(i) }, for: .touchUpInside)
            canvas.addSubview(b)
            retries.append(b)
        }
        setNeedsLayout()
    }

    func stop() {
        generation = UUID()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func retry(_ i: Int) {
        failed.remove(i)
        retries[i].isHidden = true
        refreshVisible()
    }

    // MARK: - التخطيط

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !applying, bounds.width > 0 else { return }
        if layoutWidth != bounds.width && !busy { rebuild() }
        refreshVisible()
    }

    private func visibleRect() -> CGRect { convert(bounds, to: canvas) }
    private func page(at y: CGFloat) -> Int { tiles.firstIndex { $0.frame.maxY > y } ?? max(0, tiles.count - 1) }

    /// يعيد ترتيب الصفحات مع الحفاظ على موضع القراءة الحالي.
    private func rebuild() {
        guard bounds.width > 0 else { return }
        applying = true
        let old = visibleRect()
        let oldPage = page(at: old.minY + 1)
        let oldFrame = tiles.indices.contains(oldPage) ? tiles[oldPage].frame : .zero
        let fraction = oldFrame.height > 0 ? max(0, (old.minY - oldFrame.minY) / oldFrame.height) : 0
        let scale = zoomScale
        setZoomScale(1, animated: false)
        layoutWidth = bounds.width
        var y: CGFloat = 0
        for i in tiles.indices {
            let h = layoutWidth * ratios[i]
            tiles[i].frame = CGRect(x: 0, y: y, width: layoutWidth, height: h)
            spinners[i].center = CGPoint(x: layoutWidth / 2, y: y + min(h / 2, 220))
            retries[i].frame = CGRect(x: layoutWidth / 2 - 120, y: y + min(h / 2, 220) - 22, width: 240, height: 44)
            y += h
        }
        let fw = max(1, layoutWidth - 32)
        let fit = footer.systemLayoutSizeFitting(CGSize(width: fw, height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let fh = max(200, ceil(fit.height))
        footer.frame = CGRect(x: 16, y: y + 28, width: fw, height: fh)
        canvas.frame = CGRect(x: 0, y: 0, width: layoutWidth, height: y + fh + 28 + max(80, safeAreaInsets.bottom + 40))
        contentSize = canvas.bounds.size
        setZoomScale(scale, animated: false)
        let target = restored ? oldPage : min(max(0, initialPage), max(0, tiles.count - 1))
        let rect = tiles.indices.contains(target) ? tiles[target].frame : .zero
        let ty = (rect.minY + (restored ? fraction * rect.height : 0)) * scale
        setContentOffset(CGPoint(x: contentOffset.x, y: min(max(0, ty), max(0, contentSize.height - bounds.height))), animated: false)
        restored = true
        applying = false
    }

    private func settle() {
        if !busy && !pending.isEmpty {
            for (i, r) in pending { if ratios.indices.contains(i) { ratios[i] = r } }
            pending.removeAll()
            rebuild()
        }
        refreshVisible()
        report()
    }

    // MARK: - التحميل الكسول

    private func refreshVisible() {
        guard !applying, layoutWidth > 0 else { return }
        let visible = visibleRect()
        let near = visible.insetBy(dx: 0, dy: -bounds.height * 1.5 / max(1, zoomScale))
        let maxPixel = layoutWidth * UIScreen.main.scale * 1.6
        for i in tiles.indices {
            let wanted = tiles[i].frame.intersects(near)
            if !wanted {
                if tiles[i].image != nil { tiles[i].image = nil }
                tasks[i]?.cancel(); tasks[i] = nil
                spinners[i].stopAnimating()
                continue
            }
            guard tiles[i].image == nil, tasks[i] == nil, !failed.contains(i) else { continue }
            spinners[i].startAnimating()
            let token = generation
            let source = pages[i]
            tasks[i] = Task { @MainActor [weak self] in
                let result = await ChapterPageLoader.load(source, maxPixel: maxPixel)
                guard let self, !Task.isCancelled, self.generation == token, self.tiles.indices.contains(i) else { return }
                self.tasks[i] = nil
                self.spinners[i].stopAnimating()
                guard let (image, ratio) = result else {
                    self.failed.insert(i)
                    self.retries[i].isHidden = false
                    return
                }
                self.tiles[i].image = image
                if abs(self.ratios[i] - ratio) > 0.001 {
                    self.pending[i] = ratio
                    if !self.busy { self.settle() }
                }
            }
        }
    }

    private func report() {
        guard !applying, !isZooming else { return }
        let rect = visibleRect()
        let p = page(at: rect.minY + rect.height * 0.25)
        if p != lastPage { lastPage = p; onPosition?(p) }
        let bounce = contentOffset.y < 0 || contentOffset.y > max(0, contentSize.height - bounds.height)
        onScroll?(contentOffset.y, (isDragging || isDecelerating) && !bounce)
    }

    // MARK: - الإيماءات

    @objc private func handleTap() { onTap?() }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: canvas)
            let scale: CGFloat = 2.4
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { refreshVisible() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { settle() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { refreshVisible(); report() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
}

/// يجلب الصفحة (ملف أو شبكة مع الجلسة) ويفكّها خارج الخيط الرئيسي بدقة مناسبة للشاشة.
enum ChapterPageLoader {
    static func load(_ source: ReaderPageSource, maxPixel: CGFloat) async -> (UIImage, CGFloat)? {
        switch source {
        case .local(let url):
            return await Task.detached(priority: .userInitiated) { decode(url: url, maxPixel: maxPixel) }.value
        case .remote(let urls):
            for url in urls {
                if Task.isCancelled { return nil }
                guard let (data, resp) = try? await API.shared.session.data(for: API.shared.authorized(url)),
                      (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                if let r = await Task.detached(priority: .userInitiated, operation: { decode(data: data, maxPixel: maxPixel) }).value {
                    return r
                }
            }
            return nil
        }
    }

    private static func decode(url: URL, maxPixel: CGFloat) -> (UIImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(src, maxPixel: maxPixel)
    }

    private static func decode(data: Data, maxPixel: CGFloat) -> (UIImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(src, maxPixel: maxPixel)
    }

    private static func decode(_ src: CGImageSource, maxPixel: CGFloat) -> (UIImage, CGFloat)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        // صفحات الويبتون الطويلة: نحدد بالعرض لا بالطول حتى لا تفقد وضوحها
        let longest = max(w, h)
        let target = min(longest, maxPixel * max(1, h / w))
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: target]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return (UIImage(cgImage: cg), CGFloat(h / w))
    }
}

/// إظهار/إخفاء الأدوات حسب اتجاه التمرير: يختفي بسرعة عند النزول،
/// ولا يظهر إلا بتمرير مقصود للأعلى أو عند بداية الفصل.
struct ReaderScrollDirection {
    var revealDistance: CGFloat = 240
    private var previous: CGFloat?
    private var travel: CGFloat = 0

    mutating func update(offset: CGFloat, userScrolling: Bool) -> Bool? {
        defer { previous = offset }
        guard userScrolling, let previous else { travel = 0; return nil }
        if offset <= 16 { travel = 0; return true }
        let delta = offset - previous
        if delta == 0 { return nil }
        if (delta > 0) != (travel > 0) { travel = 0 }
        travel += delta
        let threshold: CGFloat = travel < 0 ? revealDistance : 14
        guard abs(travel) >= threshold else { return nil }
        let visible = travel < 0
        travel = 0
        return visible
    }
}
