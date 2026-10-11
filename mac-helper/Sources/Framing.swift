import Foundation

/// Splits a message into Bluetooth notification frames:
/// [type u8][msgId u8][seq u16 LE][total u16 LE][payload…]. Must match docs/protocol.js.
enum Framing {
    static let headerSize = 6

    static func frames(type: UInt8, msgId: UInt8, payload: Data, chunkSize: Int) -> [Data] {
        let size = max(1, chunkSize)
        let total = max(1, (payload.count + size - 1) / size)
        var chunks: [Data] = []
        chunks.reserveCapacity(total)
        for seq in 0..<total {
            var d = Data([type, msgId, UInt8(seq & 0xFF), UInt8(seq >> 8), UInt8(total & 0xFF), UInt8(total >> 8)])
            let start = seq * size
            let end = min(payload.count, start + size)
            if start < end { d.append(payload.subdata(in: payload.startIndex + start..<payload.startIndex + end)) }
            chunks.append(d)
        }
        return chunks
    }
}
