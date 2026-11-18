import AVFoundation
import Foundation

/// Finds how long the videos / sounds on a PowerPoint slide are. PowerPoint's AppleScript only reports the
/// play position, so the length is read from the saved .pptx itself: the slide's XML says which media file
/// belongs to which shape (and how much of it is trimmed), and AVFoundation reads that file's duration.
/// Everything runs on a background queue; results are cached per file version and slide.
enum MediaDurations {
    private static let queue = DispatchQueue(label: "pptremote.mediadurations", qos: .utility)
    private static var cache: [String: [Pic]] = [:] // "path|mtime|slide" → media on that slide
    private static var fileCache: [String: Double] = [:] // "path|mtime|entry" → seconds

    /// `items`: the media shapes on the slide as PowerPoint lists them (shape index, name), in order.
    /// Completion (main queue) gets shape index → length in ms, for the ones that could be found.
    static func lookup(pptx: String, slide: Int, items: [(shape: Int, name: String)],
                       _ completion: @escaping ([Int: Int]) -> Void) {
        guard ["pptx", "pptm", "ppsx", "ppsm"].contains((pptx as NSString).pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: pptx) else { completion([:]); return }
        queue.async {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: pptx)[.modificationDate] as? Date)?
                .map { String($0.timeIntervalSince1970) } ?? ""
            let key = "\(pptx)|\(mtime)|\(slide)"
            let pics = cache[key] ?? ((try? slidePics(pptx: pptx, slide: slide, mtime: mtime)) ?? [])
            cache[key] = pics
            var byName: [String: Int] = [:]
            for p in pics where p.ms != nil && byName[p.name] == nil { byName[p.name] = p.ms }
            var out: [Int: Int] = [:]
            for (i, item) in items.enumerated() {
                if let ms = byName[item.name] {
                    out[item.shape] = ms
                } else if i < pics.count, let ms = pics[i].ms {
                    out[item.shape] = ms // no name match: fall back to the order on the slide
                }
            }
            if !out.isEmpty { Log.write("Media length (slide \(slide)): \(out.values.map { "\($0 / 1000) s" }.joined(separator: ", "))") }
            DispatchQueue.main.async { completion(out) }
        }
    }

    private struct Pic {
        var name: String
        var ms: Int?
    }

    private static func slidePics(pptx: String, slide: Int, mtime: String) throws -> [Pic] {
        // Slide number → slide XML: presentation.xml lists the slides in order, its .rels gives their files.
        let pres = try xml(pptx, "ppt/presentation.xml")
        let ids = try pres.nodes(forXPath: "//*[local-name()='sldIdLst']/*[local-name()='sldId']").compactMap { attr($0, "id", ns: "r") }
        guard slide >= 1, slide <= ids.count else { return [] }
        let presRels = try rels(pptx, "ppt/_rels/presentation.xml.rels")
        guard let slideTarget = presRels[ids[slide - 1]]?.target else { return [] }
        let slidePath = resolve(slideTarget, from: "ppt")
        let slideDir = (slidePath as NSString).deletingLastPathComponent
        let slideFile = (slidePath as NSString).lastPathComponent
        let doc = try xml(pptx, slidePath)
        let slideRels = (try? rels(pptx, "\(slideDir)/_rels/\(slideFile).rels")) ?? [:]

        var pics: [Pic] = []
        for pic in try doc.nodes(forXPath: "//*[local-name()='pic']") {
            guard let el = pic as? XMLElement else { continue }
            func first(_ name: String) -> XMLElement? {
                (try? el.nodes(forXPath: ".//*[local-name()='\(name)']"))?.first as? XMLElement
            }
            // p14:media (embedded or linked) is the actual file; a:videoFile / a:audioFile is the older reference.
            let rid = first("media").flatMap { attr($0, "embed", ns: "r") ?? attr($0, "link", ns: "r") }
                ?? first("videoFile").flatMap { attr($0, "link", ns: "r") }
                ?? first("audioFile").flatMap { attr($0, "link", ns: "r") }
            guard let rid else { continue }
            let name = first("cNvPr").flatMap { attr($0, "name", ns: nil) } ?? ""
            var ms: Int?
            if let rel = slideRels[rid], let seconds = duration(pptx: pptx, mtime: mtime, rel: rel, slideDir: slideDir) {
                var length = seconds * 1000
                if let trim = first("trim") {
                    length -= Double(attr(trim, "st", ns: nil) ?? "") ?? 0
                    length -= Double(attr(trim, "end", ns: nil) ?? "") ?? 0
                }
                if length > 0 { ms = Int(length) }
            }
            pics.append(Pic(name: name, ms: ms))
        }
        return pics
    }

    private static func duration(pptx: String, mtime: String, rel: (target: String, external: Bool), slideDir: String) -> Double? {
        if rel.external {
            // A linked file: a file:// URL or a path relative to the presentation.
            let url = URL(string: rel.target).flatMap { $0.isFileURL ? $0 : nil }
                ?? URL(fileURLWithPath: rel.target, relativeTo: URL(fileURLWithPath: pptx).deletingLastPathComponent())
            return FileManager.default.fileExists(atPath: url.path) ? seconds(url) : nil
        }
        let entry = resolve(rel.target, from: slideDir)
        let key = "\(pptx)|\(mtime)|\(entry)"
        if let s = fileCache[key] { return s }
        // AVFoundation can't read inside a zip: unpack this one file to a temporary folder.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pptremote-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil,
              unzip(["-o", "-j", "-qq", pptx, entry, "-d", tmp.path]) != nil else { return nil }
        let file = tmp.appendingPathComponent((entry as NSString).lastPathComponent)
        guard let s = seconds(file) else { return nil }
        fileCache[key] = s
        return s
    }

    private static func seconds(_ url: URL) -> Double? {
        guard let d = try? runBlocking({ try await AVURLAsset(url: url).load(.duration) }), d.isNumeric, d.seconds > 0 else { return nil }
        return d.seconds
    }

    // MARK: - Zip and XML helpers

    private static func unzip(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    private static func xml(_ pptx: String, _ entry: String) throws -> XMLDocument {
        guard let data = unzip(["-p", pptx, entry]) else { throw NSError(domain: "PPTRemote", code: 1) }
        return try XMLDocument(data: data)
    }

    /// Relationship id → (target, external).
    private static func rels(_ pptx: String, _ entry: String) throws -> [String: (target: String, external: Bool)] {
        var out: [String: (target: String, external: Bool)] = [:]
        for node in try xml(pptx, entry).nodes(forXPath: "//*[local-name()='Relationship']") {
            guard let el = node as? XMLElement, let id = attr(el, "Id", ns: nil), let target = attr(el, "Target", ns: nil) else { continue }
            out[id] = (target, attr(el, "TargetMode", ns: nil) == "External")
        }
        return out
    }

    /// Attribute by local name; `ns` is the usual prefix ("r") for namespaced attributes, nil for plain ones.
    private static func attr(_ node: XMLNode, _ name: String, ns: String?) -> String? {
        guard let el = node as? XMLElement else { return nil }
        for a in el.attributes ?? [] {
            let local = a.localName ?? a.name ?? ""
            let prefix = a.prefix ?? ""
            if local == name, ns == nil ? prefix.isEmpty : !prefix.isEmpty { return a.stringValue }
        }
        return nil
    }

    /// "../media/media1.mp4" relative to "ppt/slides" → "ppt/media/media1.mp4"; "/ppt/x" is from the root.
    private static func resolve(_ target: String, from dir: String) -> String {
        var parts = target.hasPrefix("/") ? [] : dir.split(separator: "/").map(String.init)
        for c in target.split(separator: "/") {
            if c == ".." { if !parts.isEmpty { parts.removeLast() } } else if c != "." { parts.append(String(c)) }
        }
        return parts.joined(separator: "/")
    }
}
