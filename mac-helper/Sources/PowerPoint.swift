import AppKit
import Foundation

struct OpenPresentation: Equatable {
    var name: String
    var fullName: String
}

struct PPTState: Equatable {
    var running = false
    var hasPresentation = false
    var fullName = ""
    var count = 0
    var index = 0
    var showing = false
    var black = false
    /// Slide show window in screen points, top-left origin of the primary screen (AppleScript coordinates).
    var showBounds = CGRect.zero
    var open: [OpenPresentation] = []
    /// True when this poll did not read the list (keep the previous one).
    var listUnknown = false
}

struct Section: Equatable {
    var name: String
    var first: Int
    var count: Int
}

struct DeckLoad {
    var fullName: String
    var hidden: [Bool]
    var notes: [String]
    var sections: [Section]
    var pdfPath: String?
}

/// One paragraph of formatted speaker notes.
struct RichParagraph {
    var level: Int
    var bullet: String // "" none, "*" bullet, "#" numbered
    var bulletText: String
    var runs: [(text: String, style: String)] // style: "b", "i", "u" letters plus optional "#rrggbb"
}

struct MediaItem: Equatable {
    var shape: Int
    var name: String
    var kind: String // movie | sound
}

struct MediaStatus: Equatable {
    var shape: Int
    var state: String // playing | paused | stopped | notready
    var position: Int // ms
}

/// Talks to Microsoft PowerPoint through AppleScript (compiled in-process) on a private serial queue.
/// Every script gets the full name of the selected presentation ("" = follow PowerPoint) as first argument.
final class PowerPoint {
    static let bundleID = "com.microsoft.Powerpoint"
    /// NSAppleScript isn't thread-safe: every in-process script (PowerPoint and Keynote) runs on this one queue.
    static let scriptQueue = DispatchQueue(label: "pptremote.applescript")
    private let queue = PowerPoint.scriptQueue
    private static let US = "\u{1F}"
    private static let RS = "\u{1E}"
    private static let GS = "\u{1D}"
    private static let FS = "\u{1C}"

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    // MARK: - Scripts

    /// Shared handlers. Note: `repeat with p in presentations` can hang PowerPoint, so loops use indexes.
    private static let common = """
    on pickPres(sel)
      tell application "Microsoft PowerPoint"
        if (count of presentations) = 0 then return missing value
        if sel is not "" then
          repeat with i from 1 to (count of presentations)
            if full name of presentation i is sel then return presentation i
          end repeat
        end if
        if (count of slide show windows) > 0 then return presentation of slide show window 1
        return active presentation
      end tell
    end pickPres

    on showWin(p, sel)
      tell application "Microsoft PowerPoint"
        set n to count of slide show windows
        if n = 0 then return missing value
        -- Following PowerPoint: the presentation was taken from slide show window 1.
        if sel is "" then return slide show window 1
        set fn to full name of p
        repeat with i from 1 to n
          if full name of presentation of slide show window i is fn then return slide show window i
        end repeat
      end tell
      return missing value
    end showWin

    on docWin(p, sel)
      tell application "Microsoft PowerPoint"
        set n to count of document windows
        if n = 0 then return missing value
        -- Following PowerPoint: the active presentation is the one in the front window.
        if sel is "" then return document window 1
        set fn to full name of p
        repeat with i from 1 to n
          if full name of presentation of document window i is fn then return document window i
        end repeat
      end tell
      return missing value
    end docWin

    on joinList(lst, d)
      set AppleScript's text item delimiters to d
      set t to lst as text
      set AppleScript's text item delimiters to ""
      return t
    end joinList

    on stateString(sel, wantList)
      tell application "Microsoft PowerPoint"
        if (count of presentations) = 0 then return "NONE"
        set US to character id 31
        set GS to character id 29
        set pnames to "-"
        set pfulls to "-"
        if wantList is "1" then
          set pnames to my joinList(name of every presentation, GS)
          set pfulls to my joinList(full name of every presentation, GS)
        end if
        set p to my pickPres(sel)
        set showing to "0"
        set blk to "0"
        set idx to 0
        set bnds to "0" & US & "0" & US & "0" & US & "0"
        set w to my showWin(p, sel)
        if w is not missing value then
          set showing to "1"
          try
            set v to slideshow view of w
            set idx to slide index of slide of v
            if slide state of v is slide show state black screen then set blk to "1"
          end try
          try
            set bnds to ((left position of w) as text) & US & ((top of w) as text) & US & ((width of w) as text) & US & ((height of w) as text)
          end try
        else
          set dw to my docWin(p, sel)
          if dw is not missing value then
            try
              set idx to slide index of slide of view of dw
            end try
          end if
        end if
        return (full name of p) & US & (count of slides of p) & US & idx & US & showing & US & blk & US & bnds & US & pnames & US & pfulls
      end tell
    end stateString

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

    private static let stateScript = """
    \(common)
    on run argv
      with timeout of 8 seconds
        return my stateString(item 1 of argv, item 2 of argv)
      end timeout
    end run
    """

    private static let loadScript = """
    \(common)
    on run argv
      with timeout of 120 seconds
        tell application "Microsoft PowerPoint"
          set p to my pickPres(item 1 of argv)
          set US to character id 31
          set RS to character id 30
          set GS to character id 29
          set secs to ""
          try
            set sp to section properties of p
            set nsec to get count of sections of sp
            repeat with i from 1 to nsec
              set secs to secs & (get name of section sp at position i) & US & (get first slide of section sp at position i) & US & (get slide count of section sp at position i) & GS
            end repeat
          end try
          set acc to (full name of p) & RS & secs
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
      end timeout
    end run
    """

    private static let exportScript = """
    \(common)
    on run argv
      with timeout of 180 seconds
        set pdfFile to POSIX file (item 2 of argv)
        tell application "Microsoft PowerPoint"
          set p to my pickPres(item 1 of argv)
          save p in pdfFile as save as PDF
        end tell
      end timeout
      return "OK"
    end run
    """

    private static let singleNoteScript = """
    \(common)
    on run argv
      with timeout of 8 seconds
        set i to (item 2 of argv) as integer
        tell application "Microsoft PowerPoint"
          set p to my pickPres(item 1 of argv)
          if i > (count of slides of p) then return ""
          return my notesOf(slide i of p)
        end tell
      end timeout
    end run
    """

    /// Formatted notes of one slide: paragraphs (RS) of level US bullet US bulletText US content US runs,
    /// runs (GS) of text FS style. Words are read one by one (PowerPoint has no "runs"), so this is slow-ish.
    private static let richNotesScript = """
    \(common)
    on hex2(n)
      set d to "0123456789abcdef"
      return (character ((n div 16) + 1) of d) & (character ((n mod 16) + 1) of d)
    end hex2

