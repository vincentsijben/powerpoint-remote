import AppKit

/// A transparent, click-through window on top of the slide show that draws the laser pointer, pen ink,
/// shapes and the whiteboard sent from the remote. Coordinates are normalised to the slide (0…1, top-left origin).
final class PointerOverlay {
    struct Stroke {
        /// pen (freehand) | line | arrow | ellipse | rect
        var kind = "pen"
        var color: NSColor
        var points: [CGPoint]
    }

    /// Page used for the whiteboard's drawings.
    private static let whiteboardPage = -1

    private var window: NSWindow?
    private let view = OverlayView()
    private let zoomView = ZoomView(frame: .zero)
    private let capture = LiveZoomCapture()
    private var showFrame: CGRect = .zero
    /// Zoom wanted by the remote (centre of the visible part, 0…1, and magnification) and the one shown now.
    private var zoomTarget: (c: CGPoint, s: CGFloat)?
    private var zoomNow: (c: CGPoint, s: CGFloat) = (CGPoint(x: 0.5, y: 0.5), 1)
    private var zoomTimer: Timer?
    private(set) var zoomed = false
    private var strokesBySlide: [Int: [Stroke]] = [:]
    private var slide = 0
    private var laserTimer: Timer?
    private(set) var hasInkOnSlide = false
    private(set) var whiteboard = false
    private var page: Int { whiteboard ? Self.whiteboardPage : slide }

    /// Width / height of the slides (from the exported PDF).
    var slideAspect: CGFloat = 16.0 / 9.0 {
        didSet { view.slideAspect = slideAspect; view.needsDisplay = true }
    }

    /// Called whenever the state is polled.
    /// Called when a slide show with drawings ends, with all its drawings (page -1 = whiteboard).
    var onShowEnded: (([Int: [Stroke]]) -> Void)?

    /// All drawings of this slide show, including the line being drawn.
    func inkPages() -> [Int: [Stroke]] {
        var all = strokesBySlide
        if let c = view.current, !c.points.isEmpty { all[page, default: []].append(c) }
        return all.filter { !$0.value.isEmpty }
    }

    var hasAnyInk: Bool { !inkPages().isEmpty }

