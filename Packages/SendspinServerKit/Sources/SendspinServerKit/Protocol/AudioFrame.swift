import Foundation

/// Binary player audio chunk (roles/player/v1.md): type byte 4, big-endian int64 play
/// timestamp (µs, server clock), big-endian uint32 send-ahead (µs from transmit to play
/// time), then the encoded audio.
enum AudioFrame {
    static let messageType: UInt8 = 4
    static let headerSize = 13

    /// `sendAheadUs` saturates: 0 when sent at or after the play time, UInt32.max above it.
    static func pack(timestampUs: Int64, sendAheadUs: Int64, payload: Data) -> Data {
        var frame = Data(capacity: headerSize + payload.count)
        frame.append(messageType)
        withUnsafeBytes(of: timestampUs.bigEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(clamping: max(0, sendAheadUs)).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}
