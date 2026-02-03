import Foundation

/// Encrypted message payload sent over the mesh
struct SecureMessagePayload: Codable {
    let encryptedContent: Data
    let nonce: Data
    let tag: Data
    let senderPublicKey: Data  // For key exchange if needed
    
    /// Create encrypted payload for a specific recipient
    static func encrypt(
        text: String,
        for recipientID: UUID,
        using encryptionService: EncryptionService = .shared
    ) throws -> SecureMessagePayload {
        guard let textData = text.data(using: .utf8) else {
            throw EncryptionService.EncryptionError.encryptionFailed
        }
        
        let encrypted = try encryptionService.encrypt(textData, for: recipientID)
        
        return SecureMessagePayload(
            encryptedContent: encrypted.ciphertext,
            nonce: encrypted.nonce,
            tag: encrypted.tag,
            senderPublicKey: DeviceIdentity.shared.publicKeyData
        )
    }
    
    /// Decrypt payload from a specific sender
    func decrypt(
        from senderID: UUID,
        using encryptionService: EncryptionService = .shared
    ) throws -> String {
        // Store sender's public key if we don't have it
        if !encryptionService.hasSession(with: senderID) {
            try encryptionService.storePeerPublicKey(senderPublicKey, for: senderID)
        }
        
        let payload = EncryptionService.EncryptedPayload(
            ciphertext: encryptedContent,
            nonce: nonce,
            tag: tag
        )
        
        let decryptedData = try encryptionService.decrypt(payload, from: senderID)
        
        guard let text = String(data: decryptedData, encoding: .utf8) else {
            throw EncryptionService.EncryptionError.decryptionFailed
        }
        
        return text
    }
    
    /// Serialize to Data
    func serialize() throws -> Data {
        try JSONEncoder().encode(self)
    }
    
    /// Deserialize from Data
    static func deserialize(from data: Data) throws -> SecureMessagePayload {
        try JSONDecoder().decode(SecureMessagePayload.self, from: data)
    }
}

/// Enhanced envelope that supports encryption
extension MessageEnvelope {
    
    /// Create an encrypted direct message envelope
    static func encryptedDirect(
        to destinationID: UUID,
        content: String,
        originID: UUID,
        originName: String
    ) throws -> MessageEnvelope {
        // Encrypt the content
        let securePayload = try SecureMessagePayload.encrypt(text: content, for: destinationID)
        let payloadData = try securePayload.serialize()
        
        return MessageEnvelope(
            originID: originID,
            originName: originName,
            destinationID: destinationID,
            content: payloadData,
            isEncrypted: true
        )
    }
    
    /// Decrypt the payload if encrypted
    func decryptContent(from senderID: UUID) throws -> String {
        guard isEncrypted else {
            // Not encrypted, decode as plain MessagePayload
            let plainPayload = try MessagePayload.deserialize(from: payload)
            return plainPayload.text
        }
        
        let securePayload = try SecureMessagePayload.deserialize(from: payload)
        return try securePayload.decrypt(from: senderID)
    }
}

/// Group encryption support
struct GroupMessagePayload: Codable {
    let groupID: UUID
    let encryptedContent: Data
    let nonce: Data
    let tag: Data
    let senderID: UUID
    let senderName: String
    
    /// Encrypt message for a group
    static func encrypt(
        text: String,
        for groupID: UUID,
        using groupKey: CryptoKit.SymmetricKey
    ) throws -> GroupMessagePayload {
        guard let textData = text.data(using: .utf8) else {
            throw EncryptionService.EncryptionError.encryptionFailed
        }
        
        let encrypted = try EncryptionService.shared.encrypt(textData, with: groupKey)
        
        return GroupMessagePayload(
            groupID: groupID,
            encryptedContent: encrypted.ciphertext,
            nonce: encrypted.nonce,
            tag: encrypted.tag,
            senderID: DeviceIdentity.shared.deviceID,
            senderName: DeviceIdentity.shared.displayName
        )
    }
    
    /// Decrypt with group key
    func decrypt(using groupKey: CryptoKit.SymmetricKey) throws -> String {
        let payload = EncryptionService.EncryptedPayload(
            ciphertext: encryptedContent,
            nonce: nonce,
            tag: tag
        )
        
        let decryptedData = try EncryptionService.shared.decrypt(payload, with: groupKey)
        
        guard let text = String(data: decryptedData, encoding: .utf8) else {
            throw EncryptionService.EncryptionError.decryptionFailed
        }
        
        return text
    }
    
    func serialize() throws -> Data {
        try JSONEncoder().encode(self)
    }
    
    static func deserialize(from data: Data) throws -> GroupMessagePayload {
        try JSONDecoder().decode(GroupMessagePayload.self, from: data)
    }
}

// Add CryptoKit import support
import CryptoKit
