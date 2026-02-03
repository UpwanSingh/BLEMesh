import Foundation
import Combine

/// Manages offline message queue for later delivery
final class OfflineQueueService: ObservableObject {
    
    // MARK: - Types
    
    struct QueuedMessage: Codable, Identifiable {
        let id: UUID
        let destinationID: UUID
        let content: Data
        let isEncrypted: Bool
        let createdAt: Date
        var retryCount: Int
        
        init(envelope: MessageEnvelope, destinationID: UUID) {
            self.id = envelope.id
            self.destinationID = destinationID
            self.content = (try? envelope.serialize()) ?? Data()
            self.isEncrypted = envelope.isEncrypted
            self.createdAt = Date()
            self.retryCount = 0
        }
    }
    
    // MARK: - Configuration
    
    struct Config {
        var maxQueueSize: Int = 100
        var maxRetries: Int = 5
        var messageExpiry: TimeInterval = 3600 // 1 hour
        var flushInterval: TimeInterval = 30.0
        
        static let `default` = Config()
    }
    
    // MARK: - Published State
    
    @Published private(set) var queueCount: Int = 0
    @Published private(set) var isFlushing: Bool = false
    
    // MARK: - Properties
    
    private var messageQueue: [QueuedMessage] = []
    private let config: Config
    private let lock = NSLock()
    private var flushTimer: Timer?
    
    // MARK: - Callbacks
    
    var onMessageReady: ((QueuedMessage) -> Void)?
    var onQueueEmpty: (() -> Void)?
    
    // MARK: - Persistence
    
    private let queueKey = "BLEMesh.OfflineQueue"
    
    // MARK: - Singleton
    
    static let shared = OfflineQueueService()
    
    // MARK: - Initialization
    
    init(config: Config = .default) {
        self.config = config
        loadQueue()
        startFlushTimer()
        
        MeshLogger.message.info("OfflineQueueService initialized with \(self.queueCount) queued messages")
    }
    
    deinit {
        flushTimer?.invalidate()
    }
    
    // MARK: - Public API
    
    /// Queue a message for later delivery
    func enqueue(_ envelope: MessageEnvelope, to destinationID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        
        // Check queue size
        if messageQueue.count >= config.maxQueueSize {
            // Remove oldest message
            messageQueue.removeFirst()
            MeshLogger.message.warning("Queue full, removed oldest message")
        }
        
        let queued = QueuedMessage(envelope: envelope, destinationID: destinationID)
        messageQueue.append(queued)
        
        saveQueue()
        updateCount()
        
        MeshLogger.message.info("Queued message \(envelope.id.uuidString.prefix(8)) for offline delivery")
    }
    
    /// Dequeue a message (mark as processed)
    func dequeue(_ messageID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        
        messageQueue.removeAll { $0.id == messageID }
        saveQueue()
        updateCount()
        
        if messageQueue.isEmpty {
            DispatchQueue.main.async {
                self.onQueueEmpty?()
            }
        }
    }
    
    /// Get all messages for a destination
    func messagesFor(destination: UUID) -> [QueuedMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messageQueue.filter { $0.destinationID == destination }
    }
    
    /// Flush queue for a specific destination
    func flushForDestination(_ destinationID: UUID) {
        lock.lock()
        let messagesToSend = messageQueue.filter { 
            $0.destinationID == destinationID && !isExpired($0) 
        }
        lock.unlock()
        
        guard !messagesToSend.isEmpty else { return }
        
        MeshLogger.message.info("Flushing \(messagesToSend.count) queued messages for \(destinationID.uuidString.prefix(8))")
        
        for message in messagesToSend {
            onMessageReady?(message)
            dequeue(message.id)
        }
    }
    
    /// Mark a message as having a retry attempt
    func markRetry(_ messageID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        
        if let index = messageQueue.firstIndex(where: { $0.id == messageID }) {
            messageQueue[index].retryCount += 1
            
            // Remove if max retries exceeded
            if messageQueue[index].retryCount >= config.maxRetries {
                messageQueue.remove(at: index)
                MeshLogger.message.warning("Message \(messageID.uuidString.prefix(8)) exceeded max retries, removed from queue")
            }
            
            saveQueue()
            updateCount()
        }
    }
    
    /// Flush queue - attempt to send all pending messages
    func flush() {
        lock.lock()
        let messagesToSend = messageQueue.filter { !isExpired($0) }
        lock.unlock()
        
        guard !messagesToSend.isEmpty else { return }
        
        DispatchQueue.main.async {
            self.isFlushing = true
        }
        
        MeshLogger.message.info("Flushing \(messagesToSend.count) queued messages")
        
        for message in messagesToSend {
            onMessageReady?(message)
        }
        
        DispatchQueue.main.async {
            self.isFlushing = false
        }
    }
    
    /// Clear all queued messages
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        messageQueue.removeAll()
        saveQueue()
        updateCount()
        
        MeshLogger.message.info("Offline queue cleared")
    }
    
    // MARK: - Private Methods
    
    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: config.flushInterval, repeats: true) { [weak self] _ in
            self?.cleanupExpired()
        }
    }
    
    private func cleanupExpired() {
        lock.lock()
        defer { lock.unlock() }
        
        let before = messageQueue.count
        messageQueue.removeAll { isExpired($0) }
        let removed = before - messageQueue.count
        
        if removed > 0 {
            saveQueue()
            updateCount()
            MeshLogger.message.debug("Removed \(removed) expired messages from queue")
        }
    }
    
    private func isExpired(_ message: QueuedMessage) -> Bool {
        Date().timeIntervalSince(message.createdAt) >= config.messageExpiry
    }
    
    private func updateCount() {
        DispatchQueue.main.async {
            self.queueCount = self.messageQueue.count
        }
    }
    
    // MARK: - Persistence
    
    private func saveQueue() {
        do {
            let data = try JSONEncoder().encode(messageQueue)
            UserDefaults.standard.set(data, forKey: queueKey)
        } catch {
            MeshLogger.message.error("Failed to save offline queue: \(error)")
        }
    }
    
    private func loadQueue() {
        guard let data = UserDefaults.standard.data(forKey: queueKey) else { return }
        
        do {
            messageQueue = try JSONDecoder().decode([QueuedMessage].self, from: data)
            cleanupExpired()
            updateCount()
        } catch {
            MeshLogger.message.error("Failed to load offline queue: \(error)")
        }
    }
}

// MARK: - Network Reachability Integration

extension OfflineQueueService {
    /// Called when a peer becomes available
    func peerBecameAvailable(_ peerID: UUID) {
        let messages = messagesFor(destination: peerID)
        
        guard !messages.isEmpty else { return }
        
        MeshLogger.message.info("Peer \(peerID.uuidString.prefix(8)) available, \(messages.count) queued messages")
        
        for message in messages {
            onMessageReady?(message)
        }
    }
    
    /// Called when any connectivity changes
    func networkStatusChanged(isConnected: Bool) {
        if isConnected {
            flush()
        }
    }
}
