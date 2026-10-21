import CryptoKit
import Foundation

/// What this Mac keeps as a Sendspin client (pairing.md): its identity, its pairing PSK,
/// the pairing records of servers it paired with, and the last server it played for. Hosts
/// persist it whole (the app in the Keychain): losing it means pairing again.
public struct SourceCredentials: Codable, Sendable, Equatable {
    public struct PairingRecord: Codable, Sendable, Equatable {
        public var serverID: String
        /// The long-term PSK.
        public var psk: Data
        public var lastUsed: Date
        /// From the server's last server/hello, for showing.
        public var serverName: String?
    }

    /// At least 5, as the spec requires; more would only keep stale servers.
    static let recordCapacity = 5

    /// The identity's raw Curve25519 private key; its public key is the `client_id`.
    public var privateKey: Data
    /// Long-lived and reusable: pairing doesn't consume it. Shown only as the pairing token.
    public var pairingPSK: Data
    public var records: [PairingRecord] = []
    /// The server that most recently held a playback connection (connection.md, Multiple servers).
    public var lastPlaybackServerID: String?

    /// New credentials, every secret from a CSPRNG.
    public static func generate() -> SourceCredentials {
        SourceCredentials(privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                          pairingPSK: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    var identity: Curve25519.KeyAgreement.PrivateKey {
        // Stored keys come from `generate()`, so the raw representation is valid.
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    }

    public var clientID: String { Base64URL.encode(identity.publicKey.rawRepresentation) }

    /// What the operator enters into the server to pair.
    public var pairingToken: String {
        PairingToken.encode(clientKey: identity.publicKey.rawRepresentation, pairingPSK: pairingPSK)
    }

    func record(pskID: String) -> PairingRecord? {
        records.first { SendspinPSK.id(for: $0.psk) == pskID }
    }

    /// Store a new pairing, replacing the server's old one. At capacity the least recently
    /// used record goes, but never one in `use` (backing an open connection).
    mutating func store(serverID: String, psk: Data, keeping use: Set<String>) {
        records.removeAll { $0.serverID == serverID }
        while records.count >= Self.recordCapacity,
              let oldest = records.filter({ !use.contains($0.serverID) }).min(by: { $0.lastUsed < $1.lastUsed }) {
            records.removeAll { $0.serverID == oldest.serverID }
        }
        records.append(PairingRecord(serverID: serverID, psk: psk, lastUsed: Date()))
    }

    mutating func touch(serverID: String) {
        if let index = records.firstIndex(where: { $0.serverID == serverID }) { records[index].lastUsed = Date() }
    }

    mutating func remove(serverID: String) {
        records.removeAll { $0.serverID == serverID }
    }
}
