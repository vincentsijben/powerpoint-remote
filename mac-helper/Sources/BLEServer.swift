import CoreBluetooth
import Foundation

/// Bluetooth LE peripheral (GATT server) that the iPad web app connects to via Web Bluetooth.
///
/// Protocol:
/// - Command characteristic (write): UTF-8 text such as "auth 1234", "next", "goto 5", "img 3", "fmt avif,jpeg".
/// - Data characteristic (notify): framed messages. Each notification is
///   [type u8][msgId u8][seq u16 LE][total u16 LE][payload...]. Payloads of all chunks
///   with the same msgId are concatenated. Type 1 = JSON text, type 2 = image
///   (JSON header line + "\n" + image bytes in AVIF/HEIC/JPEG).
final class BLEServer: NSObject, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(string: "2A4C9463-10DD-4D1D-9670-1C3D7737E942")
    static let commandUUID = CBUUID(string: "41D625BB-4F1D-4BBE-98B2-362DAAED35C1")
    static let dataUUID = CBUUID(string: "C8CBD42E-2EEA-403D-9223-66344ADF9C27")

    private let hub: Hub
    private var manager: CBPeripheralManager!
    private var dataChar: CBMutableCharacteristic?
    private var serviceAdded = false

    private var subscribers: [UUID: CBCentral] = [:]
    private var authed: Set<UUID> = []

    private struct OutMessage {
        var chunks: [Data]
        var next = 0
        var targets: [UUID]?   // nil = all authenticated subscribers
        var isState = false
        var isDeck = false
    }
    private var highQueue: [OutMessage] = []
    private var lowQueue: [OutMessage] = []
    private var imageRequests: [Int] = []
    private var msgCounter: UInt8 = 0
    private var lastSentVersion = 0

    private var preset = "med"
    private var format: ImageFormat = .jpeg
    private var encoding = false
    private var lastSentDeck = ""

    private(set) var status = "Starting…"
    var onStatusChange: (() -> Void)?

    var connectedCount: Int { authed.count }

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
            subscribers.removeAll()
            authed.removeAll()
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

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribers[central.identifier] = central
        Log.write("BLE central subscribed: \(central.identifier) (max \(central.maximumUpdateValueLength) bytes)")
        if authed.contains(central.identifier) {
            enqueueState(force: true)
        } else {
            enqueueJSON(["type": "auth", "ok": false, "need": true], to: [central.identifier])
        }
        updateConnectedStatus()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers.removeValue(forKey: central.identifier)
        authed.remove(central.identifier)
        Log.write("BLE central unsubscribed: \(central.identifier)")
        if authed.isEmpty {
            imageRequests.removeAll()
            lowQueue.removeAll()
            highQueue.removeAll()
        }
        updateConnectedStatus()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            guard let v = r.value, let text = String(data: v, encoding: .utf8) else { continue }
            handle(text.trimmingCharacters(in: .whitespacesAndNewlines), from: r.central)
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pump()
    }

    // MARK: - Commands

    private func handle(_ text: String, from central: CBCentral) {
        let id = central.identifier
        if subscribers[id] == nil { subscribers[id] = central }
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first?.lowercased() else { return }
        let arg = parts.count > 1 ? parts[1] : ""

        if cmd == "auth" {
            // "auth <pin> [formats] [quality]", e.g. "auth 1234 avif,heic,jpeg med"
            let tokens = arg.split(separator: " ").map(String.init)
            if tokens.first == hub.pin {
                if tokens.count > 1 { format = ImageFormat.best(from: tokens[1]) }
                if tokens.count > 2, ["low", "med", "high"].contains(tokens[2]) { preset = tokens[2] }
                Log.write("BLE client formats: \(tokens.count > 1 ? tokens[1] : "-") → \(format.rawValue), quality \(preset)")
                authed.insert(id)
                Log.write("BLE central authenticated: \(id)")
                enqueueJSON(["type": "auth", "ok": true], to: [id])
                enqueueDeck()
                enqueueState(force: true)
            } else {
                enqueueJSON(["type": "auth", "ok": false, "need": true, "wrong": true], to: [id])
            }
            updateConnectedStatus()
            return
        }
        guard authed.contains(id) else {
            enqueueJSON(["type": "auth", "ok": false, "need": true], to: [id])
            return
        }
        switch cmd {
        case "hello":
            enqueueDeck()
            enqueueState(force: true)
        case "deck":
            enqueueDeck()
        case "fmt":
            let f = ImageFormat.best(from: arg)
            if f != format {
                format = f
                imageRequests.removeAll()
                Log.write("BLE image format: \(f.rawValue)")
            }
            enqueueDeck()
        case "img":
            for s in arg.split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
            where !imageRequests.contains(s) {
                imageRequests.append(s)
            }
            pump()
        case "imgclear":
            imageRequests.removeAll()
            lowQueue.removeAll { $0.next == 0 }
        case "quality":
            preset = ["low", "med", "high"].contains(arg) ? arg : "med"
        default:
            hub.handle(command: text)
        }
    }

    // MARK: - Sending

    private func sendStateIfNeeded() {
        guard !authed.isEmpty, hub.version != lastSentVersion else { return }
        if hub.deckID != lastSentDeck {
            imageRequests.removeAll()
            lowQueue.removeAll { $0.next == 0 }
            enqueueDeck()
        }
        enqueueState(force: false)
    }

    private func enqueueDeck() {
        guard !authed.isEmpty else { return }
        lastSentDeck = hub.deckID
        highQueue.removeAll { $0.isDeck && $0.next == 0 }
        guard let data = try? JSONSerialization.data(withJSONObject: hub.deckObject(format: format)) else { return }
        var msg = makeMessage(type: 1, payload: data)
        msg.isDeck = true
        highQueue.append(msg)
        pump()
    }

    private func enqueueState(force: Bool) {
        guard !authed.isEmpty else { return }
        lastSentVersion = hub.version
        // Only the newest state matters: drop queued states that have not started sending yet.
        highQueue.removeAll { $0.isState && $0.next == 0 }
        var msg = makeMessage(type: 1, payload: hub.stateJSON(allNotes: false))
        msg.isState = true
        highQueue.append(msg)
        pump()
    }

    private func enqueueJSON(_ obj: [String: Any], to targets: [UUID], pumpNow: Bool = true) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var msg = makeMessage(type: 1, payload: data)
        msg.targets = targets
        highQueue.append(msg)
        if pumpNow { pump() }
    }

    private func chunkPayloadSize() -> Int {
        let centrals = authed.compactMap { subscribers[$0] }
        let mtu = centrals.map(\.maximumUpdateValueLength).min() ?? subscribers.values.map(\.maximumUpdateValueLength).min() ?? 20
        return max(14, mtu - Framing.headerSize)
    }

    private func makeMessage(type: UInt8, payload: Data) -> OutMessage {
        msgCounter &+= 1
        return OutMessage(chunks: Framing.frames(type: type, msgId: msgCounter, payload: payload, chunkSize: chunkPayloadSize()))
    }

    /// Encodes the next requested slide in the background, then queues it for sending.
    private func prepareNextImage() {
        guard lowQueue.count < 2, !encoding, !imageRequests.isEmpty, !authed.isEmpty else { return }
        let slide = imageRequests.removeFirst()
        let deck = hub.deckID
        let key = hub.images.key(for: slide)
        let spec = ImageSpec.bluetooth(preset, format: format)
        encoding = true
        hub.images.image(slide: slide, spec: spec) { [weak self] img in
            guard let self else { return }
            self.encoding = false
            guard deck == self.hub.deckID else { self.pump(); return }
            if let img {
                let header: [String: Any] = ["slide": slide, "deck": deck, "key": key, "fmt": img.spec.format.rawValue,
                                             "w": img.spec.width, "q": self.preset, "enc": img.encodeMs]
                var payload = (try? JSONSerialization.data(withJSONObject: header)) ?? Data()
                payload.append(0x0A)
                payload.append(img.data)
                self.lowQueue.append(self.makeMessage(type: 2, payload: payload))
            } else {
                self.enqueueJSON(["type": "noimage", "slide": slide, "deck": deck], to: Array(self.authed), pumpNow: false)
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
            let ids = msg.targets ?? Array(authed)
            let centrals = ids.compactMap { subscribers[$0] }
            if centrals.isEmpty {
                if useHigh { highQueue.removeFirst() } else { lowQueue.removeFirst() }
                continue
            }
            let ok = manager.updateValue(msg.chunks[msg.next], for: dataChar, onSubscribedCentrals: centrals)
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
        let n = authed.count
        let pending = subscribers.count - n
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
