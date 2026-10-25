import Foundation

/// This Mac's pairings with players (pairing.md, Pairing Records): each player's `client_id`
/// with the long-term PSK the pairing produced. Shared by every session; `save` is called
/// with the whole set whenever it changes, to persist it.
public final class PlayerPairings: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data]
    private let save: @Sendable ([String: Data]) -> Void

    public init(records: [String: Data] = [:], save: @escaping @Sendable ([String: Data]) -> Void = { _ in }) {
        self.records = records
        self.save = save
    }

    /// The long-term PSK for the player with this `client_id`, if paired.
    public func psk(for clientID: String) -> Data? {
        lock.withLock { records[clientID] }
    }

    public func isPaired(_ clientID: String) -> Bool {
        psk(for: clientID) != nil
    }

    /// A new pairing replaces the player's old record.
    func store(_ psk: Data, for clientID: String) {
        let records = lock.withLock {
            self.records[clientID] = psk
            return self.records
        }
        save(records)
    }

    public func remove(_ clientID: String) {
        let records: [String: Data]? = lock.withLock {
            guard self.records.removeValue(forKey: clientID) != nil else { return nil }
            return self.records
        }
        if let records { save(records) }
    }
}
