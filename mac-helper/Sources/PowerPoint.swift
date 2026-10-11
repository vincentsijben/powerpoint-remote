import AppKit
import Foundation

struct PPTState: Equatable {
    var running = false
    var hasPresentation = false
    var fullName = ""
    var count = 0
    var index = 0
    var showing = false
    var black = false
}

struct DeckLoad {
    var fullName: String
    var hidden: [Bool]
    var notes: [String]
    var pdfPath: String?
}

/// Talks to Microsoft PowerPoint through AppleScript (compiled in-process) on a private serial queue.
final class PowerPoint {
    static let bundleID = "com.microsoft.Powerpoint"
    private let queue = DispatchQueue(label: "pptremote.powerpoint")
    private static let US = "\u{1F}"
    private static let RS = "\u{1E}"

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    // MARK: - Scripts

    private static let pickPresentation = """
        if (count of slide show windows) > 0 then
          set p to presentation of slide show window 1
        else
          set p to active presentation
        end if
    """

    private static let stateHandler = """
    on stateString()
      tell application "Microsoft PowerPoint"
        if (count of presentations) = 0 then return "NONE"
        set showing to "0"
        set blk to "0"
        set idx to 0
        if (count of slide show windows) > 0 then
          set w to slide show window 1
          set p to presentation of w
          set showing to "1"
          try
            set v to slideshow view of w
            set idx to slide index of slide of v
            if slide state of v is slide show state black screen then set blk to "1"
          end try
        else
          set p to active presentation
          try
            set idx to slide index of slide of view of document window 1
          end try
        end if
        set US to character id 31
        return (full name of p) & US & (count of slides of p) & US & idx & US & showing & US & blk
      end tell
    end stateString
    """

    private static let stateScript = """
    \(stateHandler)
    on run
      return stateString()
    end run
    """

    private static let notesHandler = """
    on notesOf(s)
      tell application "Microsoft PowerPoint"
        try
          set np to notes page of s
          repeat with k from 1 to (count of place holders of np)
            set ph to place holder k of np
            if placeholder type of placeholder format of ph is placeholder type body placeholder then
              return content of text range of text frame of ph
            end if
          end repeat
        end try
      end tell
      return ""
    end notesOf
    """

    private static let loadScript = """
    \(notesHandler)
    on run
      tell application "Microsoft PowerPoint"
        \(pickPresentation)
        set US to character id 31
        set RS to character id 30
        set acc to (full name of p)
        set n to count of slides of p
        repeat with i from 1 to n
          set s to slide i of p
          set h to "0"
          try
            if hidden of slide show transition of s then set h to "1"
          end try
          set acc to acc & RS & h & US & my notesOf(s)
        end repeat
        return acc
      end tell
    end run
    """

    private static let exportScript = """
    on run argv
      set pdfFile to POSIX file (item 1 of argv)
      tell application "Microsoft PowerPoint"
        \(pickPresentation)
        save p in pdfFile as save as PDF
      end tell
      return "OK"
    end run
    """

    private static let singleNoteScript = """
    \(notesHandler)
    on run argv
      set i to (item 1 of argv) as integer
      tell application "Microsoft PowerPoint"
        \(pickPresentation)
        if i > (count of slides of p) then return ""
        return my notesOf(slide i of p)
      end tell
    end run
    """

