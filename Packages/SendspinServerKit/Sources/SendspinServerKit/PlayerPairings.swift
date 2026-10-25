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

/// How the operator pairs a player (pairing.md, Methods). Servers implement all three.
public enum PairingMethod: Sendable, Equatable {
    /// A pairing token from the player, for automation: no code, no PAKE.
    case token(PairingToken.PairingPSK)
    /// The 8 digits printed on the player or its leaflet.
    case staticCode
    /// The 6 digits the player shows or speaks, new for each attempt.
    case dynamicCode
    /// The same code as a QR code on the player's screen: a version-1 pairing token, scanned.
    case dynamicQRCode
}

/// What the operator is asked to enter.
public enum PairingPrompt: Sendable, Equatable {
    /// The player's static code; `again` after a wrong one.
    case staticCode(again: Bool)
    /// The code the player shows or speaks now; `again` after a wrong one.
    case dynamicCode(again: Bool)
    /// The QR code the player shows now, its token as read; `again` after a wrong one.
    case dynamicQRCode(again: Bool)

    /// Digits the code has; none for a QR code.
    public var length: Int {
        switch self {
        case .staticCode: 8
        case .dynamicCode: 6
        case .dynamicQRCode: 0
        }
    }
}

/// A pairing the operator started.
public struct PairingRequest: Sendable {
    public var method: PairingMethod
    /// Asked for the code each time one is needed: the digits entered (or the token a QR code
    /// read), or nil to cancel.
    public var code: @Sendable (PairingPrompt) async -> String?

    public init(method: PairingMethod, code: @escaping @Sendable (PairingPrompt) async -> String?) {
        self.method = method
        self.code = code
    }
}

/// Where a pairing stands, for the menu.
public enum PairingProgress: Sendable, Equatable {
    case starting
    /// The player holds the attempt back, e.g. until its pairing button is pressed. Its
    /// message comes from an unauthenticated peer: show it as plain text, attributed to it.
    case waiting(message: String?)
    case enteringCode(PairingPrompt)
    case checking
    case paired
    case failed(String)
}
