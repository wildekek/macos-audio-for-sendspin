import Foundation

/// Binary player audio chunk: type byte 4, big-endian int64 play timestamp (µs,
/// server clock), then — for spec v1 clients only — a big-endian uint32 send-ahead
/// (µs from transmit to play time). Legacy clients take the 9-byte header.
enum AudioFrame {
    static let messageType: UInt8 = 4
    static let legacyHeaderSize = 9
    static let headerSize = 13

    static func pack(timestampUs: Int64, sendAheadUs: Int64?, payload: Data) -> Data {
        var frame = Data(capacity: headerSize + payload.count)
        frame.append(messageType)
        withUnsafeBytes(of: timestampUs.bigEndian) { frame.append(contentsOf: $0) }
        if let sendAheadUs {
            let clamped = UInt32(clamping: max(0, sendAheadUs))
            withUnsafeBytes(of: clamped.bigEndian) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return frame
    }
}
