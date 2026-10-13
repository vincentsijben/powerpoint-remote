import AVFoundation
import CoreMedia

/// A chapter in the recording: a slide (with its title), the whiteboard, or the Mac's screen.
struct Chapter {
    var time: Double
    var key: String
    var title: String
}

enum Chapters {
    /// Drops chapters shorter than a few seconds (skipping through slides) and merges repeats.
    static func tidy(_ list: [Chapter], duration: Double) -> [Chapter] {
        var out: [Chapter] = []
        let sorted = list.sorted { $0.time < $1.time }
        for (i, c) in sorted.enumerated() {
            let end = i + 1 < sorted.count ? sorted[i + 1].time : duration
            guard end - c.time >= 3 || i == 0 else { continue }
            if let last = out.last, last.key == c.key { continue }
            out.append(c)
        }
        if var first = out.first, first.time > 0 {
            first.time = 0
            out[0] = first
        }
        return out
    }

    static func stamp(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "0:00 1. Introduction" lines: paste into a YouTube / Stream description to get chapters there too.
    static func text(_ list: [Chapter]) -> String {
        list.map { "\(stamp($0.time)) \($0.title)" }.joined(separator: "\n") + "\n"
    }

    /// Writes the MP4: video and sound copied as they are (no re-encoding), plus a chapter track.
    static func writeMP4(video: URL, audio: URL?, chapters: [Chapter], to out: URL) throws {
        let vAsset = AVURLAsset(url: video)
        guard let vTrack = vAsset.tracks(withMediaType: .video).first else { throw err("no video") }
        let duration = vTrack.timeRange.end
        let aAsset = audio.map { AVURLAsset(url: $0) }
        let aTrack = aAsset?.tracks(withMediaType: .audio).first

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                     sourceFormatHint: (vTrack.formatDescriptions.first as! CMFormatDescription))
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw err("can't add video") }
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if let aTrack {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                       sourceFormatHint: (aTrack.formatDescriptions.first as! CMFormatDescription))
            i.expectsMediaDataInRealTime = false
            guard writer.canAdd(i) else { throw err("can't add audio") }
            writer.add(i)
            aIn = i
        }
        var tIn: AVAssetWriterInput?
        var textSamples: [CMSampleBuffer] = []
        if chapters.count >= 2, let fd = textFormat() {
            let i = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: fd)
            i.marksOutputTrackAsEnabled = false
            if writer.canAdd(i), vIn.canAddTrackAssociation(withTrackOf: i, type: AVAssetTrack.AssociationType.chapterList.rawValue) {
                writer.add(i)
                vIn.addTrackAssociation(withTrackOf: i, type: AVAssetTrack.AssociationType.chapterList.rawValue)
                tIn = i
                for (k, c) in chapters.enumerated() {
                    let start = CMTime(seconds: c.time, preferredTimescale: 600)
                    let end = k + 1 < chapters.count ? CMTime(seconds: chapters[k + 1].time, preferredTimescale: 600) : duration
                    guard end > start, let sb = textSample(c.title, start: start, duration: end - start, format: fd) else { continue }
                    textSamples.append(sb)
                }
            }
        }

        let vReader = try AVAssetReader(asset: vAsset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        vReader.add(vOut)
        var aReader: AVAssetReader?
        var aOut: AVAssetReaderTrackOutput?
        if let aAsset, let aTrack {
            let r = try AVAssetReader(asset: aAsset)
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            o.alwaysCopiesSampleData = false
            r.add(o)
            aReader = r
            aOut = o
        }
        guard vReader.startReading(), aReader?.startReading() ?? true else { throw err("can't read the recording") }
        guard writer.startWriting() else { throw writer.error ?? err("can't write") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        func pump(_ input: AVAssetWriterInput, label: String, next: @escaping () -> CMSampleBuffer?) {
            group.enter()
            let q = DispatchQueue(label: "pptremote.mux.\(label)")
            var done = false
            input.requestMediaDataWhenReady(on: q) {
                while input.isReadyForMoreMediaData, !done {
                    guard let sb = next(), writer.status == .writing else {
                        done = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if !input.append(sb) {
                        done = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        pump(vIn, label: "v") { vOut.copyNextSampleBuffer() }
        if let aIn, let aOut {
            // The sound must not run past the video.
            pump(aIn, label: "a") {
                guard let sb = aOut.copyNextSampleBuffer() else { return nil }
                return sb.presentationTimeStamp < duration ? sb : nil
            }
        }
        if let tIn {
            var idx = 0
            pump(tIn, label: "t") {
                guard idx < textSamples.count else { return nil }
                idx += 1
                return textSamples[idx - 1]
            }
        }
        group.wait()
        vReader.cancelReading()
        aReader?.cancelReading()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? err("writing failed") }
    }

    /// QuickTime text sample description (what QuickTime Player and VLC read as chapter names).
    private static func textFormat() -> CMFormatDescription? {
        var d = Data()
        func u16(_ v: UInt16) { d.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
        func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xFFFF)) }
        u32(0) // size, filled in below
        d.append(contentsOf: Array("text".utf8))
        d.append(contentsOf: [0, 0, 0, 0, 0, 0]) // reserved
        u16(1)                // data reference index
        u32(0)                // display flags
        u32(0)                // text justification
        u16(0); u16(0); u16(0) // background colour
        u16(0); u16(0); u16(0); u16(0) // default text box
        u32(0); u32(0)        // reserved
        u16(0)                // font number
        u16(0)                // font face
        d.append(0)           // reserved
        u16(0)                // reserved
        u16(0); u16(0); u16(0) // foreground colour
        d.append(0)           // font name (empty Pascal string)
        let size = UInt32(d.count)
        d.replaceSubrange(0..<4, with: [UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
        var fd: CMFormatDescription?
        let status = d.withUnsafeBytes { raw in
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: nil, bigEndianTextDescriptionData: raw.bindMemory(to: UInt8.self).baseAddress!, size: d.count,
                flavor: nil, mediaType: kCMMediaType_Text, formatDescriptionOut: &fd)
        }
        return status == noErr ? fd : nil
    }

    private static func textSample(_ text: String, start: CMTime, duration: CMTime, format: CMFormatDescription) -> CMSampleBuffer? {
        let utf8 = Array(text.utf8.prefix(1000))
        var d = Data([UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)])
        d.append(contentsOf: utf8)
        d.append(contentsOf: [0, 0, 0, 12] + Array("encd".utf8) + [0, 0, 1, 0]) // the text is UTF-8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: d.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: d.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let ok = d.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: d.count) }
        guard ok == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = d.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    private static func err(_ s: String) -> NSError {
        NSError(domain: "PPTRemote", code: 3, userInfo: [NSLocalizedDescriptionKey: s])
    }
}
