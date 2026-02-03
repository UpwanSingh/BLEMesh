import Foundation
import Combine

/// Manages message delivery confirmations and retries
final class DeliveryService: ObservableObject {
    
    // MARK: - Types
    
    enum DeliveryStatus {
        case pending
        case sent
        case delivered
        case failed
        case expired
    }
    
    struct TrackedMessage {
        let id: UUID
        let envelope: MessageEnvelope
        let destinationID: UUID
        var status: DeliveryStatus
        var retryCount: Int
        let createdAt: Date
        var lastAttempt: Date?
        var deliveredAt: Date?
    }
    
    // MARK: - Configuration
    
    struct Config {
        var maxRetries: Int = 3
        var baseRetryInterval: TimeInterval = 5.0   // Base interval for exponential backoff
        var ackTimeout: TimeInterval = 10.0
        var messageExpiry: TimeInterval = 300.0     // 5 minutes
        var maxBackoffInterval: TimeInterval = 60.0 // Cap at 1 minute
        
        /// Calculate retry interval with exponential backoff
        func retryInterval(for attempt: Int) -> TimeInterval {
            // Exponential backoff: base * 2^attempt with jitter
            let exponential = baseRetryInterval * pow(2.0, Double(attempt))
            let jitter = Double.random(in: 0...1) * baseRetryInterval // Add randomness to prevent thundering herd
            return min(exponential + jitter, maxBackoffInterval)
        }
        
        static let `default` = Config()
    }
    
    // MARK: - Published State
    
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var deliveredCount: Int = 0
    @Published private(set) var failedCount: Int = 0
    
    // MARK: - Properties
    
    private var trackedMessages: [UUID: TrackedMessage] = [:]
    private var ackCallbacks: [UUID: (Bool) -> Void] = [:]
    private let config: Config
    
    private let lock = NSLock()
    private var retryTimer: Timer?
    private var expiryTimer: Timer?
    
    // MARK: - Callbacks
    
    var onDeliveryConfirmed: ((UUID) -> Void)?
    var onDeliveryFailed: ((UUID) -> Void)?
    var onRetryNeeded: ((MessageEnvelope) -> Void)?
    
    // MARK: - Singleton
    
    static let shared = DeliveryService()
    
    // MARK: - Initialization
    
    init(config: Config = .default) {
        self.config = config
        startTimers()
        MeshLogger.message.info("DeliveryService initialized")
    }
    
    deinit {
        retryTimer?.invalidate()
        expiryTimer?.invalidate()
    }
    
    // MARK: - Public API
    
