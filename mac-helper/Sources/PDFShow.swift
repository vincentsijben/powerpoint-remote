import AppKit
import PDFKit

/// The calls the Hub needs from a presentation app (PowerPoint, Keynote, or the built-in PDF presenter).
protocol SlideApp: AnyObject {
    /// "powerpoint", "keynote" or "pdf".
    var kind: String { get }
    var isRunning: Bool { get }
    func pollState(selection: String, withList: Bool, _ completion: @escaping (PPTState?) -> Void)
    func loadDeck(selection: String, _ completion: @escaping (DeckLoad?) -> Void)
    func notes(selection: String, for index: Int, _ completion: @escaping (String?) -> Void)
    func richNotes(selection: String, for index: Int, _ completion: @escaping ([RichParagraph]?) -> Void)
    func mediaList(selection: String, _ completion: @escaping ([MediaItem]) -> Void)
    func media(selection: String, _ cmd: String, shape: Int, value: Int, _ completion: @escaping (MediaStatus?) -> Void)
    func navigate(selection: String, _ cmd: String, target: Int, _ completion: @escaping (PPTState?) -> Void)
}

extension PowerPoint: SlideApp {
    var kind: String { "powerpoint" }
}

/// Presents a PDF full screen (on the projector when one is connected), so slides from Canva, Google Slides,
/// Keynote exports or LaTeX work with the remote too. Sticky notes (comments) on a page are its speaker notes.
final class PDFShow: SlideApp {
    let kind = "pdf"
    private(set) var url: URL?
    private var doc: PDFDocument?
    private var pageNotes: [String] = []
    private var index = 1
    private var showing = false
    private var black = false
    private var window: NSWindow?
    private let view = PDFSlideView()
    /// Called when something changed here (keyboard / clicker on the Mac), so the remotes update quickly.
    var onChange: (() -> Void)?

    static let prefix = "pdf:"
    var isRunning: Bool { doc != nil }
    var fullName: String { url.map { Self.prefix + $0.path } ?? "" }

    // MARK: - Opening

