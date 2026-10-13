import AVFoundation
import Foundation

/// Reads the Opus sound inside a WebM file as recorded by a browser (MediaRecorder on the iPad / phone)
/// and decodes it to 48 kHz PCM with macOS's own Opus decoder.
enum WebMOpus {
    struct Track {
        var channels = 1
        var preSkip = 0
        var packets: [(time: Double, data: Data)] = []
    }

    // MARK: - WebM (EBML) parsing

    /// Element IDs whose children we read (everything else is skipped).
    private static let masters: Set<UInt32> = [
        0x1853_8067, // Segment
        0x1F43_B675, // Cluster
        0x1654_AE6B, // Tracks
        0xAE,        // TrackEntry
        0xA0,        // BlockGroup
        0x1549_A966, // Info
        0xE1,        // Audio
    ]

    static func parse(_ data: Data) -> Track? {
        var t = Track()
        var scale = 1_000_000.0 // TimecodeScale (ns per tick)
        var clusterTime = 0.0
        var audioTrack: UInt64?
        var currentTrackNumber: UInt64 = 0
        var currentIsOpus = false
        var gotHead = false
        let bytes = [UInt8](data)
        var p = 0

        func vint(keepMarker: Bool) -> (UInt64, Int, Bool)? {
            guard p < bytes.count else { return nil }
            let first = bytes[p]
            var len = 1
            var mask: UInt8 = 0x80
            while len <= 8 && first & mask == 0 { len += 1; mask >>= 1 }
            guard len <= 8, p + len <= bytes.count else { return nil }
            var v = UInt64(keepMarker ? first : first & (mask &- 1))
            var allOnes = (first & (mask &- 1)) == (mask &- 1)
            for i in 1..<len {
                v = (v << 8) | UInt64(bytes[p + i])
                if bytes[p + i] != 0xFF { allOnes = false }
            }
            p += len
            return (v, len, allOnes)
        }

        func uint(_ start: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<n { v = (v << 8) | UInt64(bytes[start + i]) }
            return v
        }

        while p < bytes.count {
            guard let (id, _, _) = vint(keepMarker: true), let (size, _, unknown) = vint(keepMarker: false) else { break }
            let id32 = UInt32(truncatingIfNeeded: id)
            if masters.contains(id32) {
                if id32 == 0xAE { currentTrackNumber = 0; currentIsOpus = false }
                continue // read the children in place (also works for "unknown size" live streams)
            }
            if unknown { break }
            let start = p
            let n = Int(size)
            guard n >= 0, start + n <= bytes.count else { break } // truncated (still uploading): stop here
            p += n
            switch id32 {
            case 0x2A_D7B1: // TimecodeScale
                scale = Double(uint(start, n))
            case 0xD7: // TrackNumber
                currentTrackNumber = uint(start, n)
            case 0x86: // CodecID
                currentIsOpus = String(bytes: bytes[start..<(start + n)], encoding: .ascii) == "A_OPUS"
                if currentIsOpus, audioTrack == nil { audioTrack = currentTrackNumber == 0 ? 1 : currentTrackNumber }
            case 0x63A2: // CodecPrivate: "OpusHead"
                if n >= 12, String(bytes: bytes[start..<(start + 8)], encoding: .ascii) == "OpusHead" {
                    t.channels = Int(bytes[start + 9])
                    t.preSkip = Int(bytes[start + 10]) | Int(bytes[start + 11]) << 8
                    gotHead = true
                }
            case 0xE7: // Cluster Timecode
                clusterTime = Double(uint(start, n))
            case 0xA3, 0xA1: // SimpleBlock / Block
                var q = start
                // Track number (vint without marker)
                let first = bytes[q]
                var len = 1
                var mask: UInt8 = 0x80
                while len <= 8 && first & mask == 0 { len += 1; mask >>= 1 }
                var track = UInt64(first & (mask &- 1))
                for i in 1..<len { track = (track << 8) | UInt64(bytes[q + i]) }
                q += len
                guard q + 3 <= start + n else { continue }
                let rel = Double(Int16(bitPattern: UInt16(bytes[q]) << 8 | UInt16(bytes[q + 1])))
                let flags = bytes[q + 2]
                q += 3
                if let a = audioTrack, track != a { continue }
                guard flags & 0x06 == 0 else { continue } // laced blocks: not produced by browsers for Opus
                let time = (clusterTime + rel) * scale / 1_000_000_000
                t.packets.append((time, Data(bytes[q..<(start + n)])))
            default:
                break
            }
        }
        if !gotHead { t.channels = max(1, t.channels) }
        return t.packets.isEmpty ? nil : t
    }

