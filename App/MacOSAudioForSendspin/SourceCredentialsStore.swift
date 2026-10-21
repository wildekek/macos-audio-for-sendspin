import Foundation
import SendspinServerKit
import Security

/// Keeps this Mac's client credentials in the Keychain: the identity Music Assistant knows
/// this Mac by, its pairing token's secret and the pairings it made. Losing them means
/// pairing again.
enum SourceCredentialsStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "eu.vooijs.MacOSAudioForSendspin") + ".source-credentials"
    private static let account = "sendspin-client"

    static func load() -> SourceCredentials {
        if let data = read(), let credentials = try? JSONDecoder().decode(SourceCredentials.self, from: data) {
            return credentials
        }
        let credentials = SourceCredentials.generate()
        save(credentials)
        return credentials
    }

    @Sendable static func save(_ credentials: SourceCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        SecItemDelete(query as CFDictionary)
        let item = query.merging([
            kSecAttrLabel as String: "macOS Audio for Sendspin pairing credentials",
            kSecValueData as String: data,
            // This Mac only, and readable without the user present (after first unlock).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess {
            Log.error("Couldn't store the pairing credentials in the Keychain")
        }
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read() -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary,
                                         &result)
        return status == errSecSuccess ? result as? Data : nil
    }
}