    private static let navScript = """
    \(stateHandler)
    on run argv
      set cmd to item 1 of argv
      set target to 0
      if (count of argv) > 1 then set target to (item 2 of argv) as integer
      tell application "Microsoft PowerPoint"
        if (count of presentations) = 0 then return "NONE"
        if (count of slide show windows) > 0 then
          set v to slideshow view of slide show window 1
          if cmd is "next" then
            go to next slide v
          else if cmd is "prev" then
            go to previous slide v
          else if cmd is "first" then
            go to first slide v
          else if cmd is "last" then
            go to last slide v
          else if cmd is "goto" then
            repeat 400 times
              set cur to slide index of slide of v
              if cur = target then exit repeat
              if cur < target then
                go to next slide v
              else
                go to previous slide v
              end if
            end repeat
          else if cmd is "end" then
            exit slide show v
          else if cmd is "black" then
            if slide state of v is slide show state black screen then
              set slide state of v to slide show state running
            else
              set slide state of v to slide show state black screen
            end if
          end if
        else
          set p to active presentation
          set n to count of slides of p
          set cur to 1
          try
            set cur to slide index of slide of view of document window 1
          end try
          if cmd is "start" or cmd is "starthere" then
            run slide show slide show settings of p
            if cmd is "starthere" and cur > 1 then
              delay 0.6
              set v to slideshow view of slide show window 1
              repeat 400 times
                set c2 to slide index of slide of v
                if c2 ≥ cur then exit repeat
                go to next slide v
              end repeat
            end if
          else
            set dest to cur
            if cmd is "next" then set dest to cur + 1
            if cmd is "prev" then set dest to cur - 1
            if cmd is "first" then set dest to 1
            if cmd is "last" then set dest to n
            if cmd is "goto" then set dest to target
            if dest < 1 then set dest to 1
            if dest > n then set dest to n
            if dest is not cur then go to slide view of document window 1 number dest
          end if
        end if
      end tell
      return my stateString()
    end run
    """

    // MARK: - Public API (completions are called on the main queue)

    /// Completion receives nil when PowerPoint could not be queried (keep the previous state then).
    func pollState(_ completion: @escaping (PPTState?) -> Void) {
        guard isRunning else {
            completion(PPTState())
            return
        }
        queue.async {
            let st = self.run(Self.stateScript, args: []).map(Self.parseState)
            DispatchQueue.main.async { completion(st) }
        }
    }

    private static func parseState(_ out: String) -> PPTState {
        var st = PPTState(running: true)
        let f = out.components(separatedBy: US)
        if out != "NONE", f.count >= 5 {
            st.hasPresentation = true
            st.fullName = f[0]
            st.count = Int(f[1]) ?? 0
            st.index = Int(f[2]) ?? 0
            st.showing = f[3] == "1"
            st.black = f[4] == "1"
        }
        return st
    }

