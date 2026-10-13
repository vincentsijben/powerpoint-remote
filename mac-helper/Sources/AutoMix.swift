import Accelerate
import AVFoundation

/// Combines the MacBook microphone and the remote's (iPad / phone) microphone into one voice track:
///  1. finds how the iPad's sound lines up with the MacBook's (start offset and clock drift), by comparing
///     the loudness patterns of your voice in both;
///  2. writes the iPad's sound shifted and stretched onto the recording's timeline;
///  3. picks, moment by moment, the microphone that is closest to the speaker (the one that hears the voice
///     loudest compared with how it usually does), with the MacBook preferred while you type or use the
///     trackpad. Only one microphone is heard at a time (with a short crossfade), so the voice isn't doubled.
enum AutoMix {
    static let envRate = 500.0 // loudness values per second (every 2 ms)
    static let hop = 96        // 48000 / 500

    struct Result {
        let url: URL
        /// Weight of the remote's microphone per 10 ms (0 = MacBook, 1 = remote).
        let voice: [Float]
        let summary: String
    }

    /// lag(t) = a + b · (t − ts): the iPad's copy of the sound at recording time t sits at t + lag in its file.
    struct Fit {
        var a = 0.0
        var b = 0.0
        var ts = 0.0
        var points = 0
    }

    // MARK: - Loudness envelope

    /// Loudness (RMS of the slightly high-passed signal) per 2 ms, filled in at any position.
    final class EnvBuilder {
        private(set) var env: [Float] = []
        private var index = 0
        private var acc: Float = 0
        private var n = 0
        private var prev: Float = 0

        func start(at seconds: Double) {
            index = max(0, Int((seconds * envRate).rounded()))
            acc = 0
            n = 0
            prev = 0
        }

        func add(_ buf: AVAudioPCMBuffer) {
            guard let data = buf.floatChannelData else { return }
            let chans = Int(buf.format.channelCount)
            let frames = Int(buf.frameLength)
            for i in 0..<frames {
                var x = data[0][i]
                if chans > 1 { x = (x + data[1][i]) * 0.5 }
                let y = x - 0.95 * prev // emphasise speech over rumble
                prev = x
                acc += y * y
                n += 1
                if n == hop {
                    if index >= env.count { env.append(contentsOf: repeatElement(0, count: index - env.count + 50_000)) }
                    env[index] = (acc / Float(hop)).squareRoot()
                    index += 1
                    acc = 0
                    n = 0
                }
            }
        }

        func finish(length: Int? = nil) -> [Float] {
            if let length {
                if env.count < length { env.append(contentsOf: repeatElement(0, count: length - env.count)) } else { env.removeLast(env.count - length) }
            }
            return env
        }
    }

