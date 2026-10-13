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
        if let f = lastFile { o["file"] = f.lastPathComponent }
        if let e = lastError { o["err"] = e }
        if !displayName.isEmpty { o["disp"] = displayName }
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
                // The projector: the screen with the slide show, otherwise an external screen, otherwise the Mac's own.
                let displays = content.displays
                var display = displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays[0]
                if let b = showBounds, b.width > 10, let d = displays.first(where: { $0.frame.contains(CGPoint(x: b.midX, y: b.midY)) }) {
                    display = d
                } else if let ext = displays.first(where: { $0.displayID != CGMainDisplayID() }) {
                    display = ext
                }
                self.begin(display: display, mic: mic)
            }
        }
    }

    private func begin(display: SCDisplay, mic: Bool) {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }
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
            DispatchQueue.global(qos: .userInitiated).async {
                self.mixAndExport(video: writer.outputURL, system: sysURL, mic: micURL, dir: dir, done: done)
            }
        }
    }

    private func mixAndExport(video: URL, system: URL?, mic: URL?, dir: URL, done: (() -> Void)?) {
        let mixed = dir.appendingPathComponent("mixed.m4a")
        var hasAudio = false
        do {
            hasAudio = try AudioMixer.mix(system: system, mic: mic, to: mixed) { p in
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
            self.write(src, at: media)
        }
    }

    private func write(_ src: AVAudioPCMBuffer, at media: CMTime) {
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
        let expected = AVAudioFramePosition(media.seconds * Self.rate)
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
    static func mix(system: URL?, mic: URL?, to out: URL, progress: (Double) -> Void) throws -> Bool {
        let sys = try system.map { try AVAudioFile(forReading: $0) }
        let micFile = try mic.map { try AVAudioFile(forReading: $0) }
        guard sys != nil || micFile != nil else { return false }
        let rate = 48000.0
        let total = max(sys?.length ?? 0, micFile?.length ?? 0)
        guard total > 0 else { return false }

        // Bring the microphone to a comfortable level (quiet laptop mics), at most 4× louder.
        var micGainBase: Float = 1
        if let micFile {
            micGainBase = try speechGain(micFile, progress: { progress($0 * 0.3) })
            micFile.framePosition = 0
        }

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
              let micBuf = micFile.flatMap({ AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: block) }) ?? AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: block) else { return false }

        var duck: Float = 1   // microphone gain while the Mac plays sound (avoids hearing it twice)
        var limit: Float = 1  // keeps the sum from clipping
        var done: AVAudioFramePosition = 0
        while done < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(block), total - done))
            let sl = read(sys, into: sysBuf, frames: n)
            let ml = read(micFile, into: micBuf, frames: n)
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
                var peak: Float = 0
                for k in i..<end {
                    let m = k < ml ? m0[k] * micGainBase * duck : 0
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
