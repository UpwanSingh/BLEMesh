import Foundation
import CryptoKit

/// Represents a conversation (direct or group chat)
final class Conversation: ObservableObject, Identifiable {
    
    // MARK: - Properties
    
    let id: UUID
    let type: ConversationType
    var participantIDs: Set<UUID>
    @Published var name: String
    @Published var lastMessage: MeshMessage?
    @Published var unreadCount: Int = 0
    let createdAt: Date
    @Published var updatedAt: Date
    
    // For groups
    private(set) var groupKey: SymmetricKey?
    
    /// External access to update group key data
    var groupKeyData: Data? {
        get {
            return groupKey?.withUnsafeBytes { Data($0) }
        }
        set {
            if let data = newValue {
                groupKey = SymmetricKey(data: data)
            } else {
                groupKey = nil
            }
        }
    }
    
    // MARK: - Types
    
    enum ConversationType: String, Codable {
        case direct     // 1:1 chat
        case group      // Multi-party
    }
    
    // MARK: - Initialization
    
    /// Create a direct (1:1) conversation
    init(with peerID: UUID, peerName: String) {
        self.id = UUID()
        self.type = .direct
        self.participantIDs = [DeviceIdentity.shared.deviceID, peerID]
        self.name = peerName
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    /// Create a group conversation
    init(groupName: String, members: Set<UUID>) {
        self.id = UUID()
        self.type = .group
        self.participantIDs = members.union([DeviceIdentity.shared.deviceID])
        self.name = groupName
        self.createdAt = Date()
        self.updatedAt = Date()
        self.groupKey = EncryptionService.shared.generateGroupKey()
    }
    
    /// Restore from storage
    init(
        id: UUID,
        type: ConversationType,
        participantIDs: Set<UUID>,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        groupKeyData keyData: Data? = nil
    ) {
        self.id = id
        self.type = type
        self.participantIDs = participantIDs
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        
        if let data = keyData {
            self.groupKey = SymmetricKey(data: data)
        }
    }
    
    // MARK: - Public API
    
    /// Get the peer ID for a direct conversation
    var peerID: UUID? {
        guard type == .direct else { return nil }
        return participantIDs.first { $0 != DeviceIdentity.shared.deviceID }
    }
    
    /// Get other participants (excluding self)
    var otherParticipants: Set<UUID> {
        participantIDs.subtracting([DeviceIdentity.shared.deviceID])
    }
    
    /// Mark conversation as read
    func markAsRead() {
        unreadCount = 0
    }
    
    /// Update with a new message
    func updateWithMessage(_ message: MeshMessage) {
        lastMessage = message
        updatedAt = Date()
        
        if !message.isFromLocalDevice {
            unreadCount += 1
        }
    }
    
    /// Rotate group key (call when member leaves)
    func rotateGroupKey() -> SymmetricKey? {
        guard type == .group else { return nil }
        groupKey = EncryptionService.shared.generateGroupKey()
        return groupKey
    }
}

// MARK: - Hashable & Equatable

extension Conversation: Hashable {
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Codable Support

extension Conversation {
    
    struct StorageModel: Codable {
        let id: UUID
        let type: ConversationType
        let participantIDs: [UUID]
        let name: String
        let createdAt: Date
        let updatedAt: Date
        let groupKeyData: Data?
    }
    
    var storageModel: StorageModel {
        StorageModel(
            id: id,
            type: type,
            participantIDs: Array(participantIDs),
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
            groupKeyData: groupKeyData
        )
    }
    
    convenience init(from model: StorageModel) {
        self.init(
            id: model.id,
            type: model.type,
            participantIDs: Set(model.participantIDs),
            name: model.name,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt,
            groupKeyData: model.groupKeyData
        )
    }
}
