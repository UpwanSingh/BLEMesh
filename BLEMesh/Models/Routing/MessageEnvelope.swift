import Foundation

/// Enhanced message envelope with routing support (Unencrypted Version)
struct MessageEnvelope: Codable, Identifiable {
    let id: UUID                        // Unique message ID
    let originID: UUID                  // Original sender device ID
    let originName: String              // Sender's display name
    let destinationID: UUID?            // nil = broadcast to all
    let conversationID: UUID?           // nil = not part of conversation
    let timestamp: Date
    let sequenceNumber: UInt64          // Monotonically increasing per sender
    var ttl: Int
    var hopPath: [UUID]                 // Track route taken
    
    // Payload
    let isControlMessage: Bool          // true = routing control, false = user message
    let isEncrypted: Bool               // Always false in this version
    let isGroupMessage: Bool            // true = group chat message
    let payload: Data                   // Plaintext content or control message
    
    // Legacy field - always nil
    let signature: Data?
    
    // For duplicate detection across relays
    var messageHash: String {
        "\(id.uuidString)-\(originID.uuidString)-\(sequenceNumber)"
    }
    
    // MARK: - Sequence Number Management
    
    private static var _sequenceCounter: UInt64 = loadSequenceNumber()
    private static let sequenceLock = NSLock()
    
    private static func nextSequenceNumber() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        _sequenceCounter += 1
        saveSequenceNumber(_sequenceCounter)
        return _sequenceCounter
    }
    
    private static func loadSequenceNumber() -> UInt64 {
        UInt64(UserDefaults.standard.integer(forKey: "mesh.sequenceNumber"))
    }
    
    private static func saveSequenceNumber(_ value: UInt64) {
        UserDefaults.standard.set(Int(value), forKey: "mesh.sequenceNumber")
    }
    
    // MARK: - Initializers
    
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
        self.id = UUID()
        self.originID = originID
        self.originName = originName
        self.destinationID = destinationID
        self.conversationID = conversationID
        self.timestamp = Date()
        self.sequenceNumber = Self.nextSequenceNumber()
        self.ttl = ttl
        self.hopPath = [originID]
        self.isControlMessage = false
        self.isEncrypted = false // Force false
        self.isGroupMessage = isGroupMessage
        self.payload = content
        self.signature = nil
    }
    
    init(
        originID: UUID,
        originName: String,
        controlMessage: ControlMessage,
        ttl: Int = BLEConstants.maxTTL
    ) throws {
        self.id = UUID()
        self.originID = originID
        self.originName = originName
        self.destinationID = nil
        self.conversationID = nil
        self.timestamp = Date()
        self.sequenceNumber = Self.nextSequenceNumber()
        self.ttl = ttl
        self.hopPath = [originID]
        self.isControlMessage = true
        self.isEncrypted = false
        self.isGroupMessage = false
        self.payload = try controlMessage.serialize()
        self.signature = nil
    }
    
    // MARK: - Routing
    
    func isFor(deviceID: UUID) -> Bool {
        destinationID == nil || destinationID == deviceID
    }
    
    var isBroadcast: Bool {
        destinationID == nil
    }
    
    func forwarded(by nodeID: UUID) -> MessageEnvelope? {
        guard ttl > 1 else { return nil }
        var copy = self
        copy.ttl -= 1
        copy.hopPath.append(nodeID)
        return copy
    }
    
    func verifySignature() -> Bool {
        // No signature verification in unencrypted version
        return true
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
    
    func getControlMessage() throws -> ControlMessage? {
        guard isControlMessage else { return nil }
        return try ControlMessage.deserialize(from: payload)
    }
}

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
