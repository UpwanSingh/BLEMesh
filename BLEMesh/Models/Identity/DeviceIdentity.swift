import Foundation
import UIKit

/// Represents this device's permanent identity in the mesh network
final class DeviceIdentity: ObservableObject {
    
    // MARK: - Public Properties
    
    let deviceID: UUID
    @Published var displayName: String
    let createdAt: Date
    
    // Derived
    var shortID: String {
        deviceID.uuidString.prefix(8).description
    }
    
    // MARK: - Private
    
    private static let deviceIDKey = "mesh.device.id"
    private static let displayNameKey = "mesh.device.displayName"
    
    // MARK: - Singleton
    
    static let shared: DeviceIdentity = {
        return DeviceIdentity.loadOrCreate()
    }()
    
    // MARK: - Initialization
    
    private init(
        deviceID: UUID,
        displayName: String,
        createdAt: Date
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.createdAt = createdAt
    }
    
    // MARK: - Factory
    
    private static func loadOrCreate() -> DeviceIdentity {
        // Try to load existing identity
        if let identity = loadFromUserDefaults() {
            MeshLogger.app.info("Loaded existing device identity: \(identity.shortID)")
            return identity
        }
        
        // Create new identity
        let identity = createNew()
        saveToUserDefaults(identity)
        MeshLogger.app.info("Created new device identity: \(identity.shortID)")
        return identity
    }
    
    private static func createNew() -> DeviceIdentity {
        let deviceID = UUID()
        let displayName = UIDevice.current.name
        
        return DeviceIdentity(
            deviceID: deviceID,
            displayName: displayName,
            createdAt: Date()
        )
    }
    
    // MARK: - Storage
    
    private static func loadFromUserDefaults() -> DeviceIdentity? {
        guard let deviceIDString = UserDefaults.standard.string(forKey: deviceIDKey),
              let deviceID = UUID(uuidString: deviceIDString)
        else {
            return nil
        }
        
        let displayName = UserDefaults.standard.string(forKey: displayNameKey) ?? UIDevice.current.name
        let createdAt = UserDefaults.standard.object(forKey: "\(deviceIDKey).createdAt") as? Date ?? Date()
        
        return DeviceIdentity(
            deviceID: deviceID,
            displayName: displayName,
            createdAt: createdAt
        )
    }
    
    private static func saveToUserDefaults(_ identity: DeviceIdentity) {
        UserDefaults.standard.set(identity.deviceID.uuidString, forKey: deviceIDKey)
        UserDefaults.standard.set(identity.displayName, forKey: displayNameKey)
        UserDefaults.standard.set(identity.createdAt, forKey: "\(deviceIDKey).createdAt")
    }
    
    // MARK: - Operations
    
    /// Update display name
    func updateDisplayName(_ name: String) {
        displayName = name
        UserDefaults.standard.set(name, forKey: DeviceIdentity.displayNameKey)
    }
}

// MARK: - Codable Export (for sharing public info)

extension DeviceIdentity {
    
    struct PublicInfo: Codable {
        let deviceID: UUID
        let displayName: String
    }
    
    var publicInfo: PublicInfo {
        PublicInfo(
            deviceID: deviceID,
            displayName: displayName
        )
    }
}
