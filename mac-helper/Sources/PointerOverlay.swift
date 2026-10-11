import AppKit

/// A transparent, click-through window on top of the slide show that draws the laser pointer and pen ink
/// sent from the remote. Coordinates from the remote are normalised to the slide (0…1, top-left origin).
final class PointerOverlay {
    struct Stroke {
        var color: NSColor
        var points: [CGPoint]
    }

    private var window: NSWindow?
    private let view = OverlayView()
    private var strokesBySlide: [Int: [Stroke]] = [:]
    private var slide = 0
    private var laserTimer: Timer?
    private(set) var hasInkOnSlide = false

    /// Width / height of the slides (from the exported PDF).
    var slideAspect: CGFloat = 16.0 / 9.0 {
        didSet { view.slideAspect = slideAspect; view.needsDisplay = true }
    }

    /// Called whenever the state is polled.
    func update(showing: Bool, black: Bool, bounds: CGRect, slide newSlide: Int) {
        guard showing, bounds.width > 10, bounds.height > 10 else {
            if window != nil { hide() }
            if !showing { strokesBySlide.removeAll() }
            refreshInkFlag()
            return
        }
        if newSlide != slide {
            slide = newSlide
            view.laser = nil
            view.current = nil
            view.strokes = strokesBySlide[slide] ?? []
            view.needsDisplay = true
        }
        let win = window ?? makeWindow()
        let frame = Self.cocoaFrame(fromTopLeft: bounds)
        if win.frame != frame { win.setFrame(frame, display: true) }
        view.isHidden = black
        if !win.isVisible { win.orderFrontRegardless() }
        refreshInkFlag()
    }

    func laser(_ p: CGPoint?) {
        laserTimer?.invalidate()
        view.laser = p
        view.needsDisplay = true
        // Hide the dot if the remote stops sending (e.g. the finger left the screen and "off" got lost).
        laserTimer = Timer.scheduledTimer(withTimeInterval: p == nil ? 0 : 2.5, repeats: false) { [weak self] _ in
            self?.view.laser = nil
            self?.view.needsDisplay = true
        }
    }

    func penDown(color: NSColor, at p: CGPoint) {
        view.current = Stroke(color: color, points: [p])
        view.needsDisplay = true
    }

    func penMove(_ pts: [CGPoint]) {
        guard view.current != nil else { return }
        view.current!.points.append(contentsOf: pts)
        view.needsDisplay = true
    }

    func penUp() {
        if let s = view.current, s.points.count > 0 {
            strokesBySlide[slide, default: []].append(s)
            view.strokes = strokesBySlide[slide] ?? []
        }
        view.current = nil
        view.needsDisplay = true
        refreshInkFlag()
    }

    func clearInk() {
        strokesBySlide[slide] = nil
        view.strokes = []
        view.current = nil
        view.needsDisplay = true
        refreshInkFlag()
    }

    private func refreshInkFlag() {
        hasInkOnSlide = !(strokesBySlide[slide] ?? []).isEmpty
    }

    private func hide() {
        window?.orderOut(nil)
        view.laser = nil
        view.current = nil
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.level = .screenSaver
        // Needed to appear over PowerPoint's full-screen slide show.
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.isReleasedWhenClosed = false
        win.contentView = view
        view.slideAspect = slideAspect
        window = win
        return win
    }

    /// AppleScript window bounds use a top-left origin on the primary screen; Cocoa uses bottom-left.
    private static func cocoaFrame(fromTopLeft r: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? r.height
        return NSRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }
}

final class OverlayView: NSView {
    var slideAspect: CGFloat = 16.0 / 9.0
    var strokes: [PointerOverlay.Stroke] = []
    var current: PointerOverlay.Stroke?
    var laser: CGPoint?

    override var isFlipped: Bool { true }

    /// The slide's area inside the (letterboxed) slide show window.
    private var slideRect: CGRect {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return b }
        if b.width / b.height > slideAspect {
            let w = b.height * slideAspect
            return CGRect(x: (b.width - w) / 2, y: 0, width: w, height: b.height)
        }
        let h = b.width / slideAspect
        return CGRect(x: 0, y: (b.height - h) / 2, width: b.width, height: h)
    }

    private func point(_ p: CGPoint) -> CGPoint {
        let r = slideRect
        return CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = slideRect
        let lineWidth = max(3, r.height * 0.007)
        for s in strokes + (current.map { [$0] } ?? []) {
            draw(stroke: s, width: lineWidth)
        }
        if let l = laser {
            let c = point(l)
            let size = max(14, r.height * 0.016)
            NSColor(calibratedRed: 1, green: 0.1, blue: 0.1, alpha: 0.25).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - size * 1.4, y: c.y - size * 1.4, width: size * 2.8, height: size * 2.8)).fill()
            NSColor(calibratedRed: 1, green: 0.15, blue: 0.1, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)).fill()
        }
    }

    private func draw(stroke s: PointerOverlay.Stroke, width: CGFloat) {
        guard let first = s.points.first else { return }
        s.color.setStroke()
        s.color.setFill()
        if s.points.count == 1 {
            let c = point(first)
            NSBezierPath(ovalIn: CGRect(x: c.x - width / 2, y: c.y - width / 2, width: width, height: width)).fill()
            return
        }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // Smooth the line by curving through the midpoints between samples.
        var prev = point(first)
        path.move(to: prev)
        for p in s.points.dropFirst() {
            let cur = point(p)
            let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
            path.curve(to: mid, controlPoint1: prev, controlPoint2: prev)
            prev = cur
        }
        path.line(to: prev)
        path.stroke()
    }
}

extension NSColor {
    /// "#rrggbb" → colour (red when invalid).
    static func fromHex(_ hex: String) -> NSColor {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return .systemRed }
        return NSColor(calibratedRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
