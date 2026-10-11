import AppKit
import AVFoundation
import CryptoKit

/// Plays short sounds (applause, drum roll, …) on the Mac when a remote asks for it.
/// Built-in sounds live in the app bundle; extra ones can be dropped into the Sounds folder.
final class SoundBoard {
    struct Sound {
        var id: String
        var name: String
        var icon: String
        var url: URL
    }

    private static let builtIn: [(file: String, name: String, icon: String)] = [
        ("applause", "Applause", "👏"),
        ("drumroll", "Drum roll", "🥁"),
        ("correct", "Correct!", "✅"),
        ("wrong", "Wrong", "❌"),
        ("tada", "Ta-da!", "🎉"),
        ("sad-trombone", "Sad trombone", "🎺"),
        ("crickets", "Crickets", "🦗"),
        ("gong", "Gong", "🔔"),
    ]
    private static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "aac", "caf", "mp4"]

    static var userFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PPT Remote/Sounds", isDirectory: true)
    }

    private(set) var sounds: [Sound] = []
    /// Changes whenever the list changes, so remotes know when to fetch it again.
    private(set) var listKey = ""
    private var players: [AVAudioPlayer] = []
    private var timer: Timer?

    var volume: Float {
        get { UserDefaults.standard.object(forKey: "soundVolume") as? Float ?? 0.8 }
        set { UserDefaults.standard.set(min(1, max(0, newValue)), forKey: "soundVolume") }
    }

    var onChange: (() -> Void)?

    func start() {
        try? FileManager.default.createDirectory(at: Self.userFolder, withIntermediateDirectories: true)
        reload()
        // Pick up sounds added to (or removed from) the folder.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reload() }
    }

    func reload() {
        var list: [Sound] = []
        let bundleDir = Bundle.main.resourceURL?.appendingPathComponent("Sounds")
        for b in Self.builtIn {
            if let url = bundleDir?.appendingPathComponent("\(b.file).m4a"), FileManager.default.fileExists(atPath: url.path) {
                list.append(Sound(id: "b:\(b.file)", name: b.name, icon: b.icon, url: url))
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.userFolder, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        where Self.audioExtensions.contains(url.pathExtension.lowercased()) {
            let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            list.append(Sound(id: "u:\(url.lastPathComponent)", name: name, icon: "🔊", url: url))
        }
        let key = SHA256.hash(data: Data(list.map { "\($0.id)|\($0.name)" }.joined(separator: "\n").utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        if key != listKey {
            sounds = list
            listKey = key
            Log.write("Soundboard: \(list.count) sounds")
            onChange?()
        }
    }

    func play(_ id: String) {
        guard let s = sounds.first(where: { $0.id == id }) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: s.url)
            p.volume = volume
            p.prepareToPlay()
            p.play()
            players.removeAll { !$0.isPlaying }
            players.append(p)
            Log.write("Sound: \(s.name)")
        } catch {
            Log.write("Could not play \(s.name): \(error.localizedDescription)")
        }
    }

    func stopAll() {
        players.forEach { $0.stop() }
        players.removeAll()
    }

    func setVolume(_ v: Float) {
        volume = v
        players.forEach { $0.volume = volume }
    }

    func listObject() -> [String: Any] {
        [
            "type": "sounds",
            "key": listKey,
            "vol": volume,
            "list": sounds.map { ["id": $0.id, "name": $0.name, "icon": $0.icon] },
        ]
    }
}
