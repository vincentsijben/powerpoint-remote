import AppKit

/// Controls Apple Keynote via AppleScript, like `PowerPoint` does for PowerPoint.
final class Keynote: SlideApp {
    let kind = "keynote"
    static let bundleID = "com.apple.Keynote"
    private let queue = PowerPoint.scriptQueue
    private var compiled: [String: NSAppleScript] = [:]
    /// Keynote doesn't report a black screen; it's toggled with the B key, so remember it here.
    private var black = false
    private var lastIndex = 0
    private var lastListRaw = ""

    private static let US = "\u{1F}"
    private static let RS = "\u{1E}"
    private static let GS = "\u{1D}"

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    // MARK: - Scripts

    private static let common = """
    on docPath(d)
      tell application id "com.apple.Keynote"
        try
          set f to file of d
          if f is not missing value then return POSIX path of (f as alias)
        end try
        return "keynote:" & (name of d)
      end tell
    end docPath

    on pickDoc(sel)
      tell application id "com.apple.Keynote"
        if (count of documents) = 0 then return missing value
        if sel is not "" then
          repeat with i from 1 to (count of documents)
            if my docPath(document i) is sel then return document i
          end repeat
        end if
        return front document
      end tell
    end pickDoc

    -- Position of the current slide (Keynote's "slide number" leaves out skipped slides).
    on posOf(d)
      tell application id "com.apple.Keynote"
        set sn to slide number of current slide of d
        set sk to skipped of every slide of d
        if sn > 0 then
          set k to 0
          repeat with i from 1 to (count of sk)
            if item i of sk is false then
              set k to k + 1
              if k = sn then return i
            end if
          end repeat
        end if
        set cs to current slide of d
        repeat with i from 1 to (count of slides of d)
          if (slide i of d) is cs then return i
        end repeat
        return 1
      end tell
    end posOf
    """

    /// Returns: path US slides US current US playing US names(GS) US paths(GS)   (or NONE)
    private static let stateScript = common + """

    on run argv
      set sel to item 1 of argv
      set withList to item 2 of argv
      set US to character id 31
      set GS to character id 29
      tell application id "com.apple.Keynote"
        set d to my pickDoc(sel)
        if d is missing value then return "NONE"
        set n to count of slides of d
        set idx to 1
        try
          set idx to my posOf(d)
        end try
        set pl to "0"
        try
          if playing then set pl to "1"
        end try
        set names to "-"
        set fulls to "-"
        if withList is "1" then
          set nl to {}
          set fl to {}
          repeat with i from 1 to (count of documents)
            set end of nl to name of document i
            set end of fl to my docPath(document i)
          end repeat
          set AppleScript's text item delimiters to GS
          set names to nl as text
          set fulls to fl as text
          set AppleScript's text item delimiters to ""
        end if
        return my docPath(d) & US & n & US & idx & US & pl & US & names & US & fulls
      end tell
    end run
    """

    /// Returns: path, then per slide RS skipped US notes
    private static let loadScript = common + """

    on run argv
      set US to character id 31
      set RS to character id 30
      tell application id "com.apple.Keynote"
        set d to my pickDoc(item 1 of argv)
        if d is missing value then return ""
        set out to my docPath(d)
        repeat with i from 1 to (count of slides of d)
          set s to slide i of d
          set sk to "0"
          if skipped of s then set sk to "1"
          set nt to ""
          try
            set nt to (presenter notes of s) as text
          end try
          set out to out & RS & sk & US & nt
        end repeat
        return out
      end tell
    end run
    """

    private static let exportScript = common + """

    on run argv
      tell application id "com.apple.Keynote"
        set d to my pickDoc(item 1 of argv)
        if d is missing value then return ""
        export d to (POSIX file (item 2 of argv)) as PDF with properties {PDF image quality:Best, skipped slides:false, all stages:false}
        return "ok"
      end tell
    end run
    """

