import Foundation
import SendspinServerKit
import Security
import os

/// Keeps the server's Noise identity in the Keychain. Its public key is the `server_id`
/// players know this Mac by, so it must survive restarts; a new key is a new server.
enum IdentityStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.sendspin-audio.mac") + ".server-identity"
    private static let account = "noise-static-key"

    static func load(name: String) -> ServerIdentity {
        if let key = read(), let identity = try? ServerIdentity(privateKeyData: key, name: name) {
            return identity
        }
        let identity = ServerIdentity.generate(name: name)
        if !save(identity.privateKeyData) {
            // Still usable for this run; players see a new server after the next launch.
            Log.error("Couldn't store the server identity in the Keychain")
        }
        return identity
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

    private static func save(_ key: Data) -> Bool {
        SecItemDelete(query as CFDictionary)
        let item = query.merging([
            kSecAttrLabel as String: "Sendspin server identity",
            kSecValueData as String: key,
            // This Mac only, and readable without the user present (after first unlock).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
