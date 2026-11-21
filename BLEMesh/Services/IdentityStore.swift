import Foundation
import Security
import UIKit
import MeshCore

/// Stores this device's mesh keys in the Keychain (this device only, never synced/backed up).
enum IdentityStore {
    private static let service = "com.noxrail.blemesh.identity"
    private static let signingAccount = "signing"
    private static let agreementAccount = "agreement"
    private static let nicknameKey = "mesh.nickname"

    static func loadOrCreate() -> MeshIdentity {
        if let signing = read(signingAccount), let agreement = read(agreementAccount),
           let identity = try? MeshIdentity(signingKeyData: signing, agreementKeyData: agreement) {
            return identity
        }
        let identity = MeshIdentity()
        write(identity.signingKeyData, account: signingAccount)
        write(identity.agreementKeyData, account: agreementAccount)
        return identity
    }

    static var nickname: String {
        get {
            let saved = UserDefaults.standard.string(forKey: nicknameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let saved, !saved.isEmpty { return saved }
            return UIDevice.current.name
        }
        set { UserDefaults.standard.set(String(newValue.prefix(32)), forKey: nicknameKey) }
    }

    /// Delete keys (panic wipe). A new identity is generated on next launch.
    static func wipe() {
        for account in [signingAccount, agreementAccount] {
            SecItemDelete(baseQuery(account) as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: nicknameKey)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        // Available after first unlock so BLE background relaying keeps working while locked.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            MeshLogger.app.error("Keychain write failed: \(status)")
        }
    }
}
