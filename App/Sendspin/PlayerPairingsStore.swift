import Foundation
import SendspinServerKit
import Security

/// Keeps this Mac's pairings with speakers in the Keychain: each speaker's `client_id` with
/// the long-term PSK. Losing them means pairing those speakers again.
enum PlayerPairingsStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.sendspin-audio.mac") + ".player-pairings"
    private static let account = "sendspin-server"

    static func load() -> [String: Data] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary,
                                         &result)
        guard status == errSecSuccess, let data = result as? Data,
              let records = try? JSONDecoder().decode([String: Data].self, from: data) else { return [:] }
        return records
    }

    @Sendable static func save(_ records: [String: Data]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        SecItemDelete(query as CFDictionary)
        let item = query.merging([
            kSecAttrLabel as String: "Sendspin speaker pairings",
            kSecValueData as String: data,
            // This Mac only, and readable without the user present (after first unlock).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess {
            Log.error("Couldn't store the speaker pairings in the Keychain")
        }
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
