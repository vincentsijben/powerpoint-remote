import AppKit
import CoreMedia
import ScreenCaptureKit

/// Live picture of the slide show window (everything on screen there except our own overlay), used to
/// magnify part of the slide on the projector. Needs the Screen Recording permission.
final class LiveZoomCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the main thread with every new frame.
    var onFrame: ((IOSurface) -> Void)?
    /// Our overlay window (laser, ink…): left out, otherwise it would be magnified twice.
    var overlayWindowID: CGWindowID = 0

    private var stream: SCStream?
    private var streamFrame: CGRect = .zero
    private var starting = false
    private var stopTimer: Timer?
    private let queue = DispatchQueue(label: "pptremote.zoom.capture")

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (only the first time) and opens the right page in System Settings.
    static func requestPermission(openSettings: Bool) {
        if !CGRequestScreenCaptureAccess(), openSettings,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    var isRunning: Bool { stream != nil }

    /// Starts (or keeps) capturing the area `frame` (top-left origin, global screen coordinates).
    func start(frame: CGRect) {
        stopTimer?.invalidate()
        stopTimer = nil
        if starting || (stream != nil && streamFrame == frame) { return }
        if stream != nil { stopNow() }
        starting = true
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.starting = false }
                guard let content else {
                    Log.write("Live zoom unavailable: \(error?.localizedDescription ?? "no screen access")")
                    return
                }
                self.begin(content: content, frame: frame)
            }
        }
    }

    private func begin(content: SCShareableContent, frame: CGRect) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
            Log.write("Live zoom: no display found")
            return
        }
        // Leave out our own overlay (laser, ink…), otherwise it would be magnified twice.
        // Only our overlay is left out: the PDF presenter's window (also ours) must be in the picture.
        let overlay = content.windows.filter { $0.windowID == overlayWindowID }
        let filter = SCContentFilter(display: display, excludingWindows: overlay)
        let scale = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID })?.backingScaleFactor ?? 2
        let local = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            .intersection(CGRect(origin: .zero, size: display.frame.size))
        guard local.width > 10, local.height > 10 else { return }
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int(local.width * scale)
        config.height = Int(local.height * scale)
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            Log.write("Live zoom: \(error.localizedDescription)")
            return
        }
        stream = s
        streamFrame = frame
        s.startCapture { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                Log.write("Live zoom could not start: \(error.localizedDescription)")
                if self?.stream === s { self?.stream = nil }
            }
        }
        Log.write("Live zoom: capturing \(Int(config.width))×\(Int(config.height))")
    }

    /// Stops after a while, so zooming in again soon is instant (and the menu-bar recording icon goes away later).
    func stopSoon(after seconds: TimeInterval = 20) {
        guard stream != nil else { return }
        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.stopNow() }
    }

    func stopNow() {
        stopTimer?.invalidate()
        stopTimer = nil
        guard let s = stream else { return }
        stream = nil
        streamFrame = .zero
        s.stopCapture { _ in }
        Log.write("Live zoom: capture stopped")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.onFrame?(surface)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            Log.write("Live zoom stopped: \(error.localizedDescription)")
            if self.stream === stream {
                self.stream = nil
                self.streamFrame = .zero
            }
        }
    }
}

/// Shows the magnified live picture under the overlay's drawings.
final class ZoomView: NSView {
    private let clip = CALayer()
    private let image = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clip.masksToBounds = true
        clip.backgroundColor = NSColor.black.cgColor
        image.contentsGravity = .resize
        image.magnificationFilter = .trilinear
        clip.addSublayer(image)
        layer?.addSublayer(clip)
        clip.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    var hasFrame: Bool { image.contents != nil }

    func show(frame surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = surface
        CATransaction.commit()
    }

    /// `slide`: the slide's area in this view (top-left origin); `region`: visible part of the slide (0…1).
    func layout(slide: CGRect, region: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let region, hasFrame, region.width < 0.999 else {
            clip.isHidden = true
            return
        }
        let h = bounds.height
        // This layer tree uses a bottom-left origin.
        let slideBL = CGRect(x: slide.minX, y: h - slide.maxY, width: slide.width, height: slide.height)
        clip.frame = slideBL
        // The captured picture covers the whole view; the visible region must fill the slide area.
        let visTL = CGRect(x: slide.minX + region.minX * slide.width, y: slide.minY + region.minY * slide.height,
                           width: region.width * slide.width, height: region.height * slide.height)
        let k = slide.width / visTL.width
        let visBL = CGRect(x: visTL.minX, y: h - visTL.maxY, width: visTL.width, height: visTL.height)
        image.frame = CGRect(x: -visBL.minX * k + 0, y: -visBL.minY * k, width: bounds.width * k, height: bounds.height * k)
        clip.isHidden = false
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = nil
        clip.isHidden = true
        CATransaction.commit()
    }
}
