import CryptoKit
import Foundation

/// The server's long-term identity: a Curve25519 key pair whose public key, base64url
/// encoded, is the `server_id` (connection.md, Identities). Rotating it makes this a
/// different server to every player, so hosts persist the private key.
public struct ServerIdentity: Sendable {
    /// Raw 32-byte private key, for persistence.
    public let privateKeyData: Data
    public var name: String

    public init(privateKeyData: Data, name: String) throws {
        _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        self.privateKeyData = privateKeyData
        self.name = name
    }

    /// A new random identity.
    public static func generate(name: String) -> ServerIdentity {
        // A freshly generated key always has a valid raw representation.
        try! ServerIdentity(privateKeyData: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, name: name)
    }

    var privateKey: Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
    }

    /// The `server_id`: the base64url public key, 43 characters.
    public var id: String { Base64URL.encode(privateKey.publicKey.rawRepresentation) }
}
