import Foundation

/// A pairing token (pairing.md, Pairing Token): `SP:`, a version, and the payload in base32
/// without padding, with every `2` written as `9`, so it stays in the QR alphanumeric set.
/// Version 0 carries a client's public key and pairing PSK, for the operator to copy into a
/// server; version 1 a dynamic pairing code shown as a QR code.
public enum PairingToken {
    public static func encode(clientKey: Data, pairingPSK: Data) -> String {
        precondition(clientKey.count == 32 && pairingPSK.count == 32)
        return "SP:0" + base32(clientKey + pairingPSK).replacingOccurrences(of: "2", with: "9")
    }

    /// A version-0 token's contents.
    public struct PairingPSK: Equatable, Sendable {
        public var clientKey: Data
        public var pairingPSK: Data
        /// The key as the `client_id` it must match on the connection.
        public var clientID: String { Base64URL.encode(clientKey) }
    }

    /// Decode what an operator typed or pasted, leniently: whitespace, case and the `SP:`
    /// prefix don't matter, and `9` reads as `2`. Nil for anything else, or another version.
    public static func decodePairingPSK(_ input: String) -> PairingPSK? {
        guard let payload = payload(of: input, version: "0", minimumSize: 64) else { return nil }
        return PairingPSK(clientKey: payload.prefix(32), pairingPSK: payload.subdata(in: 32..<64))
    }

    /// A version-1 token's pairing code: its first 24 payload bytes.
    static func decodeDynamicCode(_ input: String) -> Data? {
        payload(of: input, version: "1", minimumSize: 24)?.prefix(24)
    }

    /// The payload of a token of `version`, at least `minimumSize` bytes; the bytes beyond
    /// what the version defines are reserved, and ignored.
    private static func payload(of input: String, version: Character, minimumSize: Int) -> Data? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("SP:") { text.removeFirst(3) }
        guard text.first == version else { return nil }
        text.removeFirst()
        guard let payload = base32Decode(text.replacingOccurrences(of: "9", with: "2")),
              payload.count >= minimumSize else { return nil }
        return Data(payload)
    }

    /// RFC 4648 base32 without padding; nil for any other character or a malformed length.
    private static func base32Decode(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = Data()
        var buffer = 0
        var bits = 0
        for character in text {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        // Leftover bits are padding: fewer than 5, and zero.
        guard bits < 5, buffer & ((1 << bits) - 1) == 0 else { return nil }
        return output
    }

    /// RFC 4648 base32, without the `=` padding.
    private static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 0x1F]) }
        return output
    }
}
