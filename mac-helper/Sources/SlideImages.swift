import AppKit
import CryptoKit
import ImageIO
import PDFKit

/// Image formats in order of preference (smallest first). All are encoded with ImageIO.
enum ImageFormat: String, CaseIterable {
    case avif, heic, jpeg

    var uti: String {
        switch self {
        case .avif: return "public.avif"
        case .heic: return "public.heic"
        case .jpeg: return "public.jpeg"
        }
    }

    var mime: String { "image/\(rawValue)" }

    static let encodable: [ImageFormat] = {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return allCases.filter { ids.contains($0.uti) }
    }()

    /// Picks the most compact format that both the client and this Mac support.
    static func best(from clientList: String) -> ImageFormat {
        let wanted = clientList.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return encodable.first { wanted.contains($0.rawValue) } ?? .jpeg
    }
}

struct ImageSpec: Hashable {
    var format: ImageFormat
    var width: Int
    var quality: Double

    /// Presets for Bluetooth (small) – AVIF/HEIC are ~4x smaller than JPEG, so they get more pixels.
    static func bluetooth(_ preset: String, format: ImageFormat) -> ImageSpec {
        let compact = format != .jpeg
        switch preset {
        case "low": return ImageSpec(format: format, width: compact ? 800 : 560, quality: compact ? 0.4 : 0.4)
        case "high": return ImageSpec(format: format, width: compact ? 1600 : 1200, quality: compact ? 0.6 : 0.6)
        default: return ImageSpec(format: format, width: compact ? 1200 : 800, quality: 0.5)
        }
    }
}

struct EncodedImage {
    var data: Data
    var spec: ImageSpec
    var encodeMs: Int
}

/// Renders slide images from the PDF that PowerPoint exported. All PDF work happens on a private queue;
/// completions are called on the main queue.
final class SlideImages {
    private let queue = DispatchQueue(label: "pptremote.images", qos: .userInitiated)

    // Only touched on `queue`.
    private var document: PDFDocument?
    private var pageForSlide: [Int: Int] = [:]
    private var cache: [String: EncodedImage] = [:]
    private var cacheOrder: [String] = []

    // Main-queue copies.
    private(set) var isLoaded = false
    /// Content key per slide (index 0 = slide 1); "" when the slide has no image (e.g. hidden & not exported).
    private(set) var keys: [String] = []
    /// Width / height of the slides.
    private(set) var aspect: CGFloat = 16.0 / 9.0

    /// Loads the PDF, maps pages to slides and computes a content key per slide.
    func load(pdfPath: String?, hidden: [Bool], completion: @escaping () -> Void) {
        queue.async {
            self.cache.removeAll()
            self.cacheOrder.removeAll()
            self.pageForSlide.removeAll()
            self.document = nil
            var keys = [String](repeating: "", count: hidden.count)
            var aspect: CGFloat = 16.0 / 9.0
            if let path = pdfPath {
                if let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
                    self.document = doc
                    self.mapPages(doc: doc, hidden: hidden)
                    if let b = doc.page(at: 0)?.bounds(for: .mediaBox), b.height > 0 { aspect = b.width / b.height }
                    let t = Date()
                    for (slide, page) in self.pageForSlide where slide >= 1 && slide <= keys.count {
                        if let p = doc.page(at: page) { keys[slide - 1] = Self.contentKey(p) }
                    }
                    Log.write("Loaded PDF with \(doc.pageCount) pages for \(hidden.count) slides (keys in \(Int(Date().timeIntervalSince(t) * 1000)) ms)")
                } else {
                    Log.write("Could not open exported PDF at \(path)")
                }
            }
            let loaded = self.document != nil
            DispatchQueue.main.async {
                self.isLoaded = loaded
                self.keys = keys
                self.aspect = aspect
                completion()
            }
        }
    }

    func key(for slide: Int) -> String {
        slide >= 1 && slide <= keys.count ? keys[slide - 1] : ""
    }

    func image(slide: Int, spec: ImageSpec, completion: @escaping (EncodedImage?) -> Void) {
        queue.async {
            let img = self.encode(slide: slide, spec: spec)
            DispatchQueue.main.async { completion(img) }
        }
    }

    // MARK: - Private (on queue)

    private func mapPages(doc: PDFDocument, hidden: [Bool]) {
        // Hidden slides are usually left out of PDF exports; map pages around them when that happens.
        let visible = hidden.enumerated().filter { !$0.element }.map { $0.offset + 1 }
        if doc.pageCount == hidden.count || hidden.isEmpty {
            for i in 0..<doc.pageCount { pageForSlide[i + 1] = i }
        } else if doc.pageCount == visible.count {
            for (page, slide) in visible.enumerated() { pageForSlide[slide] = page }
        } else {
            for i in 0..<min(doc.pageCount, hidden.count) { pageForSlide[i + 1] = i }
        }
    }

    private func encode(slide: Int, spec: ImageSpec) -> EncodedImage? {
        let cacheKey = "\(slide)-\(spec.format.rawValue)-\(spec.width)-\(spec.quality)"
        if let hit = cache[cacheKey] { return hit }
        guard let doc = document, let pageIndex = pageForSlide[slide], let page = doc.page(at: pageIndex),
              let cg = Self.render(page, width: max(64, min(spec.width, 2400))) else { return nil }
        let t = Date()
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, spec.format.uti as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: spec.quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let result = EncodedImage(data: data as Data, spec: spec, encodeMs: Int(Date().timeIntervalSince(t) * 1000))
        cache[cacheKey] = result
        cacheOrder.append(cacheKey)
        if cacheOrder.count > 400 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        return result
    }

    private static func render(_ page: PDFPage, width: Int) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Even sizes: large AVIF/HEIC images are stored as tile grids, and grids with an odd width or height
        // are invalid (MIAF 7.3.11.4.2) - Chrome on Android refuses to show them.
        let width = width & ~1
        let height = Int((Double(width) * Double(bounds.height) / Double(bounds.width) / 2).rounded()) * 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Hash of the rendered pixels: stays the same across exports as long as the slide looks the same.
    private static func contentKey(_ page: PDFPage) -> String {
        guard let img = render(page, width: 480), let data = img.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return "" }
        let digest = SHA256.hash(data: UnsafeRawBufferPointer(start: ptr, count: CFDataGetLength(data)))
        return digest.prefix(9).map { String(format: "%02x", $0) }.joined()
    }
}
