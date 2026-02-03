import Foundation
import SwiftData
import Combine

/// Service for persistent storage using SwiftData
@MainActor
final class StorageService: ObservableObject {
    
    // MARK: - Types
    
    enum StorageError: Error, LocalizedError {
        case notReady
        case saveFailed(Error)
        case fetchFailed(Error)
        case deleteFailed(Error)
        
        var errorDescription: String? {
            switch self {
            case .notReady:
                return "Storage service not initialized"
            case .saveFailed(let error):
                return "Failed to save: \(error.localizedDescription)"
            case .fetchFailed(let error):
                return "Failed to fetch: \(error.localizedDescription)"
            case .deleteFailed(let error):
                return "Failed to delete: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Singleton
    
    static let shared = StorageService()
    
    // MARK: - Properties
    
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    
    @Published private(set) var isReady = false
    @Published private(set) var lastError: StorageError?
    
    // MARK: - Initialization
    
    private init() {
        setupStorage()
    }
    
    private func setupStorage() {
        do {
            let schema = Schema([
                PersistedMessage.self,
                PersistedConversation.self,
                PersistedPeer.self
            ])
            
            let configuration = ModelConfiguration(
                "BLEMeshStore",
                schema: schema,
                isStoredInMemoryOnly: false
            )
            
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            modelContext = modelContainer?.mainContext
            isReady = true
            
            MeshLogger.app.info("StorageService initialized successfully")
        } catch {
            MeshLogger.app.error("Failed to initialize storage: \(error)")
            lastError = .saveFailed(error)
        }
    }
    
    // MARK: - Private Helper
    
    private func save() -> Result<Void, StorageError> {
        guard let context = modelContext else {
            return .failure(.notReady)
        }
        
        do {
            try context.save()
            return .success(())
        } catch {
            MeshLogger.app.error("Storage save failed: \(error)")
            lastError = .saveFailed(error)
            return .failure(.saveFailed(error))
        }
    }
    
    // MARK: - Message Operations
    
    @discardableResult
    func saveMessage(_ message: PersistedMessage) -> Result<Void, StorageError> {
        guard let context = modelContext else {
            return .failure(.notReady)
        }
        context.insert(message)
        return save()
    }
    
    func getMessages(for conversationID: UUID, limit: Int = 100) -> [PersistedMessage] {
        guard let context = modelContext else { return [] }
        
        let predicate = #Predicate<PersistedMessage> { message in
            message.conversationID == conversationID
        }
        
        var descriptor = FetchDescriptor<PersistedMessage>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
        descriptor.fetchLimit = limit
        
        do {
            let messages = try context.fetch(descriptor)
            return messages.reversed()
        } catch {
            MeshLogger.app.error("Failed to fetch messages: \(error)")
            return []
        }
    }
    
    func getMessage(byID id: UUID) -> PersistedMessage? {
        guard let context = modelContext else { return nil }
        
        let predicate = #Predicate<PersistedMessage> { $0.id == id }
        var descriptor = FetchDescriptor<PersistedMessage>(predicate: predicate)
        descriptor.fetchLimit = 1
        
        return try? context.fetch(descriptor).first
    }
    
    @discardableResult
    func updateMessageStatus(_ messageID: UUID, status: PersistedMessage.DeliveryStatus) -> Result<Void, StorageError> {
        guard let message = getMessage(byID: messageID) else { 
            return .failure(.notReady) 
        }
        message.deliveryStatus = status
        return save()
    }
    
    @discardableResult
    func deleteMessage(_ messageID: UUID) -> Result<Void, StorageError> {
        guard let context = modelContext,
              let message = getMessage(byID: messageID) else { 
            return .failure(.notReady) 
        }
        context.delete(message)
        return save()
    }
    
    // MARK: - Conversation Operations
    
    @discardableResult
    func saveConversation(_ conversation: PersistedConversation) -> Result<Void, StorageError> {
        guard let context = modelContext else { 
            return .failure(.notReady) 
        }
        context.insert(conversation)
        return save()
    }
    
    func getAllConversations() -> [PersistedConversation] {
        guard let context = modelContext else { return [] }
        
        var descriptor = FetchDescriptor<PersistedConversation>()
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        
        return (try? context.fetch(descriptor)) ?? []
    }
    
    func getConversation(byID id: UUID) -> PersistedConversation? {
        guard let context = modelContext else { return nil }
        
        let predicate = #Predicate<PersistedConversation> { $0.id == id }
        var descriptor = FetchDescriptor<PersistedConversation>(predicate: predicate)
        descriptor.fetchLimit = 1
        
        return try? context.fetch(descriptor).first
    }
    
    func getDirectConversation(with peerID: UUID) -> PersistedConversation? {
        guard let context = modelContext else { return nil }
        
        let descriptor = FetchDescriptor<PersistedConversation>()
        
        do {
            let conversations = try context.fetch(descriptor)
            return conversations.first { conv in
                conv.type == .direct && conv.participantIDs.contains(peerID)
            }
        } catch {
            return nil
        }
    }
    
    @discardableResult
    func updateConversation(_ conversationID: UUID, lastMessageTime: Date) -> Result<Void, StorageError> {
        guard let conversation = getConversation(byID: conversationID) else { 
            return .failure(.notReady) 
        }
        conversation.updatedAt = lastMessageTime
        return save()
    }
    
    @discardableResult
    func incrementUnreadCount(_ conversationID: UUID) -> Result<Void, StorageError> {
        guard let conversation = getConversation(byID: conversationID) else { 
            return .failure(.notReady) 
        }
        conversation.unreadCount += 1
        return save()
    }
    
    @discardableResult
    func clearUnreadCount(_ conversationID: UUID) -> Result<Void, StorageError> {
        guard let conversation = getConversation(byID: conversationID) else { 
            return .failure(.notReady) 
        }
        conversation.unreadCount = 0
        return save()
    }
    
    /// Alias for clearUnreadCount
    @discardableResult
    func resetUnreadCount(_ conversationID: UUID) -> Result<Void, StorageError> {
        clearUnreadCount(conversationID)
    }
    
    @discardableResult
    func deleteConversation(_ conversationID: UUID) -> Result<Void, StorageError> {
        guard let context = modelContext,
              let conversation = getConversation(byID: conversationID) else { 
            return .failure(.notReady) 
        }
        
        // Delete all messages in conversation
        let messagePredicate = #Predicate<PersistedMessage> { $0.conversationID == conversationID }
        let messageDescriptor = FetchDescriptor<PersistedMessage>(predicate: messagePredicate)
        
        if let messages = try? context.fetch(messageDescriptor) {
            for message in messages {
                context.delete(message)
            }
        }
        
        context.delete(conversation)
        return save()
    }
    
    // MARK: - Peer Operations
    
    @discardableResult
    func savePeer(_ peer: PersistedPeer) -> Result<Void, StorageError> {
        guard let context = modelContext else { 
            return .failure(.notReady) 
        }
        context.insert(peer)
        return save()
    }
    
    func getPeer(byID deviceID: UUID) -> PersistedPeer? {
        guard let context = modelContext else { return nil }
        
        let predicate = #Predicate<PersistedPeer> { $0.deviceID == deviceID }
        var descriptor = FetchDescriptor<PersistedPeer>(predicate: predicate)
        descriptor.fetchLimit = 1
        
        return try? context.fetch(descriptor).first
    }
    
    func getAllPeers() -> [PersistedPeer] {
        guard let context = modelContext else { return [] }
        
        var descriptor = FetchDescriptor<PersistedPeer>()
        descriptor.sortBy = [SortDescriptor(\.lastSeen, order: .reverse)]
        
        return (try? context.fetch(descriptor)) ?? []
    }
    
    @discardableResult
    func updatePeerPublicKey(_ deviceID: UUID, publicKey: Data) -> Result<Void, StorageError> {
        if let peer = getPeer(byID: deviceID) {
            peer.publicKeyData = publicKey
            peer.trustLevel = max(peer.trustLevel, 1)
            return save()
        } else {
            let newPeer = PersistedPeer(
                deviceID: deviceID,
                displayName: deviceID.uuidString.prefix(8).description,
                publicKeyData: publicKey,
                trustLevel: 1
            )
            return savePeer(newPeer)
        }
    }
    
    @discardableResult
    func updatePeerName(_ deviceID: UUID, name: String) -> Result<Void, StorageError> {
        if let peer = getPeer(byID: deviceID) {
            peer.displayName = name
            peer.lastSeen = Date()
            return save()
        }
        return .failure(.notReady)
    }
    
    // MARK: - Cleanup
    
    @discardableResult
    func deleteOldMessages(olderThan days: Int = 30) -> Result<Int, StorageError> {
        guard let context = modelContext else { 
            return .failure(.notReady) 
        }
        
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = #Predicate<PersistedMessage> { $0.timestamp < cutoff }
        let descriptor = FetchDescriptor<PersistedMessage>(predicate: predicate)
        
        do {
            let oldMessages = try context.fetch(descriptor)
            let count = oldMessages.count
            for message in oldMessages {
                context.delete(message)
            }
            let result = save()
            switch result {
            case .success:
                MeshLogger.app.info("Deleted \(count) old messages")
                return .success(count)
            case .failure(let error):
                return .failure(error)
            }
        } catch {
            return .failure(.fetchFailed(error))
        }
    }
}