    private static let navScript = common + """

    on run argv
      set cmd to item 2 of argv
      set target to (item 3 of argv) as integer
      tell application id "com.apple.Keynote"
        set d to my pickDoc(item 1 of argv)
        if d is missing value then return ""
        set isPlaying to false
        try
          set isPlaying to playing
        end try
        set n to count of slides of d
        if cmd is "start" then
          start d from slide 1 of d
        else if cmd is "starthere" then
          start d from current slide of d
        else if cmd is "end" then
          if isPlaying then stop d
        else if cmd is "next" then
          if isPlaying then
            show next
          else
            set i to my posOf(d)
            if i < n then set current slide of d to slide (i + 1) of d
          end if
        else if cmd is "prev" then
          if isPlaying then
            show previous
          else
            set i to my posOf(d)
            if i > 1 then set current slide of d to slide (i - 1) of d
          end if
        else if cmd is "goto" then
          if target < 1 then set target to 1
          if target > n then set target to n
          if isPlaying then
            show slide target of d
          else
            set current slide of d to slide target of d
          end if
        end if
        return "ok"
      end tell
    end run
    """

    // MARK: - SlideApp

    func pollState(selection: String, withList: Bool, _ completion: @escaping (PPTState?) -> Void) {
        guard isRunning else { return completion(PPTState(running: false)) }
        queue.async {
            let st = self.run(Self.stateScript, args: [selection, withList ? "1" : "0"]).map(self.parse)
            DispatchQueue.main.async { completion(st) }
        }
    }

    private func parse(_ out: String) -> PPTState {
        var st = PPTState(running: true)
        let f = out.components(separatedBy: Self.US)
        guard out != "NONE", f.count >= 6 else { return st }
        if f[4] != "-", f[4] != lastListRaw {
            lastListRaw = f[4]
            Log.write("Keynote: open presentations: \(f[4].replacingOccurrences(of: Self.GS, with: ", "))")
        }
        st.hasPresentation = true
        st.fullName = f[0]
        st.count = Int(f[1]) ?? 0
        st.index = Int(f[2]) ?? 1
        st.showing = f[3] == "1"
        if !st.showing || st.index != lastIndex { black = false }
        lastIndex = st.index
        st.black = black
        if st.showing { st.showBounds = Self.playWindowBounds() }
        if f[4] == "-" {
            st.listUnknown = true
        } else {
            let names = f[4].components(separatedBy: Self.GS), fulls = f[5].components(separatedBy: Self.GS)
            st.open = zip(names, fulls).map { OpenPresentation(name: $0.0, fullName: $0.1) }
        }
        return st
    }

    /// Keynote plays full screen; the window server knows where (Keynote's scripting doesn't).
    private static func playWindowBounds() -> CGRect {
        let screens = NSScreen.screens
        let primary = screens.first?.frame.height ?? 0
        let frames = screens.map { CGRect(x: $0.frame.minX, y: primary - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return frames.first ?? .zero
        }
        var best: CGRect?
        for w in list where (w[kCGWindowOwnerName as String] as? String)?.hasPrefix("Keynote") == true {
            guard let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d),
                  frames.contains(where: { abs($0.minX - b.minX) < 2 && abs($0.minY - b.minY) < 2 && abs($0.width - b.width) < 2 && abs($0.height - b.height) < 2 }) else { continue }
            let name = (w[kCGWindowName as String] as? String) ?? ""
            if name.localizedCaseInsensitiveContains("presenter") || name.localizedCaseInsensitiveContains("presentator") { continue }
            // With two screens Keynote's slide show goes to the other one (the presenter display stays on the Mac).
            if best == nil || (b.minX != 0 || b.minY != 0) { best = b }
        }
        return best ?? frames.first ?? .zero
    }

