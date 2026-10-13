import CryptoKit
import Foundation

enum Log {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("PPTRemote.log")
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ msg: String) {
        let line = "\(formatter.string(from: Date())) \(msg)\n"
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}

/// Central model: polls PowerPoint, keeps the current state, and routes commands from BLE/HTTP clients.
final class Hub {
    static let shared = Hub()

    let ppt = PowerPoint()
    let images = SlideImages()
    let overlay = PointerOverlay()
    let sounds = SoundBoard()
    let recorder = LectureRecorder()

    private(set) var state = PPTState()
    private(set) var deckID = ""
    private(set) var notes: [String] = []
    private(set) var hidden: [Bool] = []
    private(set) var sections: [Section] = []
    private(set) var loading = false
    private(set) var version = 1

    /// Full name of the presentation picked on the remote; nil = follow PowerPoint (slide show / front window).
    private(set) var selectedFullName: String?

    /// Formatted notes per slide (only slides whose notes have formatting).
    private(set) var rich: [Int: [RichParagraph]] = [:]
    private var richDone: Set<Int> = []
    private var richQueue: [Int] = []
    private var richBusy = false
    private var lastCommandAt = Date.distantPast

    /// Video/audio on the current slide (only during a slide show).
    private(set) var media: [MediaItem] = []
    private(set) var mediaStatus: [Int: MediaStatus] = [:]
    private var mediaSlide = -1
    private var mediaBusy = false
    private var lastMediaPoll = Date.distantPast

    /// Called on the main queue whenever `version` changes.
    var onChange: [() -> Void] = []
    /// Returns true while at least one remote is connected (polls PowerPoint faster then).
    var hasClients: () -> Bool = { false }

    private var polling = false
    private var pollAgain = false
    private var lastPoll = Date.distantPast
    private var lastListPoll = Date.distantPast
    private var timer: Timer?

    var pin: String {
        if let p = UserDefaults.standard.string(forKey: "pin"), p.count == 4 { return p }
        return newPin()
    }

    @discardableResult
    func newPin() -> String {
        let p = String(format: "%04d", Int.random(in: 0...9999))
        UserDefaults.standard.set(p, forKey: "pin")
        bump()
        return p
    }

    var deckName: String {
        state.fullName.isEmpty ? "" : Self.shortName(state.fullName)
    }

    static func shortName(_ fullName: String) -> String {
        let last = (fullName as NSString).lastPathComponent
        return last.removingPercentEncoding ?? last
    }

    /// Selection passed to the AppleScripts ("" = follow PowerPoint).
    private var selection: String {
        guard let sel = selectedFullName, state.open.isEmpty || state.open.contains(where: { $0.fullName == sel }) else { return "" }
        return sel
    }

