import CryptoKit
import Foundation

/// The values of the Dynamic Pairing Code flow (pairing.md: Dynamic Pairing Code Flow, PAKE,
/// Wrapping). The code is bound to the Noise handshake: both nonces and the handshake hash
/// `h` go into it, and the client commits to its nonce before it sees the server's.
enum DynamicPairingCode {
    static let nonceSize = 32

    /// `SHA-256("sendspin-pair-commit-v1" || nonce_B)`, sent in client/pair-init.
    static func commitment(to nonceB: Data) -> Data {
        Data(SHA256.hash(data: Data("sendspin-pair-commit-v1".utf8) + nonceB))
    }

    /// The six digits: `SHA-256("sendspin-pairing-code-derive-v1" || h || nonce_A || nonce_B)`
    /// as a big-endian number, mod 10^6, zero-padded.
    static func digits(handshakeHash h: Data, nonceA: Data, nonceB: Data) -> String {
        let digest = SHA256.hash(data: Data("sendspin-pairing-code-derive-v1".utf8) + h + nonceA + nonceB)
        let value = digest.reduce(UInt64(0)) { ($0 * 256 + UInt64($1)) % 1_000_000 }
        let digits = String(value)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// Grouped for display: `123-456` (Pairing Code Presentation).
    static func presented(_ digits: String) -> String {
        "\(digits.prefix(3))-\(digits.suffix(3))"
    }

    /// CPace's session id for a round: `"sendspin-pair-pake-v1" || h || pairing_index || round`,
    /// the two numbers as big-endian uint32.
    static func sessionID(handshakeHash h: Data, pairingIndex: Int, round: Int) -> Data {
        Data("sendspin-pair-pake-v1".utf8) + h + bigEndian(UInt32(pairingIndex)) + bigEndian(UInt32(round))
    }

    enum WrapLabel: String {
        case psk = "sendspin-pair-psk-wrap-v1"
        case nonce = "sendspin-pair-nonce-wrap-v1"
    }

    /// A 32-byte value sealed under the CPace output: the suite's AEAD with key
    /// `SHA-256(label || sid || ISK)`, an all-zero nonce and no associated data.
    static func wrap(_ value: Data, _ label: WrapLabel, sid: Data, isk: Data, suite: NoiseSuite) throws -> Data {
        let key = SymmetricKey(data: SHA256.hash(data: Data(label.rawValue.utf8) + sid + isk))
        return try suite.encrypt(key: key, nonce: 0, ad: Data(), plaintext: value)
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
