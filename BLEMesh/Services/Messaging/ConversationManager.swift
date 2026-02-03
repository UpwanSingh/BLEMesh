import Foundation
import Combine

/// Manages all conversations (direct and group)
@MainActor
final class ConversationManager: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var activeConversation: Conversation?
    
    // MARK: - Private
    
    private var messagesByConversation: [UUID: [MeshMessage]] = [:]
    private let storageKey = "mesh.conversations"
    
    // MARK: - Singleton
    
    static let shared = ConversationManager()
    
    // MARK: - Initialization
    
    private init() {
        loadConversations()
        MeshLogger.app.info("ConversationManager initialized with \(self.conversations.count) conversations")
    }
    
    // MARK: - Conversation Management
    
    /// Get or create a direct conversation with a peer
    func getOrCreateDirectConversation(with peerID: UUID, peerName: String) -> Conversation {
        // Check for existing
        if let existing = conversations.first(where: {
            $0.type == .direct && $0.participantIDs.contains(peerID)
        }) {
            return existing
        }
        
        // Create new
        let conversation = Conversation(with: peerID, peerName: peerName)
        conversations.append(conversation)
        sortConversations()
        saveConversations()
        
        MeshLogger.message.info("Created direct conversation with: \(peerName)")
        return conversation
    }
    
    /// Create a new group conversation
    func createGroupConversation(name: String, members: Set<UUID>) -> Conversation {
        let conversation = Conversation(groupName: name, members: members)
        conversations.append(conversation)
        sortConversations()
        saveConversations()
        
        MeshLogger.message.info("Created group: \(name) with \(members.count) members")
        return conversation
    }
    
    /// Get conversation by ID
    func conversation(byID id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }
    
    /// Get conversation for a peer
    func conversation(forPeer peerID: UUID) -> Conversation? {
        conversations.first {
            $0.type == .direct && $0.participantIDs.contains(peerID)
        }
    }
    
    /// Delete a conversation
    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        messagesByConversation.removeValue(forKey: conversation.id)
        saveConversations()
        
        if activeConversation?.id == conversation.id {
            activeConversation = nil
        }
        
        MeshLogger.message.info("Deleted conversation: \(conversation.name)")
    }
    
    /// Set active conversation
    func setActiveConversation(_ conversation: Conversation?) {
        activeConversation = conversation
        conversation?.markAsRead()
    }
    
    // MARK: - Message Management
    
    /// Add a message to a conversation
    func addMessage(_ message: MeshMessage, to conversationID: UUID) {
        guard let conversation = conversation(byID: conversationID) else {
            MeshLogger.message.warning("Message for unknown conversation: \(conversationID)")
            return
        }
        
        if messagesByConversation[conversationID] == nil {
            messagesByConversation[conversationID] = []
        }
        
        // Check for duplicates (safe optional access)
        guard messagesByConversation[conversationID]?.contains(where: { $0.id == message.id }) != true else {
            return
        }
        
        messagesByConversation[conversationID]?.append(message)
        messagesByConversation[conversationID]?.sort { $0.timestamp < $1.timestamp }
        
        conversation.updateWithMessage(message)
        sortConversations()
    }
    
    /// Route incoming message to appropriate conversation
    func routeIncomingMessage(_ message: MeshMessage, from senderID: UUID, groupID: UUID? = nil) {
        if let groupID = groupID {
            // Group message
            if let conversation = conversation(byID: groupID) {
                addMessage(message, to: conversation.id)
            }
        } else {
            // Direct message
            let conversation = getOrCreateDirectConversation(with: senderID, peerName: message.senderName)
            addMessage(message, to: conversation.id)
        }
    }
    
    /// Get messages for a conversation
    func messages(for conversationID: UUID) -> [MeshMessage] {
        messagesByConversation[conversationID] ?? []
    }
    
    /// Get unread count across all conversations
    var totalUnreadCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }
    
    // MARK: - Persistence
    
    private func loadConversations() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }
        
        do {
            let models = try JSONDecoder().decode([Conversation.StorageModel].self, from: data)
            conversations = models.map { Conversation(from: $0) }
            sortConversations()
        } catch {
            MeshLogger.app.error("Failed to load conversations: \(error.localizedDescription)")
        }
    }
    
    private func saveConversations() {
        do {
            let models = conversations.map { $0.storageModel }
            let data = try JSONEncoder().encode(models)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            MeshLogger.app.error("Failed to save conversations: \(error.localizedDescription)")
        }
    }
    
    private func sortConversations() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Group Management

extension ConversationManager {
    
    /// Add member to group
    func addMember(_ memberID: UUID, to groupID: UUID) {
        // Note: For actual groups, we'd need to modify the Conversation model
        // to support mutable participants. For now, this is a placeholder.
        MeshLogger.message.info("Adding member to group (not fully implemented)")
    }
    
    /// Remove member from group
    func removeMember(_ memberID: UUID, from groupID: UUID) {
        guard let conversation = conversation(byID: groupID),
              conversation.type == .group else {
            return
        }
        
        // Rotate group key when member leaves
        if conversation.rotateGroupKey() != nil {
            // Would need to distribute new key to remaining members
            MeshLogger.message.info("Rotated group key after member removal")
        }
        
        saveConversations()
    }
}
