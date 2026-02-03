import Foundation
import CoreBluetooth

/// BLE Service and Characteristic UUIDs for mesh communication
enum BLEConstants {
    /// Main mesh service UUID
    static let meshServiceUUID = CBUUID(string: "12345678-1234-5678-1234-567812345678")
    
    /// Characteristic for sending/receiving messages
    static let messageCharacteristicUUID = CBUUID(string: "12345678-1234-5678-1234-567812345679")
    
    /// Characteristic for device identification
    static let deviceIDCharacteristicUUID = CBUUID(string: "12345678-1234-5678-1234-56781234567A")
    
    /// Characteristic for public key exchange (ECDH)
    static let publicKeyCharacteristicUUID = CBUUID(string: "12345678-1234-5678-1234-56781234567B")
    
    /// Characteristic for signing public key exchange (ECDSA)
    static let signingKeyCharacteristicUUID = CBUUID(string: "12345678-1234-5678-1234-56781234567C")
    
    /// Maximum TTL for message relay
    static let maxTTL: Int = 3
    
    /// Default BLE MTU size (conservative)
    static let defaultMTU: Int = 182
    
    /// Chunk header size (messageID + chunkIndex + totalChunks + flags)
    static let chunkHeaderSize: Int = 20
    
    /// Maximum payload per chunk
    static var maxPayloadPerChunk: Int {
        return defaultMTU - chunkHeaderSize
    }
    
    /// Scan interval in seconds
    static let scanInterval: TimeInterval = 1.0
    
    /// Connection timeout
    static let connectionTimeout: TimeInterval = 10.0
    
    /// Message cache expiry time
    static let messageCacheExpiry: TimeInterval = 300 // 5 minutes
    
    /// Reconnect delay
    static let reconnectDelay: TimeInterval = 2.0
    
    /// Maximum reconnect attempts
    static let maxReconnectAttempts: Int = 3
    
    /// Local device name prefix
    static let deviceNamePrefix = "BLEMesh"
}

/// Message flags for chunk transmission
struct MessageFlags: OptionSet {
    let rawValue: UInt8
    
    static let isFirstChunk = MessageFlags(rawValue: 1 << 0)
    static let isLastChunk = MessageFlags(rawValue: 1 << 1)
    static let requiresAck = MessageFlags(rawValue: 1 << 2)
    static let isRelayed = MessageFlags(rawValue: 1 << 3)
    static let isEncrypted = MessageFlags(rawValue: 1 << 4)
}
