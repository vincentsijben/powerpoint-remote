import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Records a lecture into one MP4: the projector screen (including the laser, ink and zoom overlay),
/// all sound the Mac plays (soundboard, videos in the slides…) and the MacBook microphone.
///
/// While recording, video and the two audio sources are written to separate files; on stop they are
/// mixed (the microphone is turned down while the Mac itself plays sound, to avoid hearing it twice)
/// and combined without re-encoding the video, so saving takes seconds rather than minutes.
final class LectureRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Phase: String { case off, starting, rec, paused, saving }

    private(set) var phase: Phase = .off
    private(set) var lastFile: URL?
    private(set) var lastError: String?
    private(set) var savingProgress: Double = 0
    private(set) var micOn = false
    private(set) var displayName = ""
    /// Called on the main thread whenever something the remotes show changes.
    var onChange: (() -> Void)?

    /// Screen to record: "auto" (follows PowerPoint) or a display ID.
    static var screenChoice: String {
        get { UserDefaults.standard.string(forKey: "recordScreen") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "recordScreen") }
    }

    private(set) var displayID: CGDirectDisplayID = 0
    /// The microphone of the iPad / phone (sent over Bluetooth).
    let remote = RemoteMicStore()
    private(set) var recID: UInt32 = 0
    private(set) var waitingRemote = false
    private var saveNow = false
    private var showBounds: CGRect?
    private var switching = false

    static var folder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "recordingsFolder") { return URL(fileURLWithPath: p) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/PPT Remote")
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "recordingsFolder") }
    }

    // Main thread: time recorded so far.
    private var recordedBefore: TimeInterval = 0
    private var segmentStart: Date?
    var elapsed: TimeInterval { recordedBefore + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0) }

    // Capture queue only.
    private let queue = DispatchQueue(label: "pptremote.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudio: AudioTrackFile?
    private var micAudio: AudioTrackFile?
    private var capturing = false
    private var paused = false
    private var startHost: CMTime?
    private var pausedTotal = CMTime.zero
    private var pausedAt: CMTime?
    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime = CMTime.invalid
    private var repeatTimer: DispatchSourceTimer?
    private var workDir: URL?
    private var title = ""
    private var startedAt = Date()

    // MARK: - Control (main thread)

    func start(showBounds: CGRect?, title: String) {
        guard phase == .off else { return }
        guard LiveZoomCapture.hasPermission else {
            fail("Recording needs the Screen Recording permission on the Mac")
            LiveZoomCapture.requestPermission(openSettings: true)
            return
        }
        lastError = nil
        phase = .starting
        self.title = title
        onChange?()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { self.findDisplay(showBounds: showBounds, mic: ok) }
            }
        case .authorized:
            findDisplay(showBounds: showBounds, mic: true)
        default:
            Log.write("Recording without the microphone (no permission)")
            findDisplay(showBounds: showBounds, mic: false)
        }
    }

    func pause() {
        guard phase == .rec else { return }
        phase = .paused
        recordedBefore = elapsed
        segmentStart = nil
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async {
            self.paused = true
            self.pausedAt = now
        }
        Log.write("Recording paused at \(Self.clock(recordedBefore))")
        onChange?()
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .rec
        segmentStart = Date()
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async {
            if let at = self.pausedAt { self.pausedTotal = self.pausedTotal + (now - at) }
            self.pausedAt = nil
            self.paused = false
        }
        Log.write("Recording resumed")
        onChange?()
    }

    /// Stops and saves; `done` is called on the main thread when the file is ready (or saving failed).
    func stop(done: (() -> Void)? = nil) {
        guard phase == .rec || phase == .paused || phase == .starting else { done?(); return }
        recordedBefore = elapsed
        segmentStart = nil
        phase = .saving
        savingProgress = 0
        onChange?()
        Log.write("Recording stopped after \(Self.clock(recordedBefore)); saving…")
        let s = stream
        stream = nil
        let finish = { self.queue.async { self.finishWriting(done: done) } }
        if let s {
            s.stopCapture { _ in finish() }
        } else {
            finish()
        }
    }

    func stateObject() -> [String: Any] {
        var o: [String: Any] = ["st": phase.rawValue, "t": Int(elapsed.rounded(.down)), "mic": micOn]
        if phase == .saving { o["p"] = Int(savingProgress * 100) }
        if phase != .off { o["id"] = recID }
        if waitingRemote {
            o["rw"] = true
            o["rp"] = remote.expectedBytes > 0 ? Int(Double(remote.receivedBytes) / Double(remote.expectedBytes) * 100) : 0
        }
        if remote.hasAudio, phase != .off { o["rmic"] = true }
        if let f = lastFile { o["file"] = f.lastPathComponent }
        if let e = lastError { o["err"] = e }
        if !displayName.isEmpty, phase != .off { o["disp"] = displayName }
        o["screen"] = Self.screenChoice
        o["screens"] = NSScreen.screens.compactMap { sc -> [String: Any]? in
            guard let id = sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return ["id": String(id), "name": sc.localizedName]
        }
        return o
    }

    var isActive: Bool { phase != .off }

    // MARK: - Starting

    private func findDisplay(showBounds: CGRect?, mic: Bool) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let content, !content.displays.isEmpty else {
                    self.fail("Can't record the screen: \(error?.localizedDescription ?? "no display")")
                    return
                }
                self.showBounds = showBounds
                let id = self.wantedDisplay(among: content.displays.map(\.displayID))
                let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays[0]
                self.begin(display: display, mic: mic)
            }
        }
    }

    /// The screen to record. Automatic: where the slide show runs, otherwise where PowerPoint's window is,
    /// otherwise an external screen (projector), otherwise the Mac's own.
    private func wantedDisplay(among ids: [CGDirectDisplayID]) -> CGDirectDisplayID {
        if let id = UInt32(Self.screenChoice), ids.contains(id) { return id }
        if let b = showBounds, b.width > 10, let id = Self.display(at: CGPoint(x: b.midX, y: b.midY)), ids.contains(id) { return id }
        if let w = Self.powerPointWindow(), let id = Self.display(at: CGPoint(x: w.midX, y: w.midY)), ids.contains(id) { return id }
        if let ext = ids.first(where: { $0 != CGMainDisplayID() }) { return ext }
        return ids.contains(CGMainDisplayID()) ? CGMainDisplayID() : (ids.first ?? CGMainDisplayID())
    }

    private static func display(at p: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }

    /// Bounds (top-left origin) of PowerPoint's front-most window.
    private static func powerPointWindow() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Microsoft PowerPoint" && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let d = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d), r.width > 200, r.height > 150 { return r }
        }
        return nil
    }

    private static func screenName(_ id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }?.localizedName ?? "Display"
    }

    /// Picks the screen from the remote ("auto" or a display ID); switches right away while recording.
    func chooseScreen(_ choice: String) {
        Self.screenChoice = choice
        Log.write("Recording screen: \(choice == "auto" ? "automatic" : Self.screenName(UInt32(choice) ?? 0))")
        onChange?()
        retarget()
    }

    /// Called on every PowerPoint poll: in automatic mode the recording follows the slide show to its screen.
    func followShow(_ bounds: CGRect?) {
        let old = showBounds
        showBounds = bounds
        guard Self.screenChoice == "auto", bounds != nil, old != bounds else { return }
        retarget()
    }

    private func retarget() {
        guard phase == .rec || phase == .paused, stream != nil, !switching else { return }
        let ids = NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
        let want = wantedDisplay(among: ids)
        guard want != displayID else { return }
        switching = true
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            DispatchQueue.main.async {
                defer { self.switching = false }
                guard let stream = self.stream, let display = content?.displays.first(where: { $0.displayID == want }) else { return }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                stream.updateContentFilter(filter) { error in
                    DispatchQueue.main.async {
                        if let error {
                            Log.write("Could not switch the recorded screen: \(error.localizedDescription)")
                            return
                        }
                        self.displayID = want
                        self.displayName = Self.screenName(want)
                        Log.write("Recording now: \(self.displayName)")
                        self.onChange?()
                    }
                }
            }
        }
    }

    private func begin(display: SCDisplay, mic: Bool) {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }
        displayID = display.displayID
        displayName = screen?.localizedName ?? "Display"
        let scale = screen?.backingScaleFactor ?? 1
        let pw = CGFloat(display.width) * scale
        let ph = CGFloat(display.height) * scale
        // At most 1920×1200: sharp enough for slides and code, and the file stays small.
        let fit = min(1, 1920 / pw, 1200 / ph)
        let w = Int(pw * fit) / 2 * 2
        let h = Int(ph * fit) / 2 * 2

        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PPTRemote/recording-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let writer = try AVAssetWriter(outputURL: dir.appendingPathComponent("video.mov"), fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_500_000,
                    AVVideoExpectedSourceFrameRateKey: 15,
                    AVVideoMaxKeyFrameIntervalDurationKey: 4,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? NSError(domain: "PPTRemote", code: 1) }
            writer.startSession(atSourceTime: .zero)

            let config = SCStreamConfiguration()
            config.width = w
            config.height = h
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            config.queueDepth = 8
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            config.showsCursor = true
            if #available(macOS 14.0, *) {
                // Switching to a screen with another shape later: letterbox instead of stretching.
                config.preservesAspectRatio = true
            }
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false // the soundboard plays in this app
            config.sampleRate = 48000
            config.channelCount = 2
            var withMic = false
            if #available(macOS 15.0, *), mic {
                config.captureMicrophone = true
                withMic = true
            }
            // Nothing excluded: the overlay with laser, ink and zoom belongs in the video.
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            if #available(macOS 15.0, *), withMic {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            }
            micOn = withMic
            workDir = dir
            recID = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
            remote.reset(dir: dir, rec: recID)
            remote.mediaNow = { [weak self] in
                guard let self, self.phase == .rec else { return nil }
                return self.queue.sync { self.mediaNow()?.seconds }
            }
            remote.onChange = { [weak self] in self?.onChange?() }
            self.stream = stream
            let system = AudioTrackFile(url: dir.appendingPathComponent("system.m4a"), channels: 2, bitrate: 160_000)
            let micFile = withMic ? AudioTrackFile(url: dir.appendingPathComponent("mic.m4a"), channels: 1, bitrate: 96_000) : nil
            queue.sync {
                self.writer = writer
                self.videoInput = input
                self.adaptor = adaptor
                self.systemAudio = system
                self.micAudio = micFile
                self.startHost = nil
                self.pausedTotal = .zero
                self.pausedAt = nil
                self.paused = false
                self.lastFrame = nil
                self.lastFrameTime = .invalid
                self.capturing = true
            }
            stream.startCapture { error in
                DispatchQueue.main.async {
                    if let error {
                        self.queue.sync { self.capturing = false }
                        self.stream = nil
                        self.fail("Recording could not start: \(error.localizedDescription)")
                        return
                    }
                    self.startedAt = Date()
                    self.recordedBefore = 0
                    self.segmentStart = Date()
                    self.phase = .rec
                    self.startRepeatTimer()
                    Log.write("Recording \(self.displayName) at \(w)×\(h), Mac sound\(withMic ? " + microphone" : " (no microphone)")")
                    self.onChange?()
                }
            }
        } catch {
            fail("Recording could not start: \(error.localizedDescription)")
        }
    }

    /// While the screen doesn't change, macOS sends no new frames; repeat the last one now and then
    /// so the video can be scrubbed and doesn't end early.
    private func startRepeatTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, self.capturing, !self.paused, let pb = self.lastFrame, let now = self.mediaNow() else { return }
            if !self.lastFrameTime.isValid || (now - self.lastFrameTime).seconds > 1.9 { self.appendVideo(pb, at: now) }
        }
        t.resume()
        queue.async { self.repeatTimer = t }
    }

    // MARK: - Capture (queue)

    private func mediaNow() -> CMTime? {
        guard let start = startHost else { return nil }
        let host = paused ? (pausedAt ?? CMClockGetTime(CMClockGetHostTimeClock())) : CMClockGetTime(CMClockGetHostTimeClock())
        return host - start - pausedTotal
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard capturing, !paused, sb.isValid else { return }
        let pts = sb.presentationTimeStamp
        guard pts.isValid else { return }
        if startHost == nil {
            // The video starts with the first frame of the screen.
            guard type == .screen, Self.isCompleteFrame(sb) else { return }
            startHost = pts
        }
        guard let start = startHost else { return }
        let media = pts - start - pausedTotal
        guard media >= .zero else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sb), let pb = sb.imageBuffer else { return }
            lastFrame = pb
            appendVideo(pb, at: media)
        case .audio:
            systemAudio?.append(sb, at: media)
        default:
            if #available(macOS 15.0, *), type == .microphone { micAudio?.append(sb, at: media) }
        }
    }

    private static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    private func appendVideo(_ pb: CVPixelBuffer, at t: CMTime) {
        guard let input = videoInput, let adaptor, input.isReadyForMoreMediaData else { return }
        if lastFrameTime.isValid, t <= lastFrameTime { return }
        if adaptor.append(pb, withPresentationTime: t) { lastFrameTime = t }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            Log.write("Recording interrupted: \(error.localizedDescription)")
            self.stream = nil
            self.lastError = "Recording stopped unexpectedly (\(error.localizedDescription)); what was recorded is saved"
            self.stop()
        }
    }

    // MARK: - Saving (queue, then background)

    private func finishWriting(done: (() -> Void)?) {
        repeatTimer?.cancel()
        repeatTimer = nil
        // Close the video with the last picture, so it lasts until the moment recording stopped.
        if let pb = lastFrame, let end = mediaNow() { appendVideo(pb, at: end) }
        capturing = false
        let writer = self.writer
        let gotVideo = lastFrameTime.isValid
        systemAudio?.close()
        micAudio?.close()
        let sysURL = systemAudio?.hasAudio == true ? systemAudio?.url : nil
        let micURL = micAudio?.hasAudio == true ? micAudio?.url : nil
        self.writer = nil
        videoInput = nil
        adaptor = nil
        systemAudio = nil
        micAudio = nil
        lastFrame = nil
        guard let writer, let dir = workDir, gotVideo else {
            writer?.cancelWriting()
            finished(nil, error: "Nothing was recorded", done: done)
            return
        }
        videoInput?.markAsFinished()
        writer.inputs.forEach { $0.markAsFinished() }
        writer.finishWriting {
            guard writer.status == .completed else {
                self.finished(nil, error: "Saving the video failed: \(writer.error?.localizedDescription ?? "unknown error")", done: done)
                return
            }
            DispatchQueue.main.async {
                self.awaitRemote {
                    let files = self.remote.files
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.mixAndExport(video: writer.outputURL, system: sysURL, mic: micURL, remote: files, dir: dir, done: done)
                    }
                }
            }
        }
    }

    /// "Save now" from the remote: don't wait for the rest of the iPad's audio.
    func saveWithoutWaiting() {
        guard waitingRemote else { return }
        saveNow = true
    }

    /// After Stop, the remote may still be sending the end of its microphone recording: wait for it
    /// (with progress on the remote), unless it stops arriving.
    private func awaitRemote(_ go: @escaping () -> Void) {
        if remote.segments.isEmpty || remote.isComplete { go(); return }
        waitingRemote = true
        saveNow = false
        Log.write("Waiting for the remote's microphone audio (\(remote.receivedBytes / 1024) of \(remote.expectedBytes / 1024) KB)")
        onChange?()
        let began = Date()
        var lastBytes = remote.receivedBytes
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            let quiet = Date().timeIntervalSince(max(self.remote.lastDataAt, began))
            if self.remote.isComplete || self.saveNow || quiet > 120 || Date().timeIntervalSince(began) > 1800 {
                t.invalidate()
                self.waitingRemote = false
                if !self.remote.isComplete { Log.write("Saving without the rest of the remote's audio (\(self.remote.receivedBytes / 1024) of \(self.remote.expectedBytes / 1024) KB)") }
                self.onChange?()
                go()
                return
            }
            if self.remote.receivedBytes != lastBytes {
                lastBytes = self.remote.receivedBytes
                self.onChange?()
            }
        }
    }

    private func mixAndExport(video: URL, system: URL?, mic: URL?, remote: [(url: URL, start: Double)], dir: URL, done: (() -> Void)?) {
        // The remote's microphone: decode its pieces onto the recording's timeline.
        var remoteURL: URL?
        var coverage: [ClosedRange<Double>] = []
        if !remote.isEmpty {
            let rf = AudioTrackFile(url: dir.appendingPathComponent("remote.m4a"), channels: 1, bitrate: 96_000)
            for seg in remote {
                guard let data = try? Data(contentsOf: seg.url), let track = WebMOpus.parse(data) else {
                    Log.write("Remote microphone: could not read \(seg.url.lastPathComponent)")
                    continue
                }
                let first = seg.start + WebMOpus.firstPacketTime(track)
                var pos = first
                let n = WebMOpus.decode(track) { buf in
                    rf.write(buf, atSeconds: pos)
                    pos += Double(buf.frameLength) / 48000
                } ?? 0
                if n > 0 { coverage.append(first...(first + Double(n) / 48000)) }
                if n == 0 {
                    // Keep it for diagnosis.
                    let keep = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PPTRemote/unreadable")
                    try? FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: seg.url, to: keep.appendingPathComponent("\(recID)-\(seg.url.lastPathComponent)"))
                }
                Log.write("Remote microphone: \(seg.url.lastPathComponent) → \(String(format: "%.1f", Double(n) / 48000)) s from \(String(format: "%.1f", first)) s")
            }
            rf.close()
            if rf.hasAudio { remoteURL = rf.url }
        }

        let mixed = dir.appendingPathComponent("mixed.m4a")
        var hasAudio = false
        do {
            hasAudio = try AudioMixer.mix(system: system, mic: mic, remote: remoteURL, remoteCoverage: coverage, to: mixed) { p in
                DispatchQueue.main.async {
                    // Mixing is most of the work; the export afterwards only copies.
                    let v = p * 0.9
                    if v - self.savingProgress >= 0.05 || v >= 0.9 {
                        self.savingProgress = v
                        self.onChange?()
                    }
                }
            }
        } catch {
            Log.write("Mixing the sound failed: \(error.localizedDescription); saving the video without sound")
        }

        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = Self.uniqueURL(in: folder, name: Self.fileName(title: title, date: startedAt))

        let comp = AVMutableComposition()
        do {
            let vAsset = AVURLAsset(url: video)
            guard let vTrack = vAsset.tracks(withMediaType: .video).first,
                  let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NSError(domain: "PPTRemote", code: 2, userInfo: [NSLocalizedDescriptionKey: "no video track"])
            }
            try cv.insertTimeRange(vTrack.timeRange, of: vTrack, at: vTrack.timeRange.start)
            if hasAudio {
                let aAsset = AVURLAsset(url: mixed)
                if let aTrack = aAsset.tracks(withMediaType: .audio).first,
                   let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try ca.insertTimeRange(aTrack.timeRange, of: aTrack, at: .zero)
                }
            }
        } catch {
            finished(nil, error: "Saving failed: \(error.localizedDescription)", done: done)
            return
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            finished(nil, error: "Saving failed: no exporter", done: done)
            return
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.exportAsynchronously {
            if export.status == .completed {
                try? FileManager.default.removeItem(at: dir)
                self.finished(out, error: nil, done: done)
            } else {
                self.finished(nil, error: "Saving failed: \(export.error?.localizedDescription ?? "unknown error") (raw files kept in \(dir.path))", done: done)
            }
        }
    }

    private func finished(_ url: URL?, error: String?, done: (() -> Void)?) {
        DispatchQueue.main.async {
            if let url {
                self.lastFile = url
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                Log.write("Recording saved: \(url.path) (\(size / 1_000_000) MB, \(Self.clock(self.recordedBefore)))")
            }
            if let error {
                self.lastError = error
                Log.write(error)
            }
            self.phase = .off
            self.savingProgress = 0
            self.workDir = nil
            self.remote.finish()
            self.onChange?()
            done?()
        }
    }

    private func fail(_ message: String) {
        lastError = message
        phase = .off
        Log.write(message)
        onChange?()
    }

    // MARK: - Helpers

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func fileName(title: String, date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        var t = (title as NSString).deletingPathExtension
        t = t.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        if t.count > 60 { t = String(t.prefix(60)) }
        return t.isEmpty ? "Lecture \(f.string(from: date))" : "Lecture \(f.string(from: date)) – \(t)"
    }

    private static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension("mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) (\(n))").appendingPathExtension("mp4")
            n += 1
        }
        return url
    }
}

