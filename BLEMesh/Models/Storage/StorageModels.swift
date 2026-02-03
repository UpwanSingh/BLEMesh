import Foundation
import SwiftData

/// SwiftData model for persisted messages
@Model
final class PersistedMessage {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var senderID: UUID
    var senderName: String
    var content: String
    var timestamp: Date
    var ttl: Int
    var hopCount: Int
    var isFromLocalDevice: Bool
    var isEncrypted: Bool
    var deliveryStatus: DeliveryStatus
    
    enum DeliveryStatus: Int, Codable {
        case pending = 0
        case sent = 1
        case delivered = 2
        case read = 3
        case failed = 4
    }
    
    init(
        id: UUID = UUID(),
        conversationID: UUID,
        senderID: UUID,
        senderName: String,
        content: String,
        timestamp: Date = Date(),
        ttl: Int = 3,
        hopCount: Int = 0,
        isFromLocalDevice: Bool = false,
        isEncrypted: Bool = false,
        deliveryStatus: DeliveryStatus = .pending
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.senderName = senderName
        self.content = content
        self.timestamp = timestamp
        self.ttl = ttl
        self.hopCount = hopCount
        self.isFromLocalDevice = isFromLocalDevice
        self.isEncrypted = isEncrypted
        self.deliveryStatus = deliveryStatus
    }
    
    /// Convert to MeshMessage for UI
    func toMeshMessage() -> MeshMessage {
        var msg = MeshMessage(
            id: id,
            senderID: senderID.uuidString,
            senderName: senderName,
            content: content,
            timestamp: timestamp,
            ttl: ttl,
            originID: id
        )
        msg.isFromLocalDevice = isFromLocalDevice
        return msg
    }
}

/// SwiftData model for persisted conversations
@Model
final class PersistedConversation {
    @Attribute(.unique) var id: UUID
    var typeRaw: Int // 0 = direct, 1 = group
    var participantIDs: [UUID]
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var groupKeyData: Data?
    var unreadCount: Int
    
    var type: ConversationType {
        get { ConversationType(rawValue: typeRaw) ?? .direct }
        set { typeRaw = newValue.rawValue }
    }
    
    enum ConversationType: Int {
        case direct = 0
        case group = 1
    }
    
    init(
        id: UUID = UUID(),
        type: ConversationType,
        participantIDs: [UUID],
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        groupKeyData: Data? = nil,
        unreadCount: Int = 0
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.participantIDs = participantIDs
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.groupKeyData = groupKeyData
        self.unreadCount = unreadCount
    }
}

/// SwiftData model for persisted peer info
@Model
final class PersistedPeer {
    @Attribute(.unique) var deviceID: UUID
    var displayName: String
    var publicKeyData: Data?
    var lastSeen: Date
    var trustLevel: Int // 0 = unknown, 1 = seen, 2 = verified
    
    init(
        deviceID: UUID,
        displayName: String,
        publicKeyData: Data? = nil,
        lastSeen: Date = Date(),
        trustLevel: Int = 0
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.publicKeyData = publicKeyData
        self.lastSeen = lastSeen
        self.trustLevel = trustLevel
    }
}
