import Foundation
import CryptoKit
import UIKit

/// Represents this device's permanent identity in the mesh network
final class DeviceIdentity: ObservableObject {
    
    // MARK: - Public Properties
    
    let deviceID: UUID
    let publicKey: P256.KeyAgreement.PublicKey
    let signingPublicKey: P256.Signing.PublicKey
    @Published var displayName: String
    let createdAt: Date
    
    // Derived
    var shortID: String {
        deviceID.uuidString.prefix(8).description
    }
    
    var publicKeyData: Data {
        publicKey.rawRepresentation
    }
    
    var signingPublicKeyData: Data {
        signingPublicKey.rawRepresentation
    }
    
    var publicKeyFingerprint: String {
        let hash = SHA256.hash(data: publicKeyData)
        return hash.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    
    var signingKeyFingerprint: String {
        let hash = SHA256.hash(data: signingPublicKeyData)
        return hash.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    
    // MARK: - Private
    
    private let privateKey: P256.KeyAgreement.PrivateKey
    private let signingPrivateKey: P256.Signing.PrivateKey
    
    private static let deviceIDKey = "mesh.device.id"
    private static let privateKeyKey = "mesh.device.privateKey"
    private static let signingKeyKey = "mesh.device.signingKey"
    private static let displayNameKey = "mesh.device.displayName"
    
    // MARK: - Singleton
    
    static let shared: DeviceIdentity = {
        return DeviceIdentity.loadOrCreate()
    }()
    
    // MARK: - Initialization
    
    private init(
        deviceID: UUID,
        privateKey: P256.KeyAgreement.PrivateKey,
        signingPrivateKey: P256.Signing.PrivateKey,
        displayName: String,
        createdAt: Date
    ) {
        self.deviceID = deviceID
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey
        self.signingPrivateKey = signingPrivateKey
        self.signingPublicKey = signingPrivateKey.publicKey
        self.displayName = displayName
        self.createdAt = createdAt
    }
    
    // MARK: - Factory
    
    private static func loadOrCreate() -> DeviceIdentity {
        // Try to load existing identity
        if let identity = loadFromKeychain() {
            MeshLogger.app.info("Loaded existing device identity: \(identity.shortID)")
            return identity
        }
        
        // Create new identity
        let identity = createNew()
        saveToKeychain(identity)
        MeshLogger.app.info("Created new device identity: \(identity.shortID)")
        return identity
    }
    
    private static func createNew() -> DeviceIdentity {
        let deviceID = UUID()
        let privateKey = P256.KeyAgreement.PrivateKey()
        let signingKey = P256.Signing.PrivateKey()
        let displayName = UIDevice.current.name
        
        return DeviceIdentity(
            deviceID: deviceID,
            privateKey: privateKey,
            signingPrivateKey: signingKey,
            displayName: displayName,
            createdAt: Date()
        )
    }
    
    // MARK: - Keychain Storage
    
    private static func loadFromKeychain() -> DeviceIdentity? {
        guard let deviceIDString = UserDefaults.standard.string(forKey: deviceIDKey),
              let deviceID = UUID(uuidString: deviceIDString),
              let privateKeyData = KeychainHelper.load(key: privateKeyKey),
              let privateKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        else {
            return nil
        }
        
        // Load or generate signing key
        let signingKey: P256.Signing.PrivateKey
        if let signingKeyData = KeychainHelper.load(key: signingKeyKey),
           let loadedSigningKey = try? P256.Signing.PrivateKey(rawRepresentation: signingKeyData) {
            signingKey = loadedSigningKey
        } else {
            // Generate signing key for existing devices without one
            signingKey = P256.Signing.PrivateKey()
            KeychainHelper.save(key: signingKeyKey, data: signingKey.rawRepresentation)
        }
        
        let displayName = UserDefaults.standard.string(forKey: displayNameKey) ?? UIDevice.current.name
        let createdAt = UserDefaults.standard.object(forKey: "\(deviceIDKey).createdAt") as? Date ?? Date()
        
        return DeviceIdentity(
            deviceID: deviceID,
            privateKey: privateKey,
            signingPrivateKey: signingKey,
            displayName: displayName,
            createdAt: createdAt
        )
    }
    
    private static func saveToKeychain(_ identity: DeviceIdentity) {
        UserDefaults.standard.set(identity.deviceID.uuidString, forKey: deviceIDKey)
        UserDefaults.standard.set(identity.displayName, forKey: displayNameKey)
        UserDefaults.standard.set(identity.createdAt, forKey: "\(deviceIDKey).createdAt")
        
        KeychainHelper.save(key: privateKeyKey, data: identity.privateKey.rawRepresentation)
        KeychainHelper.save(key: signingKeyKey, data: identity.signingPrivateKey.rawRepresentation)
    }
    
    // MARK: - Cryptographic Operations
    
    /// Perform ECDH key agreement with a peer's public key
    func deriveSharedSecret(with peerPublicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        return try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }
    
    /// Perform ECDH key agreement with raw public key data
    func deriveSharedSecret(with peerPublicKeyData: Data) throws -> SharedSecret {
        let peerPublicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyData)
        return try deriveSharedSecret(with: peerPublicKey)
    }
    
    /// Sign data using ECDSA
    func sign(_ data: Data) throws -> Data {
        let signature = try signingPrivateKey.signature(for: data)
        return signature.rawRepresentation
    }
    
    /// Update display name
    func updateDisplayName(_ name: String) {
        displayName = name
        UserDefaults.standard.set(name, forKey: DeviceIdentity.displayNameKey)
    }
}

// MARK: - Keychain Helper

private enum KeychainHelper {
    
    static func save(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        // Delete existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            MeshLogger.app.error("Keychain save failed: \(status)")
        }
    }
    
    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            return nil
        }
        
        return result as? Data
    }
    
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Codable Export (for sharing public info)

extension DeviceIdentity {
    
    struct PublicInfo: Codable {
        let deviceID: UUID
        let publicKey: Data
        let displayName: String
    }
    
    var publicInfo: PublicInfo {
        PublicInfo(
            deviceID: deviceID,
            publicKey: publicKeyData,
            displayName: displayName
        )
    }
}