/// One audio source written to an AAC file, kept in step with the video: gaps are filled with silence,
/// so a position in the file is a position in the recording.
final class AudioTrackFile {
    let url: URL
    private let channels: AVAudioChannelCount
    private let bitrate: Int
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterFrom: AVAudioFormat?
    private var written: AVAudioFramePosition = 0
    private static let rate = 48000.0

    init(url: URL, channels: AVAudioChannelCount, bitrate: Int) {
        self.url = url
        self.channels = channels
        self.bitrate = bitrate
    }

    var hasAudio: Bool { written > 0 }

    func append(_ sb: CMSampleBuffer, at media: CMTime) {
        guard let desc = sb.formatDescription, CMSampleBufferGetNumSamples(sb) > 0 else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
        try? sb.withAudioBufferList { abl, _ in
            guard let src = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl.unsafePointer) else { return }
            self.write(src, atSeconds: media.seconds)
        }
    }

    /// Writes `src` so that it starts `seconds` into the recording.
    func write(_ src: AVAudioPCMBuffer, atSeconds seconds: Double) {
        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
            ]
            file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        guard let file, let buf = convert(src, to: file.processingFormat), buf.frameLength > 0 else { return }
        let expected = AVAudioFramePosition(seconds * Self.rate)
        let gap = expected - written
        if gap > AVAudioFramePosition(Self.rate * 0.02) {
            writeSilence(frames: gap, format: file.processingFormat)
        } else if gap < -AVAudioFramePosition(Self.rate * 0.05) {
            // Overlaps what is already written (clock jitter): keep only the new part.
            let skip = AVAudioFrameCount(-gap)
            guard skip < buf.frameLength, let rest = Self.slice(buf, from: skip) else { return }
            try? file.write(from: rest)
            written += AVAudioFramePosition(rest.frameLength)
            return
        }
        try? file.write(from: buf)
        written += AVAudioFramePosition(buf.frameLength)
    }

    private func writeSilence(frames: AVAudioFramePosition, format: AVAudioFormat) {
        guard let file else { return }
        var left = frames
        let chunk: AVAudioFrameCount = 4800
        guard let zero = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        while left > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), left))
            zero.frameLength = n
            for c in 0..<Int(format.channelCount) { zero.floatChannelData?[c].update(repeating: 0, count: Int(n)) }
            try? file.write(from: zero)
            left -= AVAudioFramePosition(n)
            written += AVAudioFramePosition(n)
        }
    }

    private func convert(_ src: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if src.format == target { return src }
        if converter == nil || converterFrom != src.format {
            converter = AVAudioConverter(from: src.format, to: target)
            converter?.downmix = true
            converterFrom = src.format
        }
        guard let converter else { return nil }
        let cap = AVAudioFrameCount(Double(src.frameLength) * target.sampleRate / src.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return src
        }
        return err == nil ? out : nil
    }

    static func slice(_ buf: AVAudioPCMBuffer, from start: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let n = buf.frameLength - start
        guard let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: n), let s = buf.floatChannelData, let d = out.floatChannelData else { return nil }
        out.frameLength = n
        for c in 0..<Int(buf.format.channelCount) { d[c].update(from: s[c] + Int(start), count: Int(n)) }
        return out
    }

    func close() {
        file = nil // AVAudioFile finishes the file when released
    }
}

