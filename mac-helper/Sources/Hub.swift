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

    private(set) var state = PPTState()
    private(set) var deckID = ""
    private(set) var notes: [String] = []
    private(set) var hidden: [Bool] = []
    private(set) var loading = false
    private(set) var version = 1

    /// Called on the main queue whenever `version` changes.
    var onChange: [() -> Void] = []
    /// Returns true while at least one remote is connected (polls PowerPoint faster then).
    var hasClients: () -> Bool = { false }

    private var polling = false
    private var pollAgain = false
    private var lastPoll = Date.distantPast
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
        state.fullName.isEmpty ? "" : (state.fullName as NSString).lastPathComponent
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let interval: TimeInterval = self.hasClients() ? 0.35 : 2.0
            if Date().timeIntervalSince(self.lastPoll) >= interval { self.poll() }
        }
        poll()
    }

    func poll() {
        if polling { pollAgain = true; return }
        polling = true
        lastPoll = Date()
        ppt.pollState { [weak self] st in
            guard let self else { return }
            self.polling = false
            if let st { self.apply(st) }
            if self.pollAgain {
                self.pollAgain = false
                self.poll()
            }
        }
    }

    private func apply(_ st: PPTState) {
        let old = state
        state = st
        if !st.hasPresentation {
            if !deckID.isEmpty || !notes.isEmpty {
                deckID = ""
                notes = []
                hidden = []
                images.load(pdfPath: nil, hidden: [])
            }
        } else if st.fullName != old.fullName || st.count != old.count || deckID.isEmpty {
            if !loading { reloadDeck() }
        } else if st.index != old.index, st.index > 0 {
            refreshNotes(st.index)
        }
        if st != old { bump() }
    }

    func reloadDeck() {
        guard ppt.isRunning, !loading else { return }
        loading = true
        bump()
        Log.write("Loading deck…")
        ppt.loadDeck { [weak self] load in
            guard let self else { return }
            self.loading = false
            if let load {
                self.notes = load.notes
                self.hidden = load.hidden
                self.images.load(pdfPath: load.pdfPath, hidden: load.hidden)
                self.deckID = String(UInt32.random(in: 0...UInt32.max), radix: 36)
                Log.write("Deck loaded: \(load.fullName), \(load.notes.count) slides, images: \(load.pdfPath != nil)")
            } else {
                Log.write("Deck load failed")
            }
            self.bump()
            self.poll()
        }
    }

    private func refreshNotes(_ index: Int) {
        ppt.notes(for: index) { [weak self] text in
            guard let self, let text, index >= 1, index <= self.notes.count else { return }
            if self.notes[index - 1] != text {
                self.notes[index - 1] = text
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

    /// Handles a text command such as "next" or "goto 5". Returns false if unknown.
    @discardableResult
    func handle(command: String) -> Bool {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first?.lowercased() else { return false }
        let arg = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
        if cmd == "reload" {
            reloadDeck()
            return true
        }
        guard Self.navCommands.contains(cmd) else { return false }
        Log.write("Command: \(command)")
        ppt.navigate(cmd, target: arg) { [weak self] st in
            guard let self else { return }
            if let st { self.apply(st) }
            // Starting/ending a show takes a moment to settle; check again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.poll() }
        }
        return true
    }

    // MARK: - State JSON

    func stateObject(allNotes: Bool) -> [String: Any] {
        var notesOut: [String: String] = [:]
        if allNotes {
            for (i, n) in notes.enumerated() { notesOut[String(i + 1)] = n }
        } else {
            for i in [state.index, state.index + 1] where i >= 1 && i <= notes.count {
                notesOut[String(i)] = notes[i - 1]
            }
        }
        return [
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
        ]
    }

    func stateJSON(allNotes: Bool) -> Data {
        (try? JSONSerialization.data(withJSONObject: stateObject(allNotes: allNotes))) ?? Data("{}".utf8)
    }
}
