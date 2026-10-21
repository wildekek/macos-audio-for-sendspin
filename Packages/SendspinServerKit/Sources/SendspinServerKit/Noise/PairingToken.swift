import Foundation

/// A version-0 pairing token (pairing.md, Pairing Token): the client's public key and its
/// pairing PSK, for the operator to copy into a server. `SP:0` and the payload in base32
/// without padding, with every `2` written as `9`, so it stays in the QR alphanumeric set.
public enum PairingToken {
    public static func encode(clientKey: Data, pairingPSK: Data) -> String {
        precondition(clientKey.count == 32 && pairingPSK.count == 32)
        return "SP:0" + base32(clientKey + pairingPSK).replacingOccurrences(of: "2", with: "9")
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
