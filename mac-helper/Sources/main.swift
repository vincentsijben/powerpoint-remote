import AppKit
import CoreImage
import ServiceManagement

/// Menu bar app: shows connection status, the PIN, and the network address (with QR code).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hub = Hub.shared
    private var ble: BLEServer!
    private var http: HTTPServer!
    private var statusItem: NSStatusItem!
    private var lastConnected = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        let webRoot = Bundle.main.resourceURL!.appendingPathComponent("web")
        http = HTTPServer(hub: hub, webRoot: webRoot)
        http.start(preferredPort: 8765)
        ble = BLEServer(hub: hub)
        hub.hasClients = { [weak self] in
            guard let self else { return false }
            return self.ble.connectedCount + self.http.connectedCount > 0
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        ble.onStatusChange = { [weak self] in self?.updateIcon() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateIcon() }
        hub.start()
        Log.write("PPT Remote started. PIN \(hub.pin). Direct slide jumps: \(PowerPoint.canJumpDirectly ? "on" : "off (needs Accessibility)")")
    }

    private func updateIcon() {
        let connected = ble.connectedCount + http.connectedCount
        guard connected != lastConnected else { return }
        lastConnected = connected
        let symbol = connected > 0 ? "dot.radiowaves.left.and.right" : "rectangle.on.rectangle"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "PPT Remote")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.title = connected > 0 ? " \(connected)" : ""
        statusItem.button?.imagePosition = .imageLeading
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = hub.state
        let pptLine: String
        if !st.running {
            pptLine = "PowerPoint is not running"
        } else if !st.hasPresentation {
            pptLine = "No presentation open"
        } else {
            pptLine = "\(hub.deckName) — slide \(st.index)/\(st.count)\(st.showing ? " (presenting)" : "")\(hub.loading ? " — loading…" : "")"
        }
        addInfo(menu, pptLine)
        addInfo(menu, ble.status)
        if PowerPoint.canJumpDirectly {
            addInfo(menu, "Direct slide jumps: on")
        } else {
            addAction(menu, "Enable Direct Slide Jumps… (Accessibility)", #selector(enableJumps))
        }
        addInfo(menu, "PIN: \(hub.pin)", bold: true)
        menu.addItem(.separator())

        let addresses = HTTPServer.localAddresses()
        if http.port == 0 {
            addInfo(menu, "Network server not running")
        } else if addresses.isEmpty {
            addInfo(menu, "Network: not connected to any network")
        } else {
            addInfo(menu, "Network fallback (click to copy):")
            for a in addresses {
                let url = networkURL(ip: a.ip)
                let item = NSMenuItem(title: url, action: #selector(copyURL(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                menu.addItem(item)
            }
            if let qr = qrImage(networkURL(ip: addresses[0].ip)) {
                let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
                view.image = qr
                let item = NSMenuItem()
                item.view = view
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        addAction(menu, "Reload Slides from PowerPoint", #selector(reload))
        addAction(menu, "Open Sounds Folder…", #selector(openSounds))
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        addAction(menu, "Open Remote in Browser", #selector(openLocal))
        addAction(menu, "Show Log", #selector(showLog))
        addAction(menu, "Generate New PIN", #selector(newPin))
        menu.addItem(.separator())
        addAction(menu, "Quit PPT Remote", #selector(quit), key: "q")
    }

    private func networkURL(ip: String) -> String { "http://\(ip):\(http.port)/?pin=\(hub.pin)" }

    private func addInfo(_ menu: NSMenu, _ text: String, bold: Bool = false) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        if bold {
            item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        }
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: NSSize(width: 200, height: 200))
        img.addRepresentation(rep)
        return img
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.representedObject as? String ?? "", forType: .string)
    }

    @objc private func enableJumps() {
        PowerPoint.requestJumpPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func reload() { hub.reloadDeck() }

    @objc private func openSounds() {
        try? FileManager.default.createDirectory(at: SoundBoard.userFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(SoundBoard.userFolder)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.write("Start at login: off")
            } else {
                try service.register()
                Log.write("Start at login: on (\(Bundle.main.bundlePath))")
                if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
                    let alert = NSAlert()
                    alert.messageText = "Start at Login is on"
                    alert.informativeText = "Tip: move PPT Remote to the Applications folder first, otherwise it stops starting at login when this folder moves or is rebuilt."
                    alert.runModal()
                }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
    @objc private func newPin() { hub.newPin() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openLocal() {
        if let url = URL(string: "http://localhost:\(http.port)/?pin=\(hub.pin)") { NSWorkspace.shared.open(url) }
    }

    @objc private func showLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PPTRemote.log")
        NSWorkspace.shared.open(url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