    on run argv
      with timeout of 30 seconds
        set i to (item 2 of argv) as integer
        tell application "Microsoft PowerPoint"
          set US to character id 31
          set RS to character id 30
          set GS to character id 29
          set FS to character id 28
          set p to my pickPres(item 1 of argv)
          if i > (count of slides of p) then return ""
          set np to notes page of slide i of p
          set tr to missing value
          repeat with k from 1 to (count of place holders of np)
            set ph to place holder k of np
            if placeholder type of placeholder format of ph is placeholder type body placeholder then set tr to text range of text frame of ph
          end repeat
          if tr is missing value then return ""
          set npar to count of paragraphs of tr
          if npar > 80 then return "TOOLONG"
          set acc to ""
          repeat with qi from 1 to npar
            set pr to paragraph qi of tr
            set lvl to 1
            try
              set lvl to indent level of pr
            end try
            set bk to ""
            set bch to ""
            try
              set bf to bullet format of paragraph format of pr
              if visible of bf then
                if bullet type of bf is bullet type numbered then
                  set bk to "#"
                  set bch to (bullet number of bf) as text
                else if bullet type of bf is bullet type unnumbered then
                  set bk to "*"
                  set bch to bullet character of bf
                end if
              end if
            end try
            set runs to ""
            set pc to content of pr
            set pstl to ""
            set mixed to true
            try
              -- A paragraph reports bold/italic/underline when any part has it; plain paragraphs need no word scan.
              set fpp to properties of font of pr
              set mixed to (bold of fpp) or (italic of fpp) or (underline of fpp)
              set c to font color of fpp
              if (count of c) = 3 then
                if not ((item 1 of c) = 0 and (item 2 of c) = 0 and (item 3 of c) = 0) then
                  set pstl to "#" & my hex2(item 1 of c) & my hex2(item 2 of c) & my hex2(item 3 of c)
                end if
              end if
            end try
            set nw to 0
            if mixed then set nw to count of words of pr
            if nw > 400 then return "TOOLONG"
            if not mixed then set runs to pc & FS & pstl & GS
            repeat with j from 1 to nw
              set wd to word j of pr
              set fp to properties of font of wd
              set stl to ""
              try
                if bold of fp then set stl to stl & "b"
              end try
              try
                if italic of fp then set stl to stl & "i"
              end try
              try
                if underline of fp then set stl to stl & "u"
              end try
              try
                set c to font color of fp
                if (count of c) = 3 then
                  if not ((item 1 of c) = 0 and (item 2 of c) = 0 and (item 3 of c) = 0) then
                    set stl to stl & "#" & my hex2(item 1 of c) & my hex2(item 2 of c) & my hex2(item 3 of c)
                  end if
                end if
              end try
              set runs to runs & (content of wd) & FS & stl & GS
            end repeat
            set acc to acc & lvl & US & bk & US & bch & US & pc & US & runs & RS
          end repeat
          return acc
        end tell
      end timeout
    end run
    """

    /// Video/audio on the current slide of the running show. argv: sel, cmd, shape, value
    private static let mediaScript = """
    \(common)
    on run argv
      with timeout of 8 seconds
        set cmd to item 2 of argv
        set k to (item 3 of argv) as integer
        set val to (item 4 of argv) as integer
        tell application "Microsoft PowerPoint"
          set US to character id 31
          set GS to character id 29
          set p to my pickPres(item 1 of argv)
          set w to my showWin(p, item 1 of argv)
          if w is missing value then return ""
          set v to slideshow view of w
          set s to slide of v
          if cmd is "list" then
            set acc to ""
            repeat with i from 1 to (count of shapes of s)
              set sh to shape i of s
              try
                if shape type of sh is shape type media then
                  set mk to "movie"
                  try
                    if media type of sh is media type sound then set mk to "sound"
                  end try
                  set acc to acc & i & US & (name of sh) & US & mk & GS
                end if
              end try
            end repeat
            return acc
          end if
          set pl to get player from v for (shape k of s)
          if cmd is "play" then
            play player pl
          else if cmd is "pause" then
            pause player pl
          else if cmd is "stop" then
            stop player pl
          else if cmd is "seek" then
            set current position of pl to val
          else if cmd is "rel" then
            set np to (current position of pl) + val
            if np < 0 then set np to 0
            set current position of pl to np
          end if
          set ps to player state of pl
          set stx to "stopped"
          if ps is player state playing then set stx to "playing"
          if ps is player state paused then set stx to "paused"
          if ps is player state not ready then set stx to "notready"
          return stx & US & (current position of pl)
        end tell
      end timeout
    end run
    """

    private static let navScript = """
    \(common)
    on run argv
      with timeout of 30 seconds
        set sel to item 1 of argv
        set cmd to item 2 of argv
        set target to (item 3 of argv) as integer
        tell application "Microsoft PowerPoint"
          set p to my pickPres(sel)
          if p is missing value then return "NONE"
          set w to my showWin(p, sel)
          if w is not missing value then
            set v to slideshow view of w
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
            set n to count of slides of p
            set dw to my docWin(p, sel)
            set cur to 1
            try
              set cur to slide index of slide of view of dw
            end try
            if cmd is "start" or cmd is "starthere" then
              run slide show slide show settings of p
              if cmd is "starthere" and cur > 1 then
                delay 0.6
                set w to my showWin(p, sel)
                if w is not missing value then
                  set v to slideshow view of w
                  repeat 400 times
                    set c2 to slide index of slide of v
                    if c2 ≥ cur then exit repeat
                    go to next slide v
                  end repeat
                end if
              end if
            else if dw is not missing value then
              set dest to cur
              if cmd is "next" then set dest to cur + 1
              if cmd is "prev" then set dest to cur - 1
              if cmd is "first" then set dest to 1
              if cmd is "last" then set dest to n
              if cmd is "goto" then set dest to target
              if dest < 1 then set dest to 1
              if dest > n then set dest to n
              if dest is not cur then go to slide view of dw number dest
            end if
          end if
        end tell
        return my stateString(sel, "0")
      end timeout
    end run
    """

    // MARK: - Public API (completions are called on the main queue)

    /// Completion receives nil when PowerPoint could not be queried (keep the previous state then).
    /// The list of open presentations is only read when `withList` is true (it rarely changes).
    func pollState(selection: String, withList: Bool, _ completion: @escaping (PPTState?) -> Void) {
        guard isRunning else {
            completion(PPTState())
            return
        }
        queue.async {
            let st = self.run(Self.stateScript, args: [selection, withList ? "1" : "0"]).map(Self.parseState)
            DispatchQueue.main.async { completion(st) }
        }
    }

    private static func parseState(_ out: String) -> PPTState {
        var st = PPTState(running: true)
        let f = out.components(separatedBy: US)
        guard out != "NONE", f.count >= 11 else { return st }
        st.hasPresentation = true
        st.fullName = f[0]
        st.count = Int(f[1]) ?? 0
        st.index = Int(f[2]) ?? 0
        st.showing = f[3] == "1"
        st.black = f[4] == "1"
        let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        st.showBounds = CGRect(x: num(f[5]), y: num(f[6]), width: num(f[7]), height: num(f[8]))
        if st.showing { st.showBounds = Self.realShowBounds(reported: st.showBounds, deck: (st.fullName as NSString).lastPathComponent) }
        if f[9] == "-" {
            st.listUnknown = true
        } else {
            let names = f[9].components(separatedBy: GS)
            let fulls = f[10].components(separatedBy: GS)
            st.open = zip(names, fulls).map { OpenPresentation(name: $0, fullName: $1) }
        }
        return st
    }

    func loadDeck(selection: String, _ completion: @escaping (DeckLoad?) -> Void) {
        guard isRunning else {
            completion(nil)
            return
        }
        queue.async {
            guard let out = self.run(Self.loadScript, args: [selection]) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var parts = out.components(separatedBy: Self.RS)
            let fullName = parts.removeFirst()
            let sections: [Section] = parts.isEmpty ? [] : parts.removeFirst().components(separatedBy: Self.GS).compactMap {
                let f = $0.components(separatedBy: Self.US)
                guard f.count >= 3, let first = Int(f[1]), let count = Int(f[2]) else { return nil }
                return Section(name: f[0], first: first, count: count)
            }
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
                guard self.run(Self.exportScript, args: [selection, pdf]) != nil else { continue }
                // PowerPoint may be able to write somewhere this app cannot read (sandbox / privacy rules).
                if let data = try? Data(contentsOf: URL(fileURLWithPath: pdf)), data.count > 0 {
                    pdfPath = pdf
                    break
                }
                Log.write("Exported PDF not readable at \(pdf)")
            }
            let result = DeckLoad(fullName: fullName, hidden: hidden, notes: notes, sections: sections, pdfPath: pdfPath)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func notes(selection: String, for index: Int, _ completion: @escaping (String?) -> Void) {
        guard isRunning else { completion(nil); return }
        queue.async {
            let out = self.run(Self.singleNoteScript, args: [selection, String(index)])
            DispatchQueue.main.async { completion(out.map(Self.cleanNotes)) }
        }
    }

    /// Returns nil on failure, [] when the notes have no formatting worth showing.
    /// Runs in a separate osascript process: PowerPoint then interleaves these many small requests with
    /// navigation commands, instead of making Next/Prev wait for the whole slide.
    func richNotes(selection: String, for index: Int, _ completion: @escaping ([RichParagraph]?) -> Void) {
        guard isRunning else { completion(nil); return }
        richQueue.async {
            let out = Self.osascript(Self.richNotesScript, args: [selection, String(index)], timeout: 40)
            let result = out.map(Self.parseRich)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private let richQueue = DispatchQueue(label: "pptremote.richnotes", qos: .utility)

    private static func osascript(_ source: String, args: [String], timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { return nil }
        var outData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            Log.write("osascript timed out")
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Log.write("osascript error: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }
        var s = String(data: outData, encoding: .utf8) ?? ""
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    private static func parseRich(_ out: String) -> [RichParagraph] {
        if out.isEmpty || out == "TOOLONG" { return [] }
        var paras: [RichParagraph] = []
        for p in out.components(separatedBy: RS) where !p.isEmpty {
            let f = p.components(separatedBy: US)
            guard f.count >= 5 else { continue }
            var runs: [(String, String)] = []
            for r in f[4].components(separatedBy: GS) where !r.isEmpty {
                let parts = r.components(separatedBy: FS)
                let text = parts[0].replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\u{0B}", with: "\n")
                let style = parts.count > 1 ? parts[1] : ""
                if let last = runs.last, last.1 == style {
                    runs[runs.count - 1].0 += text
                } else {
                    runs.append((text, style))
                }
            }
            let content = f[3].replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\u{0B}", with: "\n")
            // Words should add up to the paragraph; if not, fall back to the paragraph text without formatting.
            let joined = runs.map(\.0).joined()
            if joined.trimmingCharacters(in: .whitespacesAndNewlines) != content.trimmingCharacters(in: .whitespacesAndNewlines) {
                runs = [(content, "")]
            }
            paras.append(RichParagraph(level: max(1, Int(f[0]) ?? 1), bullet: f[1], bulletText: f[2],
                                       runs: runs.map { (text: $0.0, style: $0.1) }))
        }
        // Drop a trailing empty paragraph.
        while let last = paras.last, last.runs.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }), last.bullet.isEmpty {
            paras.removeLast()
        }
        let hasFormatting = paras.contains { !$0.bullet.isEmpty || $0.level > 1 || $0.runs.contains { !$0.style.isEmpty } }
        return hasFormatting ? paras : []
    }

    func mediaList(selection: String, _ completion: @escaping ([MediaItem]) -> Void) {
        guard isRunning else { completion([]); return }
        queue.async {
            let out = self.run(Self.mediaScript, args: [selection, "list", "0", "0"]) ?? ""
            let items: [MediaItem] = out.components(separatedBy: Self.GS).compactMap {
                let f = $0.components(separatedBy: Self.US)
                guard f.count >= 3, let k = Int(f[0]) else { return nil }
                return MediaItem(shape: k, name: f[1], kind: f[2])
            }
            DispatchQueue.main.async { completion(items) }
        }
    }

    /// cmd: status, play, pause, stop, seek (value = ms), rel (value = ±ms)
    func media(selection: String, _ cmd: String, shape: Int, value: Int = 0, _ completion: @escaping (MediaStatus?) -> Void) {
        guard isRunning else { completion(nil); return }
        queue.async {
            let out = self.run(Self.mediaScript, args: [selection, cmd, String(shape), String(value)])
            let st: MediaStatus? = out.flatMap {
                let f = $0.components(separatedBy: Self.US)
                guard f.count >= 2 else { return nil }
                return MediaStatus(shape: shape, state: f[0], position: Int(f[1]) ?? 0)
            }
            DispatchQueue.main.async { completion(st) }
        }
    }

    /// cmd: next, prev, first, last, goto, start, starthere, end, black.
    /// Completion receives the PowerPoint state right after the command.
    func navigate(selection: String, _ cmd: String, target: Int = 0, _ completion: @escaping (PPTState?) -> Void) {
        guard isRunning else { completion(nil); return }
        queue.async {
            if cmd == "goto", let st = self.jumpDirectly(selection: selection, to: target) {
                DispatchQueue.main.async { completion(st) }
                return
            }
            let st = self.run(Self.navScript, args: [selection, cmd, String(target)]).map(Self.parseState)
            DispatchQueue.main.async { completion(st) }
        }
    }

    // MARK: - Direct jump (slide show)

    /// Posting key events needs the Accessibility permission.
    /// PowerPoint reports the slide show window's position without the offset of the screen it's on, so on
    /// a second screen (projector) the overlay and the recording would end up on the wrong screen. The window
    /// server knows the real position: use the PowerPoint window of the same size (not Presenter View).
    static func realShowBounds(reported r: CGRect, deck: String) -> CGRect {
        guard r.width > 10, r.height > 10,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return r }
        var best: (CGRect, Int)?
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Microsoft PowerPoint" {
            guard let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d),
                  abs(b.width - r.width) < 2, abs(b.height - r.height) < 2 else { continue }
            let name = (w[kCGWindowName as String] as? String) ?? ""
            var score = 1
            if name.localizedCaseInsensitiveContains("presenter") || name.localizedCaseInsensitiveContains("presentator") { score = 0 }
            if !deck.isEmpty, name.contains((deck as NSString).deletingPathExtension) { score += 1 }
            if b.origin == r.origin { score += 1 }
            if best == nil || score > best!.1 { best = (b, score) }
        }
        guard let found = best?.0, found.origin != r.origin else { return r }
        return found
    }

    static var canJumpDirectly: Bool { AXIsProcessTrusted() }

    static func requestJumpPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static var askedForPermission = false

    /// In a running slide show, AppleScript can only step slide by slide (the audience sees every slide
    /// in between). Typing the slide number + Return jumps straight there, so send those keys to PowerPoint.
    /// Returns nil when this is not possible, so the caller falls back to stepping.
    private func jumpDirectly(selection: String, to target: Int) -> PPTState? {
        guard target >= 1, let before = run(Self.stateScript, args: [selection, "0"]).map(Self.parseState),
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
            if let st = run(Self.stateScript, args: [selection, "0"]).map(Self.parseState), st.index == target || !st.showing {
                Log.write("Jumped directly to slide \(target)")
                return st
            }
        }
        Log.write("Direct jump to slide \(target) did not work; stepping instead")
        return nil
    }

    // MARK: - Helpers

    static func exportDirectories() -> [String] {
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