    static var recents: [String] {
        get { (UserDefaults.standard.stringArray(forKey: "recentPDFs") ?? []).filter { FileManager.default.fileExists(atPath: $0) } }
        set { UserDefaults.standard.set(Array(newValue.prefix(8)), forKey: "recentPDFs") }
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let d = PDFDocument(url: url), d.pageCount > 0 else {
            Log.write("Could not open PDF: \(url.path)")
            return false
        }
        if showing { endShow() }
        // Sticky notes are the speaker notes: don't draw their icons on the slides.
        for i in 0..<d.pageCount { d.page(at: i)?.displaysAnnotations = false }
        doc = d
        self.url = url
        index = 1
        black = false
        pageNotes = (0..<d.pageCount).map { i in
            guard let page = d.page(at: i) else { return "" }
            return page.annotations
                .filter { ["Text", "FreeText", "Popup"].contains($0.type ?? "") }
                .compactMap { $0.contents?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        var r = Self.recents.filter { $0 != url.path }
        r.insert(url.path, at: 0)
        Self.recents = r
        Log.write("PDF opened: \(url.lastPathComponent), \(d.pageCount) pages, notes on \(pageNotes.filter { !$0.isEmpty }.count)")
        return true
    }

    func close() {
        if showing { endShow() }
        doc = nil
        url = nil
        pageNotes = []
    }

    // MARK: - SlideApp

    func pollState(selection: String, withList: Bool, _ completion: @escaping (PPTState?) -> Void) {
        DispatchQueue.main.async { completion(self.state()) }
    }

    func state() -> PPTState {
        var st = PPTState(running: doc != nil)
        guard let doc, let url else { return st }
        st.hasPresentation = true
        st.fullName = fullName
        st.count = doc.pageCount
        st.index = index
        st.showing = showing
        st.black = black
        if showing, let f = window?.frame {
            // AppleScript-style coordinates: top-left origin of the main screen.
            let primary = NSScreen.screens.first?.frame.height ?? f.height
            st.showBounds = CGRect(x: f.minX, y: primary - f.maxY, width: f.width, height: f.height)
        }
        st.open = [OpenPresentation(name: url.lastPathComponent, fullName: fullName)]
        return st
    }

    func loadDeck(selection: String, _ completion: @escaping (DeckLoad?) -> Void) {
        guard let doc, let url else { return completion(nil) }
        let load = DeckLoad(fullName: fullName, hidden: [Bool](repeating: false, count: doc.pageCount), notes: pageNotes,
                            sections: [], pdfPath: url.path)
        DispatchQueue.main.async { completion(load) }
    }

    func notes(selection: String, for index: Int, _ completion: @escaping (String?) -> Void) {
        completion(index >= 1 && index <= pageNotes.count ? pageNotes[index - 1] : nil)
    }

    func richNotes(selection: String, for index: Int, _ completion: @escaping ([RichParagraph]?) -> Void) { completion(nil) }
    func mediaList(selection: String, _ completion: @escaping ([MediaItem]) -> Void) { completion([]) }
    func media(selection: String, _ cmd: String, shape: Int, value: Int, _ completion: @escaping (MediaStatus?) -> Void) { completion(nil) }

    func navigate(selection: String, _ cmd: String, target: Int, _ completion: @escaping (PPTState?) -> Void) {
        go(cmd, target: target)
        completion(state())
    }

    // MARK: - Showing

    func go(_ cmd: String, target: Int = 0) {
        guard let doc else { return }
        let n = doc.pageCount
        switch cmd {
        case "next": if showing && black { black = false } else { index = min(n, index + 1) }
        case "prev": if showing && black { black = false } else { index = max(1, index - 1) }
        case "first": index = 1
        case "last": index = n
        case "goto": index = min(n, max(1, target))
        case "start":
            index = 1
            startShow()
        case "starthere": startShow()
        case "end": endShow()
        case "black": if showing { black.toggle() }
        default: return
        }
        render()
    }

    private func startShow() {
        let win = window ?? makeWindow()
        // On the projector when there is one (like PowerPoint), otherwise on the Mac's own screen.
        let screen = NSScreen.screens.count > 1 ? NSScreen.screens[1] : NSScreen.screens.first
        if let screen { win.setFrame(screen.frame, display: true) }
        showing = true
        black = false
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKey()
        NSCursor.setHiddenUntilMouseMoves(true)
        Log.write("PDF show started on \(screen?.localizedName ?? "screen")")
    }

    private func endShow() {
        showing = false
        black = false
        window?.orderOut(nil)
        Log.write("PDF show ended")
    }

    private func render() {
        view.page = doc?.page(at: index - 1)
        view.black = black
        view.needsDisplay = true
    }

    private func makeWindow() -> NSWindow {
        let win = KeyWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .statusBar // above the menu bar and Dock; the drawing overlay is above this
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = view
        view.onKey = { [weak self] key in
            guard let self else { return }
            switch key {
            case "next", "prev", "end", "black", "first", "last": self.go(key)
            default: break
            }
            self.onChange?()
        }
        window = win
        render()
        return win
    }
}

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Draws one PDF page as large as fits, centred on black (sharp at any size: it's drawn as vectors).
final class PDFSlideView: NSView {
    var page: PDFPage?
    var black = false
    var onKey: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard !black, let page, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = page.bounds(for: .mediaBox)
        guard b.width > 0, b.height > 0 else { return }
        let scale = min(bounds.width / b.width, bounds.height / b.height)
        let w = b.width * scale, h = b.height * scale
        let r = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        ctx.setFillColor(.white)
        ctx.fill(r)
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        ctx.interpolationQuality = .high
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
    }

    /// Keyboard and presentation clickers (they send arrow / page keys).
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 124, 125, 121, 49, 36, 76: onKey?("next")  // → ↓ PageDown Space Return Enter
        case 123, 126, 116, 51: onKey?("prev")          // ← ↑ PageUp Backspace
        case 115: onKey?("first")                       // Home
        case 119: onKey?("last")                        // End
        case 53: onKey?("end")                          // Esc
        default:
            if let c = event.charactersIgnoringModifiers?.lowercased(), c == "b" || c == "." { onKey?("black") } else { super.keyDown(with: event) }
        }
    }
}
