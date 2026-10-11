import AppKit
import PDFKit

/// Renders slide images from the PDF that PowerPoint exported, and caches them as JPEG.
final class SlideImages {
    private var document: PDFDocument?
    /// slide index (1-based) -> PDF page index (0-based)
    private var pageForSlide: [Int: Int] = [:]
    private var cache: [String: Data] = [:]

    var isLoaded: Bool { document != nil }

    func load(pdfPath: String?, hidden: [Bool]) {
        cache.removeAll()
        pageForSlide.removeAll()
        document = nil
        guard let path = pdfPath else { return }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            Log.write("Could not open exported PDF at \(path)")
            return
        }
        // Hidden slides are usually left out of PDF exports; map pages around them when that happens.
        let visible = hidden.enumerated().filter { !$0.element }.map { $0.offset + 1 }
        if doc.pageCount == hidden.count || hidden.isEmpty {
            for i in 0..<doc.pageCount { pageForSlide[i + 1] = i }
        } else if doc.pageCount == visible.count {
            for (page, slide) in visible.enumerated() { pageForSlide[slide] = page }
        } else {
            for i in 0..<min(doc.pageCount, hidden.count) { pageForSlide[i + 1] = i }
        }
        document = doc
        Log.write("Loaded PDF with \(doc.pageCount) pages for \(hidden.count) slides")
    }

    /// Returns JPEG data for a slide, rendered to fit `width` pixels wide.
    func jpeg(slide: Int, width: Int, quality: Double) -> Data? {
        let key = "\(slide)-\(width)-\(quality)"
        if let d = cache[key] { return d }
        guard let doc = document, let pageIndex = pageForSlide[slide], let page = doc.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let w = max(64, min(width, 2400))
        let h = Int((Double(w) * Double(bounds.height) / Double(bounds.width)).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = ctx.cgContext
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        cg.interpolationQuality = .high
        cg.scaleBy(x: CGFloat(w) / bounds.width, y: CGFloat(h) / bounds.height)
        cg.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: cg)
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        if let data { cache[key] = data }
        return data
    }
}