    func update(showing: Bool, black: Bool, bounds: CGRect, slide newSlide: Int) {
        guard showing, bounds.width > 10, bounds.height > 10 else {
            if !showing {
                let ink = inkPages()
                if !ink.isEmpty { onShowEnded?(ink) }
            }
            if window != nil { hide() }
            if !showing {
                strokesBySlide.removeAll()
                whiteboard = false
                view.whiteboard = false
            }
            refreshInkFlag()
            return
        }
        if newSlide != slide {
            slide = newSlide
            resetZoom()
            view.spot = nil
            view.needsDisplay = true
            if !whiteboard {
                view.laser = nil
                view.current = nil
                view.strokes = strokesBySlide[page] ?? []
                view.needsDisplay = true
            }
        }
        let win = window ?? makeWindow()
        let frame = Self.cocoaFrame(fromTopLeft: bounds)
        showFrame = bounds
        if win.frame != frame {
            win.setFrame(frame, display: true)
            if capture.isRunning { capture.start(frame: bounds) }
            layoutZoom()
        }
        view.isHidden = black && !whiteboard
        zoomView.isHidden = black || whiteboard
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

    /// Darkens everything except a circle around `p` (radius as a fraction of the slide height); nil = off.
    func spotlight(_ p: CGPoint?, radius: CGFloat) {
        view.spot = p
        view.spotRadius = radius
        view.needsDisplay = true
    }

    // MARK: - Live zoom

    /// Starts the screen capture ahead of time so the first zoom is instant.
    func prepareZoom() {
        guard LiveZoomCapture.hasPermission, window?.isVisible == true, showFrame.width > 10 else { return }
        capture.start(frame: showFrame)
    }

    /// Magnifies the slide on the projector: `center` of the visible part (0…1) and `scale` (1 = whole slide).
    func zoom(center: CGPoint, scale: CGFloat) {
        guard !whiteboard, window?.isVisible == true else { return }
        guard LiveZoomCapture.hasPermission else {
            Log.write("Live zoom needs the Screen Recording permission")
            LiveZoomCapture.requestPermission(openSettings: false)
            return
        }
        let s = min(8, max(1, scale))
        zoomTarget = (Self.clampCenter(center, scale: s), s)
        capture.start(frame: showFrame)
        if zoomView.hasFrame { animateZoom() }
    }

    func zoomOff() {
        guard zoomTarget != nil || zoomed else { return }
        zoomTarget = (CGPoint(x: 0.5, y: 0.5), 1)
        animateZoom()
        capture.stopSoon()
    }

    private func resetZoom() {
        zoomTimer?.invalidate()
        zoomTimer = nil
        zoomTarget = nil
        zoomNow = (CGPoint(x: 0.5, y: 0.5), 1)
        zoomed = false
        zoomView.clear()
        view.region = CGRect(x: 0, y: 0, width: 1, height: 1)
        view.needsDisplay = true
        if capture.isRunning { capture.stopSoon() }
    }

    private static func clampCenter(_ c: CGPoint, scale s: CGFloat) -> CGPoint {
        let half = 0.5 / s
        return CGPoint(x: min(1 - half, max(half, c.x)), y: min(1 - half, max(half, c.y)))
    }

    private static func region(_ z: (c: CGPoint, s: CGFloat)) -> CGRect {
        let w = 1 / z.s
        return CGRect(x: z.c.x - w / 2, y: z.c.y - w / 2, width: w, height: w)
    }

    /// Glides towards the wanted zoom (also smooths the stream of updates during a pinch).
    private func animateZoom() {
        guard zoomTimer == nil else { return }
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self, let target = self.zoomTarget else { t.invalidate(); self?.zoomTimer = nil; return }
            let k: CGFloat = 0.3
            var now = self.zoomNow
            // Interpolate the scale logarithmically so zooming feels even.
            now.s = exp(log(now.s) + (log(target.s) - log(now.s)) * k)
            now.c = CGPoint(x: now.c.x + (target.c.x - now.c.x) * k, y: now.c.y + (target.c.y - now.c.y) * k)
            let done = abs(now.s - target.s) < 0.002 && abs(now.c.x - target.c.x) < 0.0005 && abs(now.c.y - target.c.y) < 0.0005
            if done { now = target }
            now.c = Self.clampCenter(now.c, scale: now.s)
            self.zoomNow = now
            self.layoutZoom()
            if done {
                t.invalidate()
                self.zoomTimer = nil
                if target.s <= 1.0001 { self.zoomTarget = nil }
            }
        }
    }

    private func layoutZoom() {
        let active = zoomNow.s > 1.0001
        zoomed = active
        let region = active ? Self.region(zoomNow) : CGRect(x: 0, y: 0, width: 1, height: 1)
        view.region = region
        zoomView.layout(slide: view.slideRect, region: active ? region : nil)
        view.needsDisplay = true
    }

    /// Keeps an unfinished stroke (e.g. a quick dot whose "pen up" hasn't arrived) instead of dropping it.
    private func commitCurrent() {
        if let s = view.current, s.points.count > 0 {
            strokesBySlide[page, default: []].append(s)
            view.strokes = strokesBySlide[page] ?? []
        }
    }

    func penDown(color: NSColor, at p: CGPoint) {
        commitCurrent()
        view.current = Stroke(color: color, points: [p])
        view.needsDisplay = true
    }

    func penMove(_ pts: [CGPoint]) {
        guard view.current != nil else { return }
        view.current!.points.append(contentsOf: pts)
        view.needsDisplay = true
    }

    /// Straight line, arrow, ellipse or rectangle from the first point to the moving end point.
    func shapeDown(kind: String, color: NSColor, at p: CGPoint) {
        commitCurrent()
        view.current = Stroke(kind: kind, color: color, points: [p, p])
        view.needsDisplay = true
    }

    func shapeMove(_ p: CGPoint) {
        guard view.current != nil, view.current!.kind != "pen" else { return }
        view.current!.points = [view.current!.points[0], p]
        view.needsDisplay = true
    }

    func setWhiteboard(_ on: Bool) {
        guard on != whiteboard else { return }
        whiteboard = on
        view.whiteboard = on
        if on { resetZoom() }
        zoomView.isHidden = on
        view.current = nil
        view.laser = nil
        view.strokes = strokesBySlide[page] ?? []
        view.isHidden = false
        view.needsDisplay = true
        refreshInkFlag()
    }

    func penUp() {
        commitCurrent()
        view.current = nil
        view.needsDisplay = true
        refreshInkFlag()
    }

