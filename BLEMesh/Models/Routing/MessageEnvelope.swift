import Foundation

/// Enhanced message envelope with routing support and replay protection
struct MessageEnvelope: Codable, Identifiable {
    let id: UUID                        // Unique message ID
    let originID: UUID                  // Original sender device ID
    let originName: String              // Sender's display name
    let destinationID: UUID?            // nil = broadcast to all
    let conversationID: UUID?           // nil = not part of conversation
    let timestamp: Date
    let sequenceNumber: UInt64          // Replay protection - monotonically increasing per sender
    var ttl: Int
    var hopPath: [UUID]                 // Track route taken
    
    // Payload
    let isControlMessage: Bool          // true = routing control, false = user message
    let isEncrypted: Bool               // true = payload is encrypted
    let isGroupMessage: Bool            // true = group chat message
    let payload: Data                   // Encrypted content or control message
    
    // Signature (ECDSA signature of header fields including sequence number)
    let signature: Data?
    
    // For duplicate detection across relays
    var messageHash: String {
        "\(id.uuidString)-\(originID.uuidString)-\(sequenceNumber)"
    }
    
    // MARK: - Sequence Number Management
    
    /// Thread-safe sequence number counter
    private static var _sequenceCounter: UInt64 = loadSequenceNumber()
    private static let sequenceLock = NSLock()
    
    /// Get next sequence number (thread-safe, persisted)
    private static func nextSequenceNumber() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        
        _sequenceCounter += 1
        saveSequenceNumber(_sequenceCounter)
        return _sequenceCounter
    }
    
    /// Load sequence number from UserDefaults
    private static func loadSequenceNumber() -> UInt64 {
        UInt64(UserDefaults.standard.integer(forKey: "mesh.sequenceNumber"))
    }
    
    /// Save sequence number to UserDefaults
    private static func saveSequenceNumber(_ value: UInt64) {
        UserDefaults.standard.set(Int(value), forKey: "mesh.sequenceNumber")
    }
    
    // MARK: - Initializers
    
    /// Create a user message envelope (with auto-signing and sequence number)
    init(
        originID: UUID,
        originName: String,
        destinationID: UUID?,
        conversationID: UUID? = nil,
        content: Data,
        isEncrypted: Bool = false,
        isGroupMessage: Bool = false,
        ttl: Int = BLEConstants.maxTTL
    ) {
        let msgID = UUID()
        let ts = Date()
        let seqNum = Self.nextSequenceNumber()
        
        self.id = msgID
        self.originID = originID
        self.originName = originName
        self.destinationID = destinationID
        self.conversationID = conversationID
        self.timestamp = ts
        self.sequenceNumber = seqNum
        self.ttl = ttl
        self.hopPath = [originID]
        self.isControlMessage = false
        self.isEncrypted = isEncrypted
        self.isGroupMessage = isGroupMessage
        self.payload = content
        
        // Sign the header (including sequence number)
        self.signature = try? EncryptionService.shared.signEnvelopeHeader(
            id: msgID,
            originID: originID,
            destinationID: destinationID,
            timestamp: ts,
            sequenceNumber: seqNum
        )
    }
    
    /// Create a control message envelope (with auto-signing and sequence number)
    init(
        originID: UUID,
        originName: String,
        controlMessage: ControlMessage,
        ttl: Int = BLEConstants.maxTTL
    ) throws {
        let msgID = UUID()
        let ts = Date()
        let seqNum = Self.nextSequenceNumber()
        
        self.id = msgID
        self.originID = originID
        self.originName = originName
        self.destinationID = nil
        self.conversationID = nil
        self.timestamp = ts
        self.sequenceNumber = seqNum
        self.ttl = ttl
        self.hopPath = [originID]
        self.isControlMessage = true
        self.isEncrypted = false
        self.isGroupMessage = false
        self.payload = try controlMessage.serialize()
        
        // Sign the header (including sequence number)
        self.signature = try? EncryptionService.shared.signEnvelopeHeader(
            id: msgID,
            originID: originID,
            destinationID: nil,
            timestamp: ts,
            sequenceNumber: seqNum
        )
    }
    
    // MARK: - Routing
    
    /// Check if message is for a specific device
    func isFor(deviceID: UUID) -> Bool {
        destinationID == nil || destinationID == deviceID
    }
    
    /// Check if this is a broadcast message
    var isBroadcast: Bool {
        destinationID == nil
    }
    
    /// Create a forwarded copy with updated hop info
    func forwarded(by nodeID: UUID) -> MessageEnvelope? {
        guard ttl > 1 else { return nil }
        
        var copy = self
        copy.ttl -= 1
        copy.hopPath.append(nodeID)
        return copy
    }
    
    /// Verify the signature is valid from the claimed origin
    func verifySignature() -> Bool {
        guard let sig = signature else {
            MeshLogger.message.warning("No signature on message from \(originID.uuidString.prefix(8))")
            return true // Allow unsigned messages for backward compatibility
        }
        
        do {
            return try EncryptionService.shared.verifyEnvelopeSignature(
                signature: sig,
                id: id,
                originID: originID,
                destinationID: destinationID,
                timestamp: timestamp,
                sequenceNumber: sequenceNumber,
                from: originID
            )
        } catch {
            MeshLogger.message.error("Signature verification failed: \(error)")
            return false
        }
    }
    
    // MARK: - Serialization
    
    func serialize() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    
    static func deserialize(from data: Data) throws -> MessageEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MessageEnvelope.self, from: data)
    }
    
    /// Extract control message if this is one
    func getControlMessage() throws -> ControlMessage? {
        guard isControlMessage else { return nil }
        return try ControlMessage.deserialize(from: payload)
    }
}

/// User-facing message content (inside envelope payload)
struct MessagePayload: Codable {
    let text: String
    let replyToID: UUID?
    let metadata: [String: String]?
    
    init(text: String, replyToID: UUID? = nil, metadata: [String: String]? = nil) {
        self.text = text
        self.replyToID = replyToID
        self.metadata = metadata
    }
    
    func serialize() throws -> Data {
        try JSONEncoder().encode(self)
    }
    
    static func deserialize(from data: Data) throws -> MessagePayload {
        try JSONDecoder().decode(MessagePayload.self, from: data)
    }
}