    static func presentationID(_ fullName: String) -> String {
        SHA256.hash(data: Data(fullName.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func start() {
        sounds.onChange = { [weak self] in self?.bump() }
        sounds.start()
        recorder.onChange = { [weak self] in self?.bump() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let interval: TimeInterval = self.hasClients() ? 0.35 : 2.0
            if Date().timeIntervalSince(self.lastPoll) >= interval { self.poll() }
            self.pollMediaIfNeeded()
            self.processRichQueue()
        }
        poll()
    }

    func poll() {
        if polling { pollAgain = true; return }
        polling = true
        lastPoll = Date()
        let withList = Date().timeIntervalSince(lastListPoll) > 2
        if withList { lastListPoll = Date() }
        ppt.pollState(selection: selection, withList: withList) { [weak self] st in
            guard let self else { return }
            self.polling = false
            if let st { self.apply(st) }
            if self.pollAgain {
                self.pollAgain = false
                self.poll()
            }
        }
    }

    private func apply(_ incoming: PPTState) {
        let old = state
        var st = incoming
        if st.listUnknown {
            st.open = old.open
            st.listUnknown = false
        }
        state = st
        if let sel = selectedFullName, st.running, !st.open.isEmpty, !st.open.contains(where: { $0.fullName == sel }) {
            Log.write("Selected presentation was closed; following PowerPoint again")
            selectedFullName = nil
        }
        if !st.hasPresentation {
            if !deckID.isEmpty || !notes.isEmpty {
                deckID = ""
                notes = []
                hidden = []
                sections = []
                resetRich()
                images.load(pdfPath: nil, hidden: []) {}
            }
        } else if st.fullName != old.fullName || st.count != old.count || deckID.isEmpty {
            if !loading { reloadDeck() }
        } else if st.index != old.index, st.index > 0 {
            refreshNotes(st.index)
            prioritizeRich(around: st.index)
        }
        if st.showing != old.showing || st.index != old.index || st.fullName != old.fullName {
            mediaSlide = -1
            media = []
            mediaStatus = [:]
            if st.showing { refreshMedia() }
        }
        overlay.update(showing: st.showing, black: st.black, bounds: st.showBounds, slide: st.index)
        recorder.followShow(st.showing ? st.showBounds : nil)
        if st != old { bump() }
    }

    func reloadDeck() {
        guard ppt.isRunning, !loading else { return }
        loading = true
        bump()
        Log.write("Loading deck…")
        let t = Date()
        ppt.loadDeck(selection: selection) { [weak self] load in
            guard let self else { return }
            guard let load else {
                self.loading = false
                Log.write("Deck load failed")
                self.bump()
                self.poll()
                return
            }
            self.images.load(pdfPath: load.pdfPath, hidden: load.hidden) {
                self.loading = false
                self.notes = load.notes
                self.hidden = load.hidden
                self.sections = load.sections
                self.overlay.slideAspect = self.images.aspect
                self.deckID = Self.makeDeckID(name: load.fullName, keys: self.images.keys, loaded: self.images.isLoaded)
                self.resetRich()
                self.richQueue = load.notes.enumerated().filter { !$0.element.isEmpty }.map { $0.offset + 1 }
                self.prioritizeRich(around: self.state.index)
                Log.write("Deck loaded: \(load.fullName), \(load.notes.count) slides, \(load.sections.count) sections, " +
                          "images: \(self.images.isLoaded), id \(self.deckID), \(Int(Date().timeIntervalSince(t) * 1000)) ms")
                self.bump()
                self.poll()
            }
        }
    }

    /// Same slides => same ID, so a remote can keep using the slides it already stored.
    private static func makeDeckID(name: String, keys: [String], loaded: Bool) -> String {
        let source = loaded ? keys.joined(separator: ",") : "\(name)|\(keys.count)|\(Date().timeIntervalSince1970)"
        return SHA256.hash(data: Data(source.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func refreshNotes(_ index: Int) {
        ppt.notes(selection: selection, for: index) { [weak self] text in
            guard let self, let text, index >= 1, index <= self.notes.count else { return }
            if self.notes[index - 1] != text {
                self.notes[index - 1] = text
                self.rich[index] = nil
                self.richDone.remove(index)
                self.richQueue.insert(index, at: 0)
                self.bump()
            }
        }
    }

    // MARK: - Formatted notes (read slowly in the background)

    private func resetRich() {
        rich = [:]
        richDone = []
        richQueue = []
    }

    private func prioritizeRich(around index: Int) {
        for i in [index + 1, index].reversed() where i >= 1 && richQueue.contains(i) {
            richQueue.removeAll { $0 == i }
            richQueue.insert(i, at: 0)
        }
    }

    private func processRichQueue() {
        guard !richBusy, !loading, !richQueue.isEmpty, ppt.isRunning else { return }
        let slide = richQueue[0]
        // Current/next slide right away; the rest only while the presenter isn't clicking.
        let urgent = slide == state.index || slide == state.index + 1
        guard urgent || Date().timeIntervalSince(lastCommandAt) > 2 else { return }
        richQueue.removeFirst()
        guard !richDone.contains(slide) else { return }
        richBusy = true
        let deck = deckID
        ppt.richNotes(selection: selection, for: slide) { [weak self] paras in
            guard let self else { return }
            self.richBusy = false
            guard deck == self.deckID else { return }
            self.richDone.insert(slide)
            if let paras, !paras.isEmpty {
                self.rich[slide] = paras
                self.bump()
            }
        }
    }

    // MARK: - Media

    private func refreshMedia() {
        let slide = state.index
        ppt.mediaList(selection: selection) { [weak self] items in
            guard let self, self.state.showing, self.state.index == slide else { return }
            self.mediaSlide = slide
            if items != self.media {
                self.media = items
                if !items.isEmpty { Log.write("Slide \(slide) has \(items.count) media item(s)") }
                self.bump()
            }
            self.lastMediaPoll = .distantPast
        }
    }

    private func pollMediaIfNeeded() {
        guard state.showing, !media.isEmpty, !mediaBusy, mediaSlide == state.index else { return }
        let playing = mediaStatus.values.contains { $0.state == "playing" }
        guard Date().timeIntervalSince(lastMediaPoll) > (playing ? 1.0 : 2.0) else { return }
        lastMediaPoll = Date()
        for item in media { mediaCommand("status", shape: item.shape) }
    }

    private func mediaCommand(_ cmd: String, shape: Int, value: Int = 0) {
        mediaBusy = true
        let slide = state.index
        ppt.media(selection: selection, cmd, shape: shape, value: value) { [weak self] st in
            guard let self else { return }
            self.mediaBusy = false
            guard let st, self.state.index == slide else { return }
            let old = self.mediaStatus[shape]
            self.mediaStatus[shape] = st
            // Remotes run the clock themselves while playing; only report real changes.
            if old?.state != st.state || cmd != "status" || abs((old?.position ?? 0) + (st.state == "playing" ? 1000 : 0) - st.position) > 1500 {
                self.bump()
            }
        }
    }

    func bump() {
        version += 1
        onChange.forEach { $0() }
    }

    // MARK: - Commands

    static let navCommands: Set<String> = ["next", "prev", "first", "last", "goto", "start", "starthere", "end", "black"]

    /// Handles a text command such as "next", "goto 5", "media play 2" or "pm 5000,4000". Returns false if unknown.
    @discardableResult
    func handle(command: String) -> Bool {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first?.lowercased() else { return false }
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch cmd {
        case "lz", "pd", "pm", "pu", "ink", "sd", "sm", "wb", "sp", "zm":
            return pointer(cmd, rest)
        case "snd":
            return sound(rest)
        case "rec":
            return record(rest)
        case "reload":
            reloadDeck()
            return true
        case "use":
            return use(rest)
        case "media":
            let f = rest.split(separator: " ").map(String.init)
            guard f.count >= 2, let shape = Int(f[1]), ["play", "pause", "stop", "seek", "rel"].contains(f[0]) else { return false }
            Log.write("Command: media \(rest)")
            lastCommandAt = Date()
            mediaCommand(f[0], shape: shape, value: f.count > 2 ? Int(f[2]) ?? 0 : 0)
            return true
        default:
            break
        }
        guard Self.navCommands.contains(cmd) else { return false }
        Log.write("Command: \(command)")
        lastCommandAt = Date()
        ppt.navigate(selection: selection, cmd, target: Int(rest) ?? 0) { [weak self] st in
            guard let self else { return }
            if let st { self.apply(st) }
            // Starting/ending a show takes a moment to settle; check again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.poll() }
        }
        return true
    }

    /// "rec start|pause|resume|stop": records the projector screen, the Mac's sound and the microphone.
    private func record(_ what: String) -> Bool {
        switch what {
        case "start": recorder.start(showBounds: state.showing ? state.showBounds : nil, title: state.hasPresentation ? deckName : "")
        case "pause": recorder.pause()
        case "resume": recorder.resume()
        case "stop": recorder.stop()
        case "savenow": recorder.saveWithoutWaiting()
        default:
            guard what.hasPrefix("screen ") else { return false }
            recorder.chooseScreen(String(what.dropFirst(7)))
        }
        return true
    }

    private func use(_ id: String) -> Bool {
        if id == "auto" {
            selectedFullName = nil
            Log.write("Presentation: follow PowerPoint")
        } else if let p = state.open.first(where: { Self.presentationID($0.fullName) == id }) {
            selectedFullName = p.fullName
            Log.write("Presentation selected: \(p.name)")
        } else {
            return false
        }
        bump()
        poll()
        return true
    }

    /// Pointer coordinates arrive as integers 0…10000 relative to the slide.
    private func pointer(_ cmd: String, _ rest: String) -> Bool {
        func pts(_ s: String) -> [CGPoint] {
            s.split(separator: ";").compactMap { pair in
                let xy = pair.split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2 else { return nil }
                return CGPoint(x: min(1, max(0, xy[0] / 10000)), y: min(1, max(0, xy[1] / 10000)))
            }
        }
        switch cmd {
        case "lz":
            overlay.laser(rest == "off" ? nil : pts(rest).last)
        case "pd":
            let f = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2, let p = pts(f[1]).first else { return false }
            overlay.penDown(color: .fromHex(f[0]), at: p)
        case "pm":
            overlay.penMove(pts(rest))
        case "sd":
            // "sd <line|arrow|ellipse|rect> #rrggbb x,y"
            let f = rest.split(separator: " ").map(String.init)
            guard f.count == 3, ["line", "arrow", "ellipse", "rect"].contains(f[0]), let p = pts(f[2]).first else { return false }
            overlay.shapeDown(kind: f[0], color: .fromHex(f[1]), at: p)
        case "sm":
            guard let p = pts(rest).last else { return false }
            overlay.shapeMove(p)
        case "wb":
            if rest == "clear" {
                overlay.setWhiteboard(true)
                overlay.clearInk()
            } else {
                overlay.setWhiteboard(rest == "on")
            }
            Log.write("Whiteboard \(overlay.whiteboard ? "on" : "off")")
            bump()
        case "sp":
            // "sp x,y r" (radius 0…10000 of the slide height) or "sp off"
            if rest == "off" {
                overlay.spotlight(nil, radius: 0)
            } else {
                let f = rest.split(separator: " ").map(String.init)
                guard let p = pts(f[0]).first else { return false }
                let r = f.count > 1 ? (Double(f[1]) ?? 1600) / 10000 : 0.16
                overlay.spotlight(p, radius: CGFloat(min(0.6, max(0.03, r))))
            }
        case "zm":
            // "zm x,y s" (centre of the visible part 0…10000, magnification ×100), "zm off", "zm prep"
            if rest == "off" {
                overlay.zoomOff()
            } else if rest == "prep" {
                overlay.prepareZoom()
                if !LiveZoomCapture.hasPermission { bump() }
            } else {
                let f = rest.split(separator: " ").map(String.init)
                guard f.count == 2, let c = pts(f[0]).first, let s = Double(f[1]) else { return false }
                overlay.zoom(center: c, scale: CGFloat(s / 100))
            }
        case "pu":
            // Only tell the remotes when "this page has drawings" changes; a state update after every
            // stroke made the remote re-render while the next letter was being written.
            let had = overlay.hasInkOnSlide
            overlay.penUp()
            if overlay.hasInkOnSlide != had { bump() }
        case "ink":
            overlay.clearInk()
            bump()
        default:
            return false
        }
        return true
    }

    /// "snd play <id>" | "snd stop" | "snd vol 0.8"
    private func sound(_ rest: String) -> Bool {
        let f = rest.split(separator: " ", maxSplits: 1).map(String.init)
        switch f.first {
        case "play" where f.count == 2:
            sounds.play(f[1])
        case "stop":
            sounds.stopAll()
        case "vol" where f.count == 2:
            guard let v = Float(f[1]) else { return false }
            sounds.setVolume(v)
            bump()
        default:
            return false
        }
        return true
    }

    // MARK: - State JSON

    func presentationList() -> [[String: Any]] {
        let current = state.fullName
        return state.open.map {
            ["id": Self.presentationID($0.fullName), "name": $0.name, "current": $0.fullName == current]
        }
    }

    /// - Parameter notesFor: slides whose notes to include (nil = current and next).
    func stateObject(notesFor: [Int]? = nil, includeList: Bool = true) -> [String: Any] {
        let wanted = notesFor ?? [state.index, state.index + 1]
        var notesOut: [String: String] = [:]
        var richOut: [String: Any] = [:]
        for i in wanted where i >= 1 && i <= notes.count {
            notesOut[String(i)] = notes[i - 1]
            if let r = rich[i] { richOut[String(i)] = Self.richJSON(r) }
        }
        var obj: [String: Any] = [
            "type": "state",
            "ver": version,
            "ppt": state.running,
            "pres": state.hasPresentation,
            "loading": loading,
            "deck": deckID,
            "name": deckName,
            "count": state.count,
            "index": state.index,
            "showing": state.showing,
            "black": state.black,
            "images": images.isLoaded,
            "hidden": hidden.enumerated().filter { $0.element }.map { $0.offset + 1 },
            "notes": notesOut,
            "ink": overlay.hasInkOnSlide,
            "wb": overlay.whiteboard,
            "zoomok": LiveZoomCapture.hasPermission,
            "rec": recorder.stateObject(),
            "skey": sounds.listKey,
            "svol": sounds.volume,
            "auto": selectedFullName == nil,
            "pcount": state.open.count,
        ]
        if !richOut.isEmpty { obj["rich"] = richOut }
        if !media.isEmpty, state.showing {
            obj["media"] = media.map { m -> [String: Any] in
                let st = mediaStatus[m.shape]
                return ["k": m.shape, "name": m.name, "kind": m.kind, "st": st?.state ?? "stopped", "pos": st?.position ?? 0]
            }
        }
        if includeList { obj["plist"] = presentationList() }
        return obj
    }

    func stateJSON(allNotes: Bool) -> Data {
        let obj = stateObject(notesFor: allNotes ? Array(1...max(1, notes.count)) : nil)
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    /// Level of notes available for a slide: 0 none, 1 plain, 2 formatted.
    func notesLevel(_ slide: Int) -> Int {
        guard slide >= 1, slide <= notes.count else { return 0 }
        return rich[slide] != nil ? 2 : 1
    }

    static func richJSON(_ paras: [RichParagraph]) -> [[String: Any]] {
        paras.map { p in
            var o: [String: Any] = ["r": p.runs.map { [$0.text, $0.style] }]
            if p.level > 1 { o["l"] = p.level }
            if !p.bullet.isEmpty { o["b"] = p.bullet; o["n"] = p.bulletText }
            return o
        }
    }

    /// Per-slide content keys and sections; sent once per deck so the remote can look slides up in its own storage.
    func deckObject(format: ImageFormat) -> [String: Any] {
        [
            "type": "deck",
            "deck": deckID,
            "name": deckName,
            "keys": images.keys,
            "fmt": format.rawValue,
            "macFormats": ImageFormat.encodable.map(\.rawValue),
            "sections": sections.map { ["name": $0.name, "first": $0.first, "count": $0.count] },
        ]
    }
}