    func loadDeck(_ completion: @escaping (DeckLoad?) -> Void) {
        guard isRunning else {
            completion(nil)
            return
        }
        queue.async {
            guard let out = self.run(Self.loadScript, args: []) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var parts = out.components(separatedBy: Self.RS)
            let fullName = parts.removeFirst()
            var hidden: [Bool] = []
            var notes: [String] = []
            for p in parts {
                let f = p.components(separatedBy: Self.US)
                hidden.append(f.first == "1")
                notes.append(Self.cleanNotes(f.dropFirst().joined(separator: Self.US)))
            }
            var pdfPath: String?
            for dir in Self.exportDirectories() {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let pdf = (dir as NSString).appendingPathComponent("slides.pdf")
                try? FileManager.default.removeItem(atPath: pdf)
                guard self.run(Self.exportScript, args: [pdf]) != nil else { continue }
                // PowerPoint may be able to write somewhere this app cannot read (sandbox / privacy rules).
                if let data = try? Data(contentsOf: URL(fileURLWithPath: pdf)), data.count > 0 {
                    pdfPath = pdf
                    break
                }
                Log.write("Exported PDF not readable at \(pdf)")
            }
            let result = DeckLoad(fullName: fullName, hidden: hidden, notes: notes, pdfPath: pdfPath)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func notes(for index: Int, _ completion: @escaping (String?) -> Void) {
        guard isRunning else { completion(nil); return }
        queue.async {
            let out = self.run(Self.singleNoteScript, args: [String(index)])
            DispatchQueue.main.async { completion(out.map(Self.cleanNotes)) }
        }
    }

    /// cmd: next, prev, first, last, goto, start, starthere, end, black.
    /// Completion receives the PowerPoint state right after the command.
    func navigate(_ cmd: String, target: Int = 0, _ completion: @escaping (PPTState?) -> Void) {
        guard isRunning else { completion(nil); return }
        queue.async {
            if cmd == "goto", let st = self.jumpDirectly(to: target) {
                DispatchQueue.main.async { completion(st) }
                return
            }
            let st = self.run(Self.navScript, args: [cmd, String(target)]).map(Self.parseState)
            DispatchQueue.main.async { completion(st) }
        }
    }

    // MARK: - Direct jump (slide show)

    /// Posting key events needs the Accessibility permission.
    static var canJumpDirectly: Bool { AXIsProcessTrusted() }

    static func requestJumpPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static var askedForPermission = false

    /// In a running slide show, AppleScript can only step slide by slide (the audience sees every slide
    /// in between). Typing the slide number + Return jumps straight there, so send those keys to PowerPoint.
    /// Returns nil when this is not possible, so the caller falls back to stepping.
    private func jumpDirectly(to target: Int) -> PPTState? {
        guard target >= 1, let before = run(Self.stateScript, args: []).map(Self.parseState),
              before.showing, before.index != target else { return nil }
        guard Self.canJumpDirectly else {
            if !Self.askedForPermission {
                Self.askedForPermission = true
                Log.write("Direct slide jumps need Accessibility permission; stepping instead")
                DispatchQueue.main.async { Self.requestJumpPermission() }
            }
            return nil
        }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.processIdentifier
        else { return nil }
        let src = CGEventSource(stateID: .privateState)
        let digitKeys: [Character: CGKeyCode] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]
        func tap(_ code: CGKeyCode, _ char: Character?) {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
                if let char {
                    // Set the character too, so non-US keyboard layouts (e.g. AZERTY) still type digits.
                    let utf16 = Array(String(char).utf16)
                    e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                }
                e.postToPid(pid)
                usleep(12_000)
            }
        }
        for c in String(target) { if let k = digitKeys[c] { tap(k, c) } }
        tap(36, nil)
        for _ in 0..<12 {
            usleep(80_000)
            if let st = run(Self.stateScript, args: []).map(Self.parseState), st.index == target || !st.showing {
                Log.write("Jumped directly to slide \(target)")
                return st
            }
        }
        Log.write("Direct jump to slide \(target) did not work; stepping instead")
        return nil
    }

    // MARK: - Helpers

    private static func exportDirectories() -> [String] {
        let home = NSHomeDirectory()
        // PowerPoint is sandboxed: try a folder we own first, then PowerPoint's own container
        // (always writable for PowerPoint, but reading it may need "access data from other apps").
        return [
            "\(home)/Library/Caches/PPTRemote",
            (NSTemporaryDirectory() as NSString).appendingPathComponent("PPTRemote"),
            "\(home)/Library/Containers/com.microsoft.Powerpoint/Data/Library/Caches/PPTRemote",
        ]
    }

    private static func cleanNotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0B}", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compiled scripts, only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]

    /// Runs an AppleScript in-process (much faster than spawning osascript) and returns its
    /// result as text, or nil on failure. Must be called on `queue`.
    private func run(_ source: String, args: [String]) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        var script = compiled[source]
        if script == nil {
            var err: NSDictionary?
            guard let s = NSAppleScript(source: source), s.compileAndReturnError(&err) else {
                Log.write("AppleScript compile error: \(err ?? [:])")
                return nil
            }
            compiled[source] = s
            script = s
        }
        // A 'run' event with a list as direct parameter becomes `argv` in the run handler.
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { list.insert(NSAppleEventDescriptor(string: a), at: i + 1) }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        var err: NSDictionary?
        let result = script!.executeAppleEvent(event, error: &err)
        if let err {
            let msg = err[NSAppleScript.errorMessage] ?? err
            Log.write("AppleScript error: \(msg)")
            return nil
        }
        return result.stringValue ?? ""
    }
}