    /// Samples (at 48 kHz) in one Opus packet, from its table-of-contents byte.
    static func samplesInPacket(_ d: Data) -> Int {
        guard let toc = d.first else { return 0 }
        let config = Int(toc >> 3)
        let frame: Int
        switch config {
        case 0..<12: frame = [480, 960, 1920, 2880][config % 4]          // SILK: 10/20/40/60 ms
        case 12..<16: frame = [480, 960][config % 2]                     // Hybrid: 10/20 ms
        default: frame = [120, 240, 480, 960][(config - 16) % 4]         // CELT: 2.5/5/10/20 ms
        }
        switch toc & 3 {
        case 0: return frame
        case 1, 2: return frame * 2
        default: return d.count > 1 ? frame * Int(d[d.index(after: d.startIndex)] & 0x3F) : frame
        }
    }

    // MARK: - Decoding

    /// Decodes to mono 48 kHz float audio, handing it out in pieces (an hour of audio doesn't fit in memory
    /// comfortably). Returns the number of samples, or nil when macOS can't decode it.
    @discardableResult
    static func decode(_ t: Track, sink: (AVAudioPCMBuffer) -> Void) -> Int? {
        let ch = AVAudioChannelCount(max(1, min(2, t.channels)))
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                                               mChannelsPerFrame: ch, mBitsPerChannel: 0, mReserved: 0)
        guard let inFmt = AVAudioFormat(streamDescription: &asbd),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: ch, interleaved: false),
              let monoFmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return nil }
        var total = 0
        var skip = t.preSkip // Opus starts with a few ms of decoder warm-up
        let batch = 50
        var i = 0
        while i < t.packets.count {
            let slice = t.packets[i..<min(t.packets.count, i + batch)]
            i += batch
            let maxSize = slice.map { $0.data.count }.max() ?? 1
            let comp = AVAudioCompressedBuffer(format: inFmt, packetCapacity: AVAudioPacketCount(slice.count), maximumPacketSize: maxSize)
            var offset: Int64 = 0
            var samples = 0
            for (k, pkt) in slice.enumerated() {
                pkt.data.withUnsafeBytes { raw in
                    comp.data.advanced(by: Int(offset)).copyMemory(from: raw.baseAddress!, byteCount: pkt.data.count)
                }
                let n = samplesInPacket(pkt.data)
                comp.packetDescriptions![k] = AudioStreamPacketDescription(mStartOffset: offset, mVariableFramesInPacket: UInt32(n), mDataByteSize: UInt32(pkt.data.count))
                offset += Int64(pkt.data.count)
                samples += n
            }
            comp.packetCount = AVAudioPacketCount(slice.count)
            comp.byteLength = UInt32(offset)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(samples + 960)) else { return nil }
            var given = false
            var err: NSError?
            let status = conv.convert(to: pcm, error: &err) { _, st in
                if given { st.pointee = .noDataNow; return nil }
                given = true
                st.pointee = .haveData
                return comp
            }
            if status == .error {
                Log.write("Opus decoding failed: \(err?.localizedDescription ?? "?")")
                return total > 0 ? total : nil
            }
            let n = Int(pcm.frameLength)
            let start = min(skip, n)
            skip -= start
            guard n - start > 0, let mono = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: AVAudioFrameCount(n - start)) else { continue }
            mono.frameLength = AVAudioFrameCount(n - start)
            let d = mono.floatChannelData![0]
            let l = pcm.floatChannelData![0]
            if ch == 1 {
                d.update(from: l + start, count: n - start)
            } else {
                let r = pcm.floatChannelData![1]
                for k in start..<n { d[k - start] = (l[k] + r[k]) * 0.5 }
            }
            total += n - start
            sink(mono)
        }
        return total
    }

    /// Start time of the first packet (seconds since the recorder started), to place the sound exactly.
    static func firstPacketTime(_ t: Track) -> Double { t.packets.first?.time ?? 0 }
}
