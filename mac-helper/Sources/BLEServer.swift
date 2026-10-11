import CoreBluetooth
import Foundation

/// Bluetooth LE peripheral (GATT server) that the web app connects to via Web Bluetooth.
///
/// Protocol:
/// - Command characteristic (write): UTF-8 text such as "auth 1234", "next", "goto 5", "img 3", "fmt avif,jpeg".
/// - Data characteristic (notify): framed messages. Each notification is
///   [type u8][msgId u8][seq u16 LE][total u16 LE][payload...]. Payloads of all chunks
///   with the same msgId are concatenated. Type 1 = JSON text, type 2 = image
///   (JSON header line + "\n" + image bytes in AVIF/HEIC/JPEG).
///
/// Every connected device has its own session (image requests, format, quality, notes already sent);
/// only PowerPoint itself is shared.
final class BLEServer: NSObject, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(string: "2A4C9463-10DD-4D1D-9670-1C3D7737E942")
    static let commandUUID = CBUUID(string: "41D625BB-4F1D-4BBE-98B2-362DAAED35C1")
    static let dataUUID = CBUUID(string: "C8CBD42E-2EEA-403D-9223-66344ADF9C27")

    private let hub: Hub
    private var manager: CBPeripheralManager!
    private var dataChar: CBMutableCharacteristic?
    private var serviceAdded = false

    private final class Session {
        let id: UUID
        var central: CBCentral
        var authed = false
        var preset = "med"
        var format: ImageFormat = .jpeg
        var imageRequests: [Int] = []
        /// Notes level (1 plain, 2 formatted) already sent per slide, so state updates stay small.
        var sentNotes: [Int: Int] = [:]
        var lastSentList = ""
        var lastSentDeck = ""
        var lastSentVersion = 0

        init(central: CBCentral) {
            id = central.identifier
            self.central = central
        }

        func resetSent() {
            sentNotes = [:]
            lastSentList = ""
        }
    }

    private var sessions: [UUID: Session] = [:]

    private struct OutMessage {
        var chunks: [Data]
        var next = 0
        var target: UUID
        var isState = false
        var isDeck = false
        /// Notes / presentation list carried by a state message (to resend if it is dropped unsent).
        var notes: [Int] = []
        var carriesList = false
    }
    private var highQueue: [OutMessage] = []
    private var lowQueue: [OutMessage] = []
    private var msgCounter: UInt8 = 0
    private var encoding = false
    private var nextImageSession = 0

    private(set) var status = "Starting…"
    var onStatusChange: (() -> Void)?

    var connectedCount: Int { sessions.values.filter(\.authed).count }

    init(hub: Hub) {
        self.hub = hub
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
        hub.onChange.append { [weak self] in self?.sendStateIfNeeded() }
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            setupService()
        case .poweredOff:
            setStatus("Bluetooth is off")
        case .unauthorized:
            setStatus("Bluetooth permission denied (System Settings › Privacy › Bluetooth)")
        case .unsupported:
            setStatus("Bluetooth LE not supported")
        default:
            setStatus("Bluetooth unavailable")
        }
        if peripheral.state != .poweredOn {
            sessions.removeAll()
            highQueue.removeAll()
            lowQueue.removeAll()
            serviceAdded = false
        }
    }

    private func setupService() {
        guard !serviceAdded else { return }
        let cmd = CBMutableCharacteristic(type: Self.commandUUID, properties: [.write, .writeWithoutResponse],
                                          value: nil, permissions: [.writeable])
        let data = CBMutableCharacteristic(type: Self.dataUUID, properties: [.notify, .read],
                                           value: nil, permissions: [.readable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [cmd, data]
        dataChar = data
        manager.removeAllServices()
        manager.add(service)
        serviceAdded = true
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            setStatus("Bluetooth error: \(error.localizedDescription)")
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "PPT Remote",
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            setStatus("Advertising failed: \(error.localizedDescription)")
        } else {
            updateConnectedStatus()
            Log.write("BLE advertising as \"PPT Remote\"")
        }
    }

    private func session(for central: CBCentral) -> Session {
        if let s = sessions[central.identifier] {
            s.central = central
            return s
        }
        let s = Session(central: central)
        sessions[central.identifier] = s
        return s
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let s = session(for: central)
        // Ask for a short connection interval: many more packets per second (notably on Android).
        peripheral.setDesiredConnectionLatency(.low, for: central)
        Log.write("BLE central subscribed: \(central.identifier) (max \(central.maximumUpdateValueLength) bytes)")
        if s.authed {
            s.resetSent()
            enqueueDeck(s)
            enqueueState(s)
        } else {
            enqueueJSON(["type": "auth", "ok": false, "need": true], to: s)
        }
        updateConnectedStatus()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        sessions.removeValue(forKey: central.identifier)
        highQueue.removeAll { $0.target == central.identifier }
        lowQueue.removeAll { $0.target == central.identifier }
        Log.write("BLE central unsubscribed: \(central.identifier)")
        updateConnectedStatus()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            guard let v = r.value, let text = String(data: v, encoding: .utf8) else { continue }
            handle(text.trimmingCharacters(in: .whitespacesAndNewlines), from: session(for: r.central))
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pump()
    }

    // MARK: - Commands

    private func handle(_ text: String, from s: Session) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first?.lowercased() else { return }
        let arg = parts.count > 1 ? parts[1] : ""

        if cmd == "auth" {
            // "auth <pin> [formats] [quality]", e.g. "auth 1234 avif,heic,jpeg med"
            let tokens = arg.split(separator: " ").map(String.init)
            if tokens.first == hub.pin {
                if tokens.count > 1 { s.format = ImageFormat.best(from: tokens[1]) }
                if tokens.count > 2, ["low", "med", "high"].contains(tokens[2]) { s.preset = tokens[2] }
                Log.write("BLE central authenticated: \(s.id) (formats \(tokens.count > 1 ? tokens[1] : "-") → \(s.format.rawValue), quality \(s.preset))")
                s.authed = true
                s.resetSent()
                enqueueJSON(["type": "auth", "ok": true], to: s)
                enqueueDeck(s)
                enqueueState(s)
            } else {
                enqueueJSON(["type": "auth", "ok": false, "need": true, "wrong": true], to: s)
            }
            updateConnectedStatus()
            return
        }
        guard s.authed else {
            enqueueJSON(["type": "auth", "ok": false, "need": true], to: s)
            return
        }
        switch cmd {
        case "hello":
            s.resetSent()
            enqueueDeck(s)
            enqueueState(s)
        case "deck":
            enqueueDeck(s)
        case "sounds":
            enqueueJSON(hub.sounds.listObject(), to: s)
        case "fmt":
            let f = ImageFormat.best(from: arg)
            if f != s.format {
                s.format = f
                s.imageRequests.removeAll()
                lowQueue.removeAll { $0.target == s.id && $0.next == 0 }
                Log.write("BLE image format for \(s.id): \(f.rawValue)")
            }
            enqueueDeck(s)
        case "img":
            for n in arg.split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
            where !s.imageRequests.contains(n) {
                s.imageRequests.append(n)
            }
            pump()
        case "imgclear":
            s.imageRequests.removeAll()
            lowQueue.removeAll { $0.target == s.id && $0.next == 0 }
        case "quality":
            s.preset = ["low", "med", "high"].contains(arg) ? arg : "med"
        default:
            hub.handle(command: text)
        }
    }

    // MARK: - Sending

    private func sendStateIfNeeded() {
        for s in sessions.values where s.authed && hub.version != s.lastSentVersion {
            if hub.deckID != s.lastSentDeck {
                s.imageRequests.removeAll()
                lowQueue.removeAll { $0.target == s.id && $0.next == 0 }
                s.sentNotes = [:]
                enqueueDeck(s)
            }
            enqueueState(s)
        }
    }

    private func enqueueDeck(_ s: Session) {
        guard s.authed else { return }
        s.lastSentDeck = hub.deckID
        highQueue.removeAll { $0.target == s.id && $0.isDeck && $0.next == 0 }
        guard let data = try? JSONSerialization.data(withJSONObject: hub.deckObject(format: s.format)) else { return }
        var msg = makeMessage(type: 1, payload: data, to: s)
        msg.isDeck = true
        highQueue.append(msg)
        pump()
    }

    private func enqueueState(_ s: Session) {
        guard s.authed else { return }
        s.lastSentVersion = hub.version
        // Only the newest state matters: drop this device's queued states that have not started sending yet
        // (and forget what they carried, so it is included again).
        for m in highQueue where m.target == s.id && m.isState && m.next == 0 {
            for n in m.notes { s.sentNotes[n] = nil }
            if m.carriesList { s.lastSentList = "" }
        }
        highQueue.removeAll { $0.target == s.id && $0.isState && $0.next == 0 }
        let st = hub.state
        let wanted = [st.index, st.index + 1].filter { hub.notesLevel($0) > (s.sentNotes[$0] ?? 0) }
        let list = hub.presentationList()
        let listKey = (try? JSONSerialization.data(withJSONObject: list)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let sendList = listKey != s.lastSentList
        var obj = hub.stateObject(notesFor: wanted, includeList: sendList)
        if obj["notes"] == nil { obj["notes"] = [:] as [String: String] }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        for n in wanted { s.sentNotes[n] = hub.notesLevel(n) }
        if sendList { s.lastSentList = listKey }
        var msg = makeMessage(type: 1, payload: data, to: s)
        msg.isState = true
        msg.notes = wanted
        msg.carriesList = sendList
        highQueue.append(msg)
        pump()
    }

    private func enqueueJSON(_ obj: [String: Any], to s: Session, pumpNow: Bool = true) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        highQueue.append(makeMessage(type: 1, payload: data, to: s))
        if pumpNow { pump() }
    }

    private func makeMessage(type: UInt8, payload: Data, to s: Session) -> OutMessage {
        msgCounter &+= 1
        let chunk = max(14, s.central.maximumUpdateValueLength - Framing.headerSize)
        return OutMessage(chunks: Framing.frames(type: type, msgId: msgCounter, payload: payload, chunkSize: chunk), target: s.id)
    }

    /// Encodes the next requested slide in the background (taking turns between devices), then queues it.
    private func prepareNextImage() {
        guard lowQueue.count < 2, !encoding else { return }
        let waiting = sessions.values.filter { $0.authed && !$0.imageRequests.isEmpty }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard !waiting.isEmpty else { return }
        nextImageSession = (nextImageSession + 1) % waiting.count
        let s = waiting[nextImageSession]
        let slide = s.imageRequests.removeFirst()
        let deck = hub.deckID
        let key = hub.images.key(for: slide)
        let spec = ImageSpec.bluetooth(s.preset, format: s.format)
        let preset = s.preset
        let target = s.id
        encoding = true
        hub.images.image(slide: slide, spec: spec) { [weak self] img in
            guard let self else { return }
            self.encoding = false
            guard deck == self.hub.deckID, let s = self.sessions[target], s.authed else { self.pump(); return }
            if let img {
                let header: [String: Any] = ["slide": slide, "deck": deck, "key": key, "fmt": img.spec.format.rawValue,
                                             "w": img.spec.width, "q": preset, "enc": img.encodeMs]
                var payload = (try? JSONSerialization.data(withJSONObject: header)) ?? Data()
                payload.append(0x0A)
                payload.append(img.data)
                self.lowQueue.append(self.makeMessage(type: 2, payload: payload, to: s))
            } else {
                self.enqueueJSON(["type": "noimage", "slide": slide, "deck": deck], to: s, pumpNow: false)
            }
            self.pump()
        }
    }

    private func pump() {
        guard let dataChar, manager.state == .poweredOn else { return }
        while true {
            if lowQueue.count < 2 { prepareNextImage() } // encode the next image while this one is sent
            let useHigh = !highQueue.isEmpty
            guard useHigh || !lowQueue.isEmpty else { return }
            var msg = useHigh ? highQueue[0] : lowQueue[0]
            guard let central = sessions[msg.target]?.central else {
                if useHigh { highQueue.removeFirst() } else { lowQueue.removeFirst() }
                continue
            }
            let ok = manager.updateValue(msg.chunks[msg.next], for: dataChar, onSubscribedCentrals: [central])
            if !ok { return } // wait for peripheralManagerIsReady
            msg.next += 1
            if msg.next >= msg.chunks.count {
                if useHigh { highQueue.removeFirst() } else { lowQueue.removeFirst() }
            } else {
                if useHigh { highQueue[0] = msg } else { lowQueue[0] = msg }
            }
        }
    }

    // MARK: - Status

    private func updateConnectedStatus() {
        guard manager.state == .poweredOn else { return }
        let n = connectedCount
        let pending = sessions.count - n
        if n > 0 {
            setStatus("Bluetooth: \(n) remote\(n == 1 ? "" : "s") connected")
        } else if pending > 0 {
            setStatus("Bluetooth: device connected, waiting for PIN")
        } else {
            setStatus("Bluetooth: ready (\"PPT Remote\")")
        }
    }

    private func setStatus(_ s: String) {
        guard s != status else { return }
        status = s
        Log.write(s)
        onStatusChange?()
    }
}