    static func envelope(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000) else { return nil }
        let b = EnvBuilder()
        b.start(at: 0)
        while file.framePosition < file.length {
            do { try file.read(into: buf, frameCount: 48000) } catch { break }
            if buf.frameLength == 0 { break }
            b.add(buf)
        }
        return b.finish(length: Int(Double(file.length) / Double(hop)))
    }

    // MARK: - Main entry

    static func prepare(segments: [(url: URL, start: Double)], macMic: URL?, system: URL?, desk: [Double],
                        dir: URL, progress: (Double) -> Void) -> Result? {
        // 1. Decode the remote's pieces once to measure them.
        var tracks: [(track: WebMOpus.Track, first: Double, length: Double)] = []
        let remoteEnv = EnvBuilder()
        for (k, seg) in segments.enumerated() {
            guard let data = try? Data(contentsOf: seg.url), let t = WebMOpus.parse(data) else {
                Log.write("Remote microphone: could not read \(seg.url.lastPathComponent)")
                keepForDiagnosis(seg.url)
                continue
            }
            let first = seg.start + WebMOpus.firstPacketTime(t)
            remoteEnv.start(at: first)
            let n = WebMOpus.decode(t) { remoteEnv.add($0) } ?? 0
            if n == 0 { keepForDiagnosis(seg.url); continue }
            tracks.append((t, first, Double(n) / 48000))
            progress(0.25 * Double(k + 1) / Double(segments.count))
        }
        guard !tracks.isEmpty else { return nil }

        // 2. Line up with the MacBook microphone.
        let macEnv = macMic.flatMap { envelope($0) }
        progress(0.35)
        var fits = tracks.map { Fit(a: 0, b: 0, ts: $0.first, points: 0) }
        var notes: [String] = []
        if let macEnv {
            let rEnv = remoteEnv.finish()
            var all: [[(t: Double, lag: Double, r: Float)]] = []
            for tr in tracks {
                all.append(lags(mac: macEnv, remote: rEnv, from: tr.first, to: tr.first + tr.length))
            }
            // Clock drift belongs to the device, so a long piece's drift also helps short pieces.
            var globalB: Double?
            var best = 0
            for (k, pts) in all.enumerated() {
                let f = fit(pts, ts: tracks[k].first, globalB: nil)
                fits[k] = f
                if f.points > best, f.b != 0 { best = f.points; globalB = f.b }
            }
            for (k, pts) in all.enumerated() where fits[k].b == 0 && globalB != nil {
                fits[k] = fit(pts, ts: tracks[k].first, globalB: globalB)
            }
            for (k, f) in fits.enumerated() {
                let line = f.points > 0
                    ? String(format: "offset %+.0f ms, drift %+.0f ppm (%d matches)", f.a * 1000, f.b * 1e6, f.points)
                    : "no match found, using the start time"
                Log.write("Remote microphone piece \(k + 1): \(line)")
            }
            let matched = fits.filter { $0.points > 0 }
            if let f = matched.first { notes.append(String(format: "iPad sound lined up (%+.0f ms, drift %+.0f ppm)", f.a * 1000, f.b * 1e6)) }
        }
        progress(0.45)

        // 3. Write the remote's sound onto the recording's timeline.
        let out = AudioTrackFile(url: dir.appendingPathComponent("remote.caf"), channels: 1, bitrate: 0, pcm: true)
        var coverage: [ClosedRange<Double>] = []
        for (k, tr) in tracks.enumerated() {
            if let r = render(tr.track, first: tr.first, fit: fits[k], into: out) { coverage.append(r) }
            progress(0.45 + 0.2 * Double(k + 1) / Double(tracks.count))
        }
        out.close()
        guard out.hasAudio else { return nil }

        // 4. Which microphone carries the voice when.
        guard let remEnv = envelope(out.url) else { return nil }
        progress(0.75)
        let sysEnv = system.flatMap { envelope($0) }
        let choice = chooseVoice(mac: macEnv, remote: remEnv, system: sysEnv, coverage: coverage, desk: desk)
        progress(0.8)
        notes.append(choice.summary)
        Log.write("Voice: \(choice.summary)")
        return Result(url: out.url, voice: choice.weights, summary: notes.joined(separator: "; "))
    }

    private static func keepForDiagnosis(_ url: URL) {
        let keep = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PPTRemote/unreadable")
        try? FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: url, to: keep.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(url.lastPathComponent)"))
    }

    // MARK: - Alignment

    /// Compares the loudness patterns (log scale) of both microphones in 6-second windows, every 10 seconds.
    static func lags(mac: [Float], remote: [Float], from start: Double, to end: Double) -> [(t: Double, lag: Double, r: Float)] {
        let L = 500 // search ±1 s
        let segStart = Int(start * envRate), segEnd = min(Int(end * envRate), remote.count)
        var W = 3000
        let usable = segEnd - segStart - 2 * L
        if usable < 1500 { return [] }
        if usable < W { W = usable } // short piece: one window over all of it
        let step = 5000
        func logs(_ a: ArraySlice<Float>) -> [Float] { a.map { log10(max($0, 1e-5)) } }
        var out: [(Double, Double, Float)] = []
        var n0 = segStart + L
        while n0 + W + L <= segEnd, n0 + W <= mac.count {
            defer { n0 += step }
            var A = logs(mac[n0..<(n0 + W)])
            let B = logs(remote[(n0 - L)..<(n0 + W + L)])
            // Both must contain speech-like variation (not just a steady noise floor).
            var meanA: Float = 0, sdA: Float = 0
            vDSP_normalize(A, 1, nil, 1, &meanA, &sdA, vDSP_Length(W))
            var meanB: Float = 0, sdB: Float = 0
            vDSP_normalize(B, 1, nil, 1, &meanB, &sdB, vDSP_Length(B.count))
            guard sdA > 0.2, sdB > 0.2 else { continue }
            for i in 0..<W { A[i] -= meanA }
            var normA: Float = 0
            vDSP_svesq(A, 1, &normA, vDSP_Length(W))
            normA = normA.squareRoot()
            let K = 2 * L + 1
            var res = [Float](repeating: 0, count: K)
            vDSP_conv(B, 1, A, 1, &res, 1, vDSP_Length(K), vDSP_Length(W))
            // Normalise by the energy of each shifted piece of B.
            var s: Double = 0, s2: Double = 0
            for j in 0..<W { s += Double(B[j]); s2 += Double(B[j] * B[j]) }
            var r = [Float](repeating: 0, count: K)
            for k in 0..<K {
                let varB = s2 - s * s / Double(W)
                r[k] = varB > 1e-9 ? res[k] / (Float(varB.squareRoot()) * normA) : 0
                if k + 1 < K {
                    let o = Double(B[k]), nw = Double(B[k + W])
                    s += nw - o
                    s2 += nw * nw - o * o
                }
            }
            var peak: Float = -1, kp = 0
            for k in 0..<K where r[k] > peak { peak = r[k]; kp = k }
            var second: Float = -1
            for k in 0..<K where abs(k - kp) > 25 { second = max(second, r[k]) }
            guard peak > 0.3, peak - second > 0.06 else { continue }
            var frac = 0.0
            if kp > 0, kp < K - 1 {
                let y0 = Double(r[kp - 1]), y1 = Double(r[kp]), y2 = Double(r[kp + 1])
                let d = y0 - 2 * y1 + y2
                if d < 0 { frac = max(-0.5, min(0.5, 0.5 * (y0 - y2) / d)) }
            }
            let lag = (Double(kp - L) + frac) / envRate
            out.append((Double(n0 + W / 2) / envRate, lag, peak))
        }
        return out
    }

    /// Straight line through the measurements (ignoring outliers); a constant when there are few.
    static func fit(_ pts: [(t: Double, lag: Double, r: Float)], ts: Double, globalB: Double?) -> Fit {
        var f = Fit(a: 0, b: 0, ts: ts, points: 0)
        guard !pts.isEmpty else {
            f.b = globalB ?? 0
            return f
        }
        var use = pts
        let span = (pts.map(\.t).max() ?? 0) - (pts.map(\.t).min() ?? 0)
        if pts.count >= 3, span >= 60 {
            for _ in 0..<4 {
                var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
                for p in use {
                    let w = Double(p.r), x = p.t - ts
                    sw += w; sx += w * x; sy += w * p.lag; sxx += w * x * x; sxy += w * x * p.lag
                }
                let den = sw * sxx - sx * sx
                guard den > 1e-9 else { break }
                f.b = max(-3e-4, min(3e-4, (sw * sxy - sx * sy) / den))
                f.a = (sy - f.b * sx) / sw
                let kept = use.filter { abs($0.lag - (f.a + f.b * ($0.t - ts))) < 0.015 }
                if kept.count == use.count || kept.count < 3 { break }
                use = kept
            }
            f.points = use.count
            return f
        }
        // Few measurements: the median offset, with the device's drift if known.
        f.b = globalB ?? 0
        let offs = pts.map { $0.lag - f.b * ($0.t - ts) }.sorted()
        f.a = offs[offs.count / 2]
        f.points = pts.count
        return f
    }

    // MARK: - Writing the remote's sound in place

    /// Decodes a piece and writes it where it belongs on the recording's timeline, corrected for drift.
    private static func render(_ t: WebMOpus.Track, first: Double, fit f: Fit, into out: AudioTrackFile) -> ClosedRange<Double>? {
        // In the iPad's file, recording time t sits at τ = t + a + b (t − ts)  →  t = (τ − a + b·ts) / (1 + b).
        let t0 = (first - f.a + f.b * f.ts) / (1 + f.b)
        var pos = t0
        let stretch = abs(f.b) > 1e-7
        var conv: AVAudioConverter?
        var inFmt: AVAudioFormat?
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        if stretch {
            // The iPad's samples, measured in Mac time, come at 48000 · (1 + b) per second.
            inFmt = AVAudioFormat(standardFormatWithSampleRate: 48000 * (1 + f.b), channels: 1)
            conv = inFmt.flatMap { AVAudioConverter(from: $0, to: outFmt) }
            conv?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        func push(_ buf: AVAudioPCMBuffer?, end: Bool) {
            guard let conv, let inFmt else {
                if let buf {
                    out.write(buf, atSeconds: pos)
                    pos += Double(buf.frameLength) / 48000
                }
                return
            }
            var src: AVAudioPCMBuffer?
            if let buf, let b2 = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: buf.frameLength) {
                b2.frameLength = buf.frameLength
                b2.floatChannelData![0].update(from: buf.floatChannelData![0], count: Int(buf.frameLength))
                src = b2
            }
            let cap = AVAudioFrameCount(Double(buf?.frameLength ?? 0) / (1 + f.b)) + 4096
            guard let o = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
            var given = false
            var err: NSError?
            _ = conv.convert(to: o, error: &err) { _, st in
                if given || src == nil {
                    st.pointee = end ? .endOfStream : .noDataNow
                    return nil
                }
                given = true
                st.pointee = .haveData
                return src
            }
            if o.frameLength > 0 {
                out.write(o, atSeconds: pos)
                pos += Double(o.frameLength) / 48000
            }
        }
        let n = WebMOpus.decode(t) { push($0, end: false) } ?? 0
        if stretch { push(nil, end: true) }
        return n > 0 ? t0...pos : nil
    }

    // MARK: - Choosing the microphone

    static func chooseVoice(mac: [Float]?, remote: [Float], system: [Float]?, coverage: [ClosedRange<Double>], desk: [Double]) -> (weights: [Float], summary: String) {
        let frames = max(mac?.count ?? 0, remote.count) / 5 + 1
        var covered = [Bool](repeating: false, count: frames)
        for c in coverage {
            let a = max(0, Int(c.lowerBound * 100) + 3), b = min(frames, Int(c.upperBound * 100) - 3)
            if a < b { for f in a..<b { covered[f] = true } }
        }
        guard let mac else {
            return (covered.map { $0 ? 1 : 0 }, "voice from the iPad / phone")
        }

        // Loudness per 10 ms, smoothed over 150 ms, in dB.
        func levels(_ env: [Float]) -> [Float] {
            var p = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var s: Float = 0
                var k = f * 5
                while k < min(env.count, f * 5 + 5) { s += env[k] * env[k]; k += 1 }
                p[f] = s / 5
            }
            var out = [Float](repeating: -120, count: frames)
            var acc: Float = 0
            let w = 15
            for f in 0..<frames {
                acc += p[f]
                if f >= w { acc -= p[f - w] }
                out[f] = 10 * log10(max(acc / Float(min(f + 1, w)), 1e-12))
            }
            return out
        }
        let lm = levels(mac), lr = levels(remote)
        let ls = system.map { levels($0) }

        var deskNear = [Bool](repeating: false, count: frames)
        for t in desk {
            let a = max(0, Int((t - 1.0) * 100)), b = min(frames, Int((t + 2.0) * 100))
            if a < b { for f in a..<b { deskNear[f] = true } }
        }

        func percentile(_ v: [Float], _ q: Double) -> Float {
            guard !v.isEmpty else { return -120 }
            let s = v.sorted()
            return s[min(s.count - 1, Int(Double(s.count) * q))]
        }
        let idx = (0..<frames).filter { covered[$0] }
        let floorM = percentile(idx.map { lm[$0] }, 0.1)
        let floorR = percentile(idx.map { lr[$0] }, 0.1)
        func sysOn(_ f: Int) -> Bool { (ls?[f] ?? -120) > -45 } // the Mac plays sound: its microphone hears that too
        func speech(_ f: Int) -> (Bool, Bool) { (lm[f] > floorM + 9, lr[f] > floorR + 9) }

        // How much louder the iPad hears the voice than the MacBook does; large = you're near the iPad.
        var diffs: [Float] = [], deskDiffs: [Float] = []
        for f in idx where !sysOn(f) {
            let (sm, sr) = speech(f)
            guard sm || sr else { continue }
            let d = lr[f] - lm[f]
            diffs.append(d)
            if deskNear[f] { deskDiffs.append(d) }
        }
        var threshold: Float = -200
        var how = "no clear difference: iPad wherever it has sound"
        if deskDiffs.count >= 100 {
            threshold = percentile(deskDiffs, 0.5) + 6
            how = "calibrated while you typed on the Mac"
        } else if let t = otsu(diffs) {
            threshold = t
            how = "two positions recognised"
        }

        var w = [Float](repeating: 0, count: frames)
        var cur: Float = 0
        var pending = 0
        var switches = 0
        var remoteFrames = 0, voiced = 0
        for f in 0..<frames {
            guard covered[f] else {
                cur = 0
                pending = 0
                continue
            }
            let (sm, sr) = speech(f)
            let want: Float
            if deskNear[f] {
                want = 0
            } else if sysOn(f) || !(sm || sr) {
                want = cur
            } else {
                let d = lr[f] - lm[f]
                want = cur == 1 ? (d < threshold - 3 ? 0 : 1) : (d > threshold + 3 ? 1 : 0)
            }
            if want != cur {
                pending += 1
                if pending >= 30 || deskNear[f] {
                    cur = want
                    pending = 0
                    switches += 1
                }
            } else {
                pending = 0
            }
            w[f] = cur
            if sm || sr {
                voiced += 1
                if cur == 1 { remoteFrames += 1 }
            }
        }
        let pct = voiced > 0 ? remoteFrames * 100 / voiced : 0
        return (w, "voice \(pct)% from the iPad / phone, \(100 - pct)% from the MacBook, \(switches) switches (\(how))")
    }

    /// Threshold between two groups of values (Otsu), only when the groups are clearly apart.
    static func otsu(_ v: [Float]) -> Float? {
        guard v.count >= 200 else { return nil }
        let lo: Float = -60, bin: Float = 0.5
        let nb = 240
        var h = [Double](repeating: 0, count: nb)
        for x in v { h[min(nb - 1, max(0, Int((x - lo) / bin)))] += 1 }
        let total = Double(v.count)
        var sumAll = 0.0
        for i in 0..<nb { sumAll += Double(i) * h[i] }
        var wB = 0.0, sumB = 0.0, best = 0.0, bestI = -1
        var means = (0.0, 0.0)
        for i in 0..<nb {
            wB += h[i]
            guard wB > 0 else { continue }
            let wF = total - wB
            guard wF > 0 else { break }
            sumB += Double(i) * h[i]
            let mB = sumB / wB, mF = (sumAll - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > best { best = between; bestI = i; means = (mB, mF) }
        }
        guard bestI >= 0 else { return nil }
        let sep = Float(means.1 - means.0) * bin
        // Both groups must be substantial and at least 10 dB apart.
        let smaller = min(v.filter { $0 < lo + Float(bestI) * bin }.count, v.filter { $0 >= lo + Float(bestI) * bin }.count)
        guard sep >= 10, Double(smaller) >= total * 0.08 else { return nil }
        return lo + (Float(bestI) + 0.5) * bin
    }
}