/// Combines the Mac's own sound with the microphone into one stereo track.
enum AudioMixer {
    /// Returns false when there is no sound at all.
    /// `remote`: the iPad's microphone, used for your voice wherever it has sound (`remoteCoverage`, in seconds);
    /// the MacBook microphone fills the gaps (e.g. while the iPad's screen was locked).
    static func mix(system: URL?, mic: URL?, remote: URL? = nil, remoteCoverage: [ClosedRange<Double>] = [],
                    to out: URL, progress: (Double) -> Void) throws -> Bool {
        let sys = try system.map { try AVAudioFile(forReading: $0) }
        let micFile = try mic.map { try AVAudioFile(forReading: $0) }
        let remFile = try remote.map { try AVAudioFile(forReading: $0) }
        guard sys != nil || micFile != nil || remFile != nil else { return false }
        let rate = 48000.0
        let total = max(sys?.length ?? 0, micFile?.length ?? 0, remFile?.length ?? 0)
        guard total > 0 else { return false }

        // Bring the microphones to a comfortable level (quiet laptop mics), at most 4× louder.
        var micGainBase: Float = 1
        var remGainBase: Float = 1
        if let micFile {
            micGainBase = try speechGain(micFile, progress: { progress($0 * (remFile == nil ? 0.3 : 0.15)) })
            micFile.framePosition = 0
        }
        if let remFile {
            remGainBase = try speechGain(remFile, progress: { progress(0.15 + $0 * 0.15) })
            remFile.framePosition = 0
        }
        let coverage = remoteCoverage.sorted { $0.lowerBound < $1.lowerBound }
        var covIndex = 0
        var remWeight: Float = 0 // 1 = voice from the remote, 0 = from the MacBook

        let outFile = try AVAudioFile(forWriting: out, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let block: AVAudioFrameCount = 8192
        let outFmt = outFile.processingFormat
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: block),
              let sysBuf = sys.flatMap({ AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: block) }) ?? AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: block),
              let micBuf = micFile.flatMap({ AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: block) }) ?? AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: block),
              let remBuf = remFile.flatMap({ AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: block) }) ?? AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: block) else { return false }

        var duck: Float = 1   // microphone gain while the Mac plays sound (avoids hearing it twice)
        var limit: Float = 1  // keeps the sum from clipping
        var done: AVAudioFramePosition = 0
        while done < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(block), total - done))
            let sl = read(sys, into: sysBuf, frames: n)
            let ml = read(micFile, into: micBuf, frames: n)
            let rl = read(remFile, into: remBuf, frames: n)
            let r0 = remBuf.floatChannelData![0]
            outBuf.frameLength = n
            let L = outBuf.floatChannelData![0], R = outBuf.floatChannelData![1]
            let s0 = sysBuf.floatChannelData![0]
            let s1 = sysBuf.floatChannelData![sysBuf.format.channelCount > 1 ? 1 : 0]
            let m0 = micBuf.floatChannelData![0]
            var i = 0
            while i < Int(n) {
                let end = min(Int(n), i + 256)
                // Level of the Mac's own sound in this short piece.
                var e: Float = 0
                for k in i..<end where k < sl { e += s0[k] * s0[k] + s1[k] * s1[k] }
                let rms = (e / Float(2 * (end - i))).squareRoot()
                let target: Float = rms > 0.01 ? 0.35 : 1
                duck += (target - duck) * (target < duck ? 0.5 : 0.03)
                // Which microphone carries the voice here (with a short crossfade at the switch).
                let t = Double(done + AVAudioFramePosition(i)) / rate
                while covIndex < coverage.count, coverage[covIndex].upperBound < t { covIndex += 1 }
                let covered = covIndex < coverage.count && coverage[covIndex].contains(t)
                let wStart = remWeight
                remWeight += ((covered ? 1 : 0) - remWeight) * 0.15
                let wStep = (remWeight - wStart) / Float(end - i)
                var peak: Float = 0
                for k in i..<end {
                    let w = wStart + wStep * Float(k - i)
                    let mm = k < ml ? m0[k] * micGainBase : 0
                    let rr = k < rl ? r0[k] * remGainBase : 0
                    let m = (rr * w + mm * (1 - w)) * duck
                    let a = (k < sl ? s0[k] : 0) + m
                    let b = (k < sl ? s1[k] : 0) + m
                    L[k] = a
                    R[k] = b
                    peak = max(peak, abs(a), abs(b))
                }
                if peak * limit > 0.97 { limit = 0.97 / peak } else { limit = min(1, limit + 0.002) }
                if limit < 1 { for k in i..<end { L[k] *= limit; R[k] *= limit } }
                i = end
            }
            try outFile.write(from: outBuf)
            done += AVAudioFramePosition(n)
            progress(0.3 + 0.7 * Double(done) / Double(total))
        }
        return true
    }

    /// Reads up to `frames` frames; returns how many were real (the rest is silence).
    private static func read(_ file: AVAudioFile?, into buf: AVAudioPCMBuffer, frames: AVAudioFrameCount) -> Int {
        buf.frameLength = 0
        if let file, file.framePosition < file.length {
            try? file.read(into: buf, frameCount: frames)
        }
        let got = Int(buf.frameLength)
        buf.frameLength = frames
        for c in 0..<Int(buf.format.channelCount) where got < Int(frames) {
            buf.floatChannelData![c].advanced(by: got).update(repeating: 0, count: Int(frames) - got)
        }
        return got
    }

    /// Gain that brings the louder (speaking) parts of the microphone to a normal level.
    private static func speechGain(_ file: AVAudioFile, progress: (Double) -> Void) throws -> Float {
        let block: AVAudioFrameCount = 48000
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else { return 1 }
        var levels: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: block)
            let d = buf.floatChannelData![0]
            var i = 0
            while i + 2400 <= Int(buf.frameLength) {
                var e: Float = 0
                for k in i..<(i + 2400) { e += d[k] * d[k] }
                levels.append((e / 2400).squareRoot())
                i += 2400
            }
            progress(Double(file.framePosition) / Double(max(1, file.length)))
        }
        guard !levels.isEmpty else { return 1 }
        levels.sort()
        let loud = levels[min(levels.count - 1, Int(Double(levels.count) * 0.95))]
        guard loud > 0.0005 else { return 1 }
        return min(4, max(1, 0.12 / loud))
    }
}
