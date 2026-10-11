// Emits frames produced by mac-helper/Sources/Framing.swift as hex lines (one frame per line).
import Foundation
let args = CommandLine.arguments
let size = Int(args[1])!, chunk = Int(args[2])!, msgId = UInt8(args[3])!
var payload = Data(count: size)
for i in 0..<size { payload[i] = UInt8((i * 31 + 7) & 0xFF) }
for f in Framing.frames(type: 2, msgId: msgId, payload: payload, chunkSize: chunk) {
    print(f.map { String(format: "%02x", $0) }.joined())
}