    func clearInk() {
        strokesBySlide[page] = nil
        view.strokes = []
        view.current = nil
        view.needsDisplay = true
        refreshInkFlag()
    }

    private func refreshInkFlag() {
        hasInkOnSlide = !(strokesBySlide[page] ?? []).isEmpty
    }

    private func hide() {
        resetZoom()
        capture.stopNow()
        window?.orderOut(nil)
        view.laser = nil
        view.spot = nil
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
        let container = NSView(frame: .zero)
        zoomView.autoresizingMask = [.width, .height]
        view.autoresizingMask = [.width, .height]
        container.addSubview(zoomView)
        container.addSubview(view)
        win.contentView = container
        view.slideAspect = slideAspect
        capture.onFrame = { [weak self] surface in
            guard let self else { return }
            let first = !self.zoomView.hasFrame
            self.zoomView.show(frame: surface)
            if first { self.animateZoom() }
        }
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
    var whiteboard = false
    var spot: CGPoint?
    var spotRadius: CGFloat = 0.16
    /// Part of the slide shown when zoomed in (0…1); the whole slide normally.
    var region = CGRect(x: 0, y: 0, width: 1, height: 1)

    override var isFlipped: Bool { true }

    /// The slide's area inside the (letterboxed) slide show window.
    var slideRect: CGRect {
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
        let g = region
        return CGPoint(x: r.minX + (p.x - g.minX) / g.width * r.width, y: r.minY + (p.y - g.minY) / g.height * r.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = slideRect
        if whiteboard {
            NSColor.white.setFill()
            bounds.fill()
        }
        let mag = 1 / region.width
        let lineWidth = max(3, r.height * 0.007) * mag
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        // Zoomed in: drawings outside the visible part must not spill into the letterbox bars.
        if mag > 1 { ctx?.clip(to: r) }
        for s in strokes + (current.map { [$0] } ?? []) {
            draw(stroke: s, width: lineWidth)
        }
        ctx?.restoreGState()
        if let sp = spot { drawSpotlight(at: point(sp), radius: spotRadius * r.height * mag) }
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
        InkPainter.draw(s, width: width, minHead: 14, point: point)
    }

    /// Dark veil over the whole screen with a soft-edged hole: a "spyglass" on one part of the slide.
    private func drawSpotlight(at c: CGPoint, radius: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let shade = CGColor(gray: 0, alpha: 0.72)
        let outer = radius * 1.08
        let veil = CGMutablePath()
        veil.addRect(bounds)
        veil.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        ctx.addPath(veil)
        ctx.setFillColor(shade)
        ctx.fillPath(using: .evenOdd)
        // Soft edge: fade from clear to the veil colour around the rim.
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                    colors: [CGColor(gray: 0, alpha: 0), shade] as CFArray, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        ctx.clip()
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: radius * 0.92, endCenter: c, endRadius: outer, options: [])
        ctx.restoreGState()
    }
}

/// Draws pen strokes and shapes; used for the projector overlay and for the PDF with your drawings.
/// Needs a current NSGraphicsContext. `point` maps slide coordinates (0…1, top-left origin) to the context.
enum InkPainter {
    static func draw(_ s: PointerOverlay.Stroke, width: CGFloat, minHead: CGFloat, point: (CGPoint) -> CGPoint) {
        guard let first = s.points.first else { return }
        s.color.setStroke()
        s.color.setFill()
        if s.kind != "pen", s.points.count >= 2 {
            drawShape(s, width: width, minHead: minHead, point: point)
            return
        }
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

    private static func drawShape(_ s: PointerOverlay.Stroke, width: CGFloat, minHead: CGFloat, point: (CGPoint) -> CGPoint) {
        let a = point(s.points[0])
        let b = point(s.points[1])
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch s.kind {
        case "ellipse":
            path.appendOval(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case "rect":
            path.appendRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        default: // line, arrow
            path.move(to: a)
            path.line(to: b)
            if s.kind == "arrow", hypot(b.x - a.x, b.y - a.y) > 1 {
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = max(width * 4, minHead)
                for side in [-1.0, 1.0] {
                    let ang = angle + .pi - side * .pi / 7
                    path.move(to: b)
                    path.line(to: CGPoint(x: b.x + head * cos(ang), y: b.y + head * sin(ang)))
                }
            }
        }
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
