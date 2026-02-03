import Foundation
import Security

/// Service for secure storage of sensitive data in the iOS Keychain
final class KeychainService {
    
    // MARK: - Singleton
    
    static let shared = KeychainService()
    
    // MARK: - Types
    
    enum KeychainError: Error, LocalizedError {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
        case dataConversionFailed
        case itemNotFound
        
        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Keychain save failed with status: \(status)"
            case .loadFailed(let status):
                return "Keychain load failed with status: \(status)"
            case .deleteFailed(let status):
                return "Keychain delete failed with status: \(status)"
            case .dataConversionFailed:
                return "Failed to convert data"
            case .itemNotFound:
                return "Item not found in keychain"
            }
        }
    }
    
    // MARK: - Constants
    
    private let serviceIdentifier = "com.blemesh.keychain"
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Save data to keychain
    func save(_ data: Data, forKey key: String) throws {
        // Delete existing item first
        try? delete(forKey: key)
        
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceIdentifier,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            MeshLogger.app.error("Keychain save failed for key \(key): \(status)")
            throw KeychainError.saveFailed(status)
        }
        
        MeshLogger.app.debug("Saved to keychain: \(key)")
    }
    
    /// Load data from keychain
    func load(forKey key: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceIdentifier,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.loadFailed(status)
        }
        
        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }
        
        return data
    }
    
    /// Delete data from keychain
    func delete(forKey key: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceIdentifier,
            kSecAttrAccount: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    /// Check if key exists in keychain
    func exists(forKey key: String) -> Bool {
        do {
            _ = try load(forKey: key)
            return true
        } catch {
            return false
        }
    }
    
    /// Save codable object to keychain
    func save<T: Encodable>(_ object: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(object)
        try save(data, forKey: key)
    }
    
    /// Load codable object from keychain
    func load<T: Decodable>(forKey key: String) throws -> T {
        let data = try load(forKey: key)
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    // MARK: - Group Key Specific Methods
    
    private let groupKeysKey = "mesh.group.keys"
    
    /// Save all group keys (mapping of groupID to key data)
    func saveGroupKeys(_ keys: [UUID: Data]) throws {
        let keysDict = Dictionary(uniqueKeysWithValues: keys.map { ($0.key.uuidString, $0.value) })
        let data = try JSONEncoder().encode(keysDict)
        try save(data, forKey: groupKeysKey)
    }
    
    /// Load all group keys
    func loadGroupKeys() throws -> [UUID: Data] {
        let data = try load(forKey: groupKeysKey)
        let keysDict = try JSONDecoder().decode([String: Data].self, from: data)
        return Dictionary(uniqueKeysWithValues: keysDict.compactMap { key, value in
            guard let uuid = UUID(uuidString: key) else { return nil }
            return (uuid, value)
        })
    }
    
    /// Save a single group key
    func saveGroupKey(_ keyData: Data, forGroupID groupID: UUID) throws {
        var keys = (try? loadGroupKeys()) ?? [:]
        keys[groupID] = keyData
        try saveGroupKeys(keys)
    }
    
    /// Delete a group key
    func deleteGroupKey(forGroupID groupID: UUID) throws {
        var keys = (try? loadGroupKeys()) ?? [:]
        keys.removeValue(forKey: groupID)
        try saveGroupKeys(keys)
    }
    
    // MARK: - Clear All
    
    /// Delete all keychain items for this service (use carefully)
    func deleteAll() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceIdentifier
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
        
        MeshLogger.app.info("Cleared all keychain items")
    }
}
