import Foundation
import SwiftData
import MeshCore

/// Conversation key conventions:
///   "nearby"              public broadcast channel
///   "dm:<peer hex>"       direct conversation (keyed by mesh PeerID, never a BLE identifier)
///   "group:<uuid>"        group conversation
///   "ai"                  Ask-the-mesh Q&A
enum ConversationKey {
    static let nearby = "nearby"
    static let askMesh = "ai"
    static func direct(_ peer: PeerID) -> String { "dm:\(peer.hex)" }
    static func group(_ id: UUID) -> String { "group:\(id.uuidString)" }

    static func peer(from key: String) -> PeerID? {
        guard key.hasPrefix("dm:") else { return nil }
        return PeerID(hex: String(key.dropFirst(3)))
    }

    static func groupID(from key: String) -> UUID? {
        guard key.hasPrefix("group:") else { return nil }
        return UUID(uuidString: String(key.dropFirst(6)))
    }
}

enum ConversationKind: Int, Codable {
    case nearby = 0, direct = 1, group = 2, askMesh = 3
}

@Model
final class StoredConversation {
    @Attribute(.unique) var key: String
    var kindRaw: Int
    var title: String
    var unreadCount: Int
    var updatedAt: Date
    var lastPreview: String

    init(key: String, kind: ConversationKind, title: String, updatedAt: Date = .now) {
        self.key = key
        self.kindRaw = kind.rawValue
        self.title = title
        self.unreadCount = 0
        self.updatedAt = updatedAt
        self.lastPreview = ""
    }

    var kind: ConversationKind { ConversationKind(rawValue: kindRaw) ?? .direct }
}

@Model
final class StoredMessage {
    /// Mesh message ID — identical on sender and receiver, used for receipts and dedup.
    @Attribute(.unique) var id: UUID
    var conversationKey: String
    var senderHex: String
    var senderName: String
    var isOutgoing: Bool
    /// JSON-encoded `MeshContent`.
    var contentData: Data
    var previewText: String
    var sentAt: Date
    var receivedAt: Date
    var hops: Int
    /// `DeliveryStatus` raw value (outgoing direct messages).
    var statusRaw: Int
    /// Incoming: whether we already told the sender we read it.
    var readReceiptSent: Bool

    init(id: UUID, conversationKey: String, senderHex: String, senderName: String, isOutgoing: Bool,
         content: MeshContent, sentAt: Date, receivedAt: Date = .now, hops: Int = 0,
         status: DeliveryStatus = .sent) {
        self.id = id
        self.conversationKey = conversationKey
        self.senderHex = senderHex
        self.senderName = senderName
        self.isOutgoing = isOutgoing
        self.contentData = (try? JSONEncoder().encode(content)) ?? Data()
        self.previewText = content.previewText
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.hops = hops
        self.statusRaw = status.rawValue
        self.readReceiptSent = false
    }

    var content: MeshContent? { try? JSONDecoder().decode(MeshContent.self, from: contentData) }

    var status: DeliveryStatus {
        get { DeliveryStatus(rawValue: statusRaw) ?? .sent }
        set { statusRaw = newValue.rawValue }
    }

    var sender: PeerID? { PeerID(hex: senderHex) }
}

enum PersistenceController {
    static let schema = Schema([StoredConversation.self, StoredMessage.self])

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration("BLEMesh", schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            MeshLogger.app.error("Persistent store failed (\(error.localizedDescription)); falling back to memory")
            return try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
    }
}
