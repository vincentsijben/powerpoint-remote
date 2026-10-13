import Foundation

/// Receives the microphone recording of a remote (iPad / phone) over Bluetooth, piece by piece.
///
/// The remote records in "segments" (a new one after a pause, or when the iPad's screen was locked) and
/// keeps everything on the device until the Mac has acknowledged it, so nothing is lost when the
/// connection drops. Text commands:
///   "ma begin <rec> <seg>"        a segment starts now (the Mac notes the moment in the recording)
///   "ma end <rec> <seg> <bytes>"  the segment is complete
///   "ma ask <rec> <seg>"          how much has arrived?
/// Data arrives as binary writes: 0x01, rec (u32), seg (u32), offset (u32), bytes.
/// Replies: {"type":"mack","rec":…,"seg":…,"have":bytes} (have = -1: not wanted, e.g. an old recording).
final class RemoteMicStore {
    struct Segment {
        let url: URL
        let start: Double
        var have = 0
        var size: Int?
        var lastAck = 0
        var handle: FileHandle?
        var complete: Bool { size.map { have >= $0 } ?? false }
    }

    private(set) var segments: [UInt32: Segment] = [:]
    private(set) var recID: UInt32 = 0
    private var dir: URL?
    private(set) var lastDataAt = Date.distantPast
    private var lastGapAck = Date.distantPast

    /// Current position in the recording in seconds, or nil when not recording.
    var mediaNow: () -> Double? = { nil }
    var onChange: (() -> Void)?

    func reset(dir: URL?, rec: UInt32) {
        closeFiles()
        segments = [:]
        self.dir = dir
        recID = rec
    }

    /// Stops accepting data (the recording was saved).
    func finish() {
        closeFiles()
        dir = nil
    }

    var hasAudio: Bool { segments.values.contains { $0.have > 0 } }
    var isComplete: Bool { segments.values.allSatisfy(\.complete) }
    var receivedBytes: Int { segments.values.reduce(0) { $0 + $1.have } }
    var expectedBytes: Int { segments.values.reduce(0) { $0 + ($1.size ?? $1.have) } }

    /// Segments with sound, in order: file and start time in the recording.
    var files: [(url: URL, start: Double)] {
        segments.values.filter { $0.have > 0 }.sorted { $0.start < $1.start }.map { ($0.url, $0.start) }
    }

    func command(_ arg: String) -> [String: Any]? {
        let f = arg.split(separator: " ").map(String.init)
        guard f.count >= 3, let rec = UInt32(f[1]), let seg = UInt32(f[2]) else { return nil }
        guard rec == recID, dir != nil else { return ack(rec, seg, have: -1) }
        switch f[0] {
        case "begin":
            guard segments[seg] == nil else { return ack(rec, seg) }
            guard let now = mediaNow(), let dir else { return ack(rec, seg, have: -1) }
            let url = dir.appendingPathComponent("remote-\(seg).webm")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            // The message takes a moment over Bluetooth; the recorder on the remote started just before.
            segments[seg] = Segment(url: url, start: max(0, now - 0.06), handle: try? FileHandle(forWritingTo: url))
            Log.write("Remote microphone: segment \(seg) starts at \(String(format: "%.1f", now)) s")
            onChange?()
            return nil
        case "end":
            guard f.count >= 4, let size = Int(f[3]), segments[seg] != nil else { return ack(rec, seg, have: -1) }
            segments[seg]!.size = size
            Log.write("Remote microphone: segment \(seg) ended, \(size / 1024) KB")
            onChange?()
            return ack(rec, seg)
        case "ask":
            return ack(rec, seg)
        default:
            return nil
        }
    }

    /// A binary piece of audio. Returns an acknowledgement to send back, if one is due.
    func receive(_ data: Data) -> [String: Any]? {
        guard data.count >= 13 else { return nil }
        let b = [UInt8](data.prefix(13))
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
        let rec = u32(1), seg = u32(5), offset = Int(u32(9))
        guard rec == recID, dir != nil, var s = segments[seg] else { return ack(rec, seg, have: -1) }
        let payload = data.dropFirst(13)
        if offset == s.have {
            s.handle?.write(payload)
            s.have += payload.count
            lastDataAt = Date()
            let due = s.have - s.lastAck >= 8192 || s.complete
            if due { s.lastAck = s.have }
            segments[seg] = s
            if s.complete { onChange?() }
            return due ? ack(rec, seg) : nil
        }
        // Something went missing (or arrived twice): tell the remote where to continue, at most twice a second.
        segments[seg] = s
        guard offset > s.have, Date().timeIntervalSince(lastGapAck) > 0.5 else { return nil }
        lastGapAck = Date()
        var a = ack(rec, seg)
        a["gap"] = true
        return a
    }

    private func ack(_ rec: UInt32, _ seg: UInt32, have: Int? = nil) -> [String: Any] {
        ["type": "mack", "rec": rec, "seg": seg, "have": have ?? segments[seg]?.have ?? -1]
    }

    private func closeFiles() {
        for k in segments.keys {
            try? segments[k]?.handle?.close()
            segments[k]?.handle = nil
        }
    }
}