    /// Track a message for delivery confirmation
    func trackMessage(_ envelope: MessageEnvelope, to destinationID: UUID, completion: ((Bool) -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        
        let tracked = TrackedMessage(
            id: envelope.id,
            envelope: envelope,
            destinationID: destinationID,
            status: .sent,
            retryCount: 0,
            createdAt: Date(),
            lastAttempt: Date()
        )
        
        trackedMessages[envelope.id] = tracked
        
        if let callback = completion {
            ackCallbacks[envelope.id] = callback
        }
        
        updateCounts()
        
        MeshLogger.message.debug("Tracking message \(envelope.id.uuidString.prefix(8)) for delivery")
    }
    
    /// Handle incoming ACK
    func handleAck(_ ack: DeliveryAck) {
        lock.lock()
        defer { lock.unlock() }
        
        guard var tracked = trackedMessages[ack.messageID] else {
            MeshLogger.message.debug("ACK for unknown message: \(ack.messageID.uuidString.prefix(8))")
            return
        }
        
        tracked.status = .delivered
        tracked.deliveredAt = Date()
        trackedMessages[ack.messageID] = tracked
        
        // Callback
        if let callback = ackCallbacks.removeValue(forKey: ack.messageID) {
            DispatchQueue.main.async {
                callback(true)
            }
        }
        
        DispatchQueue.main.async {
            self.onDeliveryConfirmed?(ack.messageID)
        }
        
        updateCounts()
        
        MeshLogger.message.info("Delivery confirmed: \(ack.messageID.uuidString.prefix(8))")
    }
    
    /// Check if message was delivered
    func isDelivered(_ messageID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return trackedMessages[messageID]?.status == .delivered
    }
    
    /// Get delivery status
    func getStatus(_ messageID: UUID) -> DeliveryStatus? {
        lock.lock()
        defer { lock.unlock() }
        return trackedMessages[messageID]?.status
    }
    
    /// Cancel tracking for a message
    func cancelTracking(_ messageID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        
        trackedMessages.removeValue(forKey: messageID)
        ackCallbacks.removeValue(forKey: messageID)
        updateCounts()
    }
    
    // MARK: - Private Methods
    
    private func startTimers() {
        // Retry timer - checks for messages needing retry
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForRetries()
        }
        
        // Expiry timer - removes old messages
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.cleanupExpiredMessages()
        }
    }
    
    private func checkForRetries() {
        lock.lock()
        let now = Date()
        var messagesToRetry: [TrackedMessage] = []
        
        for (id, var tracked) in trackedMessages {
            guard tracked.status == .sent else { continue }
            
            // Calculate timeout with exponential backoff based on retry count
            let timeoutInterval = config.retryInterval(for: tracked.retryCount)
            
            // Check if retry timeout reached
            if let lastAttempt = tracked.lastAttempt,
               now.timeIntervalSince(lastAttempt) >= timeoutInterval {
                
                if tracked.retryCount < self.config.maxRetries {
                    // Schedule retry
                    tracked.retryCount += 1
                    tracked.lastAttempt = now
                    trackedMessages[id] = tracked
                    messagesToRetry.append(tracked)
                    
                    let nextInterval = config.retryInterval(for: tracked.retryCount)
                    MeshLogger.message.info("Scheduling retry \(tracked.retryCount)/\(self.config.maxRetries) for \(id.uuidString.prefix(8)) (next in \(Int(nextInterval))s)")
                } else {
                    // Max retries reached
                    tracked.status = .failed
                    trackedMessages[id] = tracked
                    
                    // Callback
                    if let callback = ackCallbacks.removeValue(forKey: id) {
                        DispatchQueue.main.async {
                            callback(false)
                        }
                    }
                    
                    DispatchQueue.main.async {
                        self.onDeliveryFailed?(id)
                    }
                    
                    MeshLogger.message.error("Delivery failed after \(self.config.maxRetries) retries: \(id.uuidString.prefix(8))")
                }
            }
        }
        
        lock.unlock()
        
        // Trigger retries outside lock
        for tracked in messagesToRetry {
            onRetryNeeded?(tracked.envelope)
        }
        
        updateCounts()
    }
    
    private func cleanupExpiredMessages() {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        var expiredIDs: [UUID] = []
        
        for (id, tracked) in trackedMessages {
            if now.timeIntervalSince(tracked.createdAt) >= config.messageExpiry {
                expiredIDs.append(id)
            }
        }
        
        for id in expiredIDs {
            if var tracked = trackedMessages[id] {
                if tracked.status == .sent || tracked.status == .pending {
                    tracked.status = .expired
                }
            }
            trackedMessages.removeValue(forKey: id)
            ackCallbacks.removeValue(forKey: id)
        }
        
        if !expiredIDs.isEmpty {
            MeshLogger.message.debug("Cleaned up \(expiredIDs.count) expired message(s)")
        }
        
        updateCounts()
    }
    
    private func updateCounts() {
        let counts = trackedMessages.values.reduce(into: (pending: 0, delivered: 0, failed: 0)) { result, tracked in
            switch tracked.status {
            case .pending, .sent:
                result.pending += 1
            case .delivered:
                result.delivered += 1
            case .failed, .expired:
                result.failed += 1
            }
        }
        
        DispatchQueue.main.async {
            self.pendingCount = counts.pending
            self.deliveredCount = counts.delivered
            self.failedCount = counts.failed
        }
    }
}
