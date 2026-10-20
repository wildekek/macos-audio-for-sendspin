import CryptoKit
import Foundation

/// base64url without padding: how Sendspin encodes keys, PSK ids and Noise messages.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: only the base64url alphabet, no padding, and the canonical encoding.
    static func decode(_ string: String) -> Data? {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard string.allSatisfy(alphabet.contains), string.count % 4 != 1 else { return nil }
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), encode(data) == string else { return nil }
        return data
    }
}

/// Pre-shared keys (spec: connection.md, Pre-Shared Key).
enum SendspinPSK {
    /// The published Sentinel PSK, used when no other PSK applies (unpaired sessions).
    static let sentinel = Data(SHA256.hash(data: Data("sendspin-sentinel-psk-v1".utf8)))

    /// `base64url(SHA-256("sendspin-psk-id-v1" || PSK))`, sent in Noise message 1.
    static func id(for psk: Data) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data("sendspin-psk-id-v1".utf8) + psk)))
    }
}
