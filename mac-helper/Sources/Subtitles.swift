import AVFoundation
import Foundation
import Speech

/// A spoken word with its time in the recording.
struct SpokenWord {
    var start: Double
    var end: Double
    var text: String
}

/// One subtitle on screen.
struct SubtitleCue {
    var start: Double
    var end: Double
    var text: String
}

#if compiler(>=6.2) // SpeechAnalyzer needs the macOS 26 SDK
/// Speech-to-text on the Mac itself (nothing is uploaded), with the time of every word.
@available(macOS 26.0, *)
enum Transcriber {
    static func transcribe(audio: URL, locale id: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpokenWord] {
        let locale = Locale(identifier: id)
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        // Dictation knows the most languages (including Dutch); the newer transcriber is used when it's
        // already installed for the language.
        let module: any SpeechModule
        var results: AsyncThrowingStream<(CMTimeRange, AttributedString), Error>
        if let loc = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let t = DictationTranscriber(locale: loc, contentHints: [.farField], transcriptionOptions: [.punctuation],
                                         reportingOptions: [], attributeOptions: [.audioTimeRange])
            module = t
            results = AsyncThrowingStream { cont in
                Task {
                    do { for try await r in t.results { cont.yield((r.range, r.text)) }; cont.finish() } catch { cont.finish(throwing: error) }
                }
            }
        } else if let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let t = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            module = t
            results = AsyncThrowingStream { cont in
                Task {
                    do { for try await r in t.results { cont.yield((r.range, r.text)) }; cont.finish() } catch { cont.finish(throwing: error) }
                }
            }
        } else {
            throw NSError(domain: "PPTRemote", code: 4, userInfo: [NSLocalizedDescriptionKey: "macOS can't transcribe \(locale.identifier)"])
        }
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Log.write("Subtitles: downloading the speech model for \(locale.identifier)…")
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () -> [SpokenWord] in
            var words: [SpokenWord] = []
            for try await (range, text) in results {
                for run in text.runs {
                    // (A run is a word, or punctuation, with its time.)
                    let piece = String(text[run.range].characters)
                    guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let tr = run.audioTimeRange ?? range
                    words.append(SpokenWord(start: tr.start.seconds, end: tr.end.seconds, text: piece))
                }
                if duration > 0 { progress(min(0.99, range.end.seconds / duration)) }
            }
            return words
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.sorted { $0.start < $1.start }
    }
}
#endif

enum Subtitles {
    static let languages: [(id: String, name: String)] = [
        ("nl_NL", "Dutch"), ("en_GB", "English"), ("de_DE", "German"), ("fr_FR", "French"), ("es_ES", "Spanish"),
    ]

    private static let punctuation = CharacterSet(charactersIn: ".,!?;:…%)»”’")

    /// Joins pieces of text: words get a space between them, punctuation sticks to the word before it.
    static func join(_ words: [SpokenWord]) -> String {
        var out = ""
        for w in words {
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if out.isEmpty || t.unicodeScalars.first.map({ punctuation.contains($0) }) == true {
                out += t
            } else {
                out += " " + t
            }
        }
        return out
    }

    /// Short readable subtitles: at most two lines of ~42 characters and 6 seconds, split at pauses and sentence ends.
    static func cues(from words: [SpokenWord]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var cur: [SpokenWord] = []
        func flush() {
            guard let first = cur.first, let last = cur.last else { return }
            cues.append(SubtitleCue(start: first.start, end: last.end, text: wrap(join(cur))))
            cur = []
        }
        for w in words {
            // Punctuation that arrives on its own belongs to the text before it.
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t.unicodeScalars.allSatisfy({ punctuation.contains($0) }) {
                if let last = cur.last {
                    cur.append(SpokenWord(start: last.end, end: last.end, text: w.text)) // keep the word's timing
                } else if !cues.isEmpty {
                    cues[cues.count - 1].text += t
                }
                continue
            }
            if let first = cur.first, let last = cur.last {
                let text = join(cur + [w])
                let sentenceEnd = [".", "?", "!"].contains(where: { last.text.trimmingCharacters(in: .whitespaces).hasSuffix($0) })
                if w.start - last.end > 0.8 || text.count > 84 || w.end - first.start > 6 || (sentenceEnd && join(cur).count > 30) {
                    flush()
                }
            }
            cur.append(w)
        }
        flush()
        // Readable timing: at least a second on screen, never overlapping the next one.
        for i in cues.indices {
            var end = max(cues[i].end + 0.3, cues[i].start + 1.0)
            if i + 1 < cues.count { end = min(end, cues[i + 1].start - 0.04) }
            cues[i].end = max(cues[i].start + 0.3, end)
        }
        return cues
    }

    private static func wrap(_ s: String) -> String {
        guard s.count > 42 else { return s }
        let chars = Array(s)
        let mid = chars.count / 2
        var best = -1
        for d in 0..<mid where best < 0 {
            if mid + d < chars.count, chars[mid + d] == " " { best = mid + d } else if mid - d > 0, chars[mid - d] == " " { best = mid - d }
        }
        guard best > 0 else { return s }
        return String(chars[..<best]) + "\n" + String(chars[(best + 1)...])
    }

    private static func time(_ t: Double, comma: Bool) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, comma ? "," : ".", ms % 1000)
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { i, c in "\(i + 1)\n\(time(c.start, comma: true)) --> \(time(c.end, comma: true))\n\(c.text)\n" }.joined(separator: "\n")
    }

    static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { "\(time($0.start, comma: false)) --> \(time($0.end, comma: false))\n\($0.text)\n" }.joined(separator: "\n")
    }

    /// The lecture as text, per chapter (slide), with a new paragraph at longer pauses.
    static func transcript(_ words: [SpokenWord], chapters: [Chapter], title: String, language: String) -> String {
        var out = "\(title)\nTranscript (made automatically on the Mac, \(language); may contain mistakes)\n"
        let parts = chapters.count < 2 ? [Chapter(time: 0, key: "", title: "")] : chapters
        var wi = 0
        for (k, ch) in parts.enumerated() {
            let end = k + 1 < parts.count ? parts[k + 1].time : .infinity
            var section: [SpokenWord] = []
            while wi < words.count, words[wi].start < end {
                section.append(words[wi])
                wi += 1
            }
            if !ch.title.isEmpty { out += "\n[\(Chapters.stamp(ch.time))] \(ch.title)\n" }
            var para: [SpokenWord] = []
            for w in section {
                if let last = para.last, w.start - last.end > 2.0 {
                    out += join(para) + "\n\n"
                    para = []
                }
                para.append(w)
            }
            if !para.isEmpty { out += join(para) + "\n" }
        }
        return out
    }
}