    func loadDeck(selection: String, _ completion: @escaping (DeckLoad?) -> Void) {
        guard isRunning else { return completion(nil) }
        queue.async {
            guard let out = self.run(Self.loadScript, args: [selection]), !out.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var parts = out.components(separatedBy: Self.RS)
            let fullName = parts.removeFirst()
            var hidden: [Bool] = [], notes: [String] = []
            for p in parts {
                let f = p.components(separatedBy: Self.US)
                hidden.append(f.first == "1")
                notes.append(f.dropFirst().joined(separator: Self.US).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            var pdfPath: String?
            for dir in PowerPoint.exportDirectories() {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let pdf = (dir as NSString).appendingPathComponent("keynote-slides.pdf")
                try? FileManager.default.removeItem(atPath: pdf)
                guard self.run(Self.exportScript, args: [selection, pdf]) != nil else { continue }
                if let data = try? Data(contentsOf: URL(fileURLWithPath: pdf)), data.count > 0 {
                    pdfPath = pdf
                    break
                }
            }
            if pdfPath == nil { Log.write("Keynote: could not export the slides as PDF") }
            let load = DeckLoad(fullName: fullName, hidden: hidden, notes: notes, sections: [], pdfPath: pdfPath)
            DispatchQueue.main.async { completion(load) }
        }
    }

    func notes(selection: String, for index: Int, _ completion: @escaping (String?) -> Void) {
        // Notes come with the deck load; nothing extra to fetch.
        completion(nil)
    }

    func richNotes(selection: String, for index: Int, _ completion: @escaping ([RichParagraph]?) -> Void) { completion(nil) }
    func mediaList(selection: String, _ completion: @escaping ([MediaItem]) -> Void) { completion([]) }
    func media(selection: String, _ cmd: String, shape: Int, value: Int, _ completion: @escaping (MediaStatus?) -> Void) { completion(nil) }

    func navigate(selection: String, _ cmd: String, target: Int, _ completion: @escaping (PPTState?) -> Void) {
        queue.async {
            var cmd = cmd
            var target = target
            switch cmd {
            case "first": cmd = "goto"; target = 1
            case "last": cmd = "goto"; target = 100_000
            case "black":
                self.toggleBlack()
                let st = self.run(Self.stateScript, args: [selection, "0"]).map(self.parse)
                DispatchQueue.main.async { completion(st) }
                return
            default: break
            }
            if self.black, cmd == "next" || cmd == "prev" {
                // Like PowerPoint: the first tap after a black screen only brings the slide back.
                self.toggleBlack()
            } else {
                _ = self.run(Self.navScript, args: [selection, cmd, String(target)])
            }
            if cmd == "start" || cmd == "starthere" || cmd == "end" { self.black = false }
            let st = self.run(Self.stateScript, args: [selection, "0"]).map(self.parse)
            DispatchQueue.main.async { completion(st) }
        }
    }

    /// Keynote's own shortcut: B blacks out the screen during the slide show (needs Accessibility).
    private func toggleBlack() {
        guard PowerPoint.canJumpDirectly,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.processIdentifier else {
            Log.write("Keynote black screen needs the Accessibility permission (menu › Enable Direct Slide Jumps…)")
            return
        }
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 11, keyDown: down) else { continue }
            let b = Array("b".utf16)
            e.keyboardSetUnicodeString(stringLength: b.count, unicodeString: b)
            e.postToPid(pid)
            usleep(12_000)
        }
        black.toggle()
    }

    // MARK: - Runner

    private func run(_ source: String, args: [String]) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        var script = compiled[source]
        if script == nil {
            var err: NSDictionary?
            guard let s = NSAppleScript(source: source), s.compileAndReturnError(&err) else {
                Log.write("Keynote AppleScript compile error: \(err ?? [:])")
                return nil
            }
            compiled[source] = s
            script = s
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { list.insert(NSAppleEventDescriptor(string: a), at: i + 1) }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        var err: NSDictionary?
        let result = script!.executeAppleEvent(event, error: &err)
        if let err {
            Log.write("Keynote AppleScript error: \(err[NSAppleScript.errorMessage] ?? err)")
            return nil
        }
        return result.stringValue ?? ""
    }
}
