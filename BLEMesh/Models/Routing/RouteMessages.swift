import Foundation

/// Types of control messages for mesh routing
enum ControlMessageType: String, Codable {
    case routeRequest = "RREQ"      // Find path to destination
    case routeReply = "RREP"        // Path found response
    case routeError = "RERR"        // Path broken notification
    case peerAnnounce = "ANNOUNCE"  // Periodic presence broadcast
    case ack = "ACK"                // Delivery acknowledgment
    case readReceipt = "READ"       // Message read confirmation
    case groupKeyDistribute = "GKD" // Group key distribution
}

/// Route Request - broadcast to find path to destination
struct RouteRequest: Codable {
    let requestID: UUID
    let originID: UUID              // Who initiated the request
    let destinationID: UUID         // Who we're looking for
    let originName: String          // Sender's display name
    var hopCount: Int               // Incremented at each hop
    var hopPath: [UUID]             // Track path taken (for reverse route)
    let timestamp: Date
    let ttl: Int
    
    init(
        originID: UUID,
        originName: String,
        destinationID: UUID,
        ttl: Int = BLEConstants.maxTTL
    ) {
        self.requestID = UUID()
        self.originID = originID
        self.originName = originName
        self.destinationID = destinationID
        self.hopCount = 0
        self.hopPath = [originID]
        self.timestamp = Date()
        self.ttl = ttl
    }
    
    /// Create a forwarded copy with incremented hop count
    func forwarded(by nodeID: UUID) -> RouteRequest? {
        guard hopCount < ttl else { return nil }
        var copy = self
        copy.hopCount += 1
        copy.hopPath.append(nodeID)
        return copy
    }
}

/// Route Reply - unicast back to origin with path info
struct RouteReply: Codable {
    let requestID: UUID             // Matches the RREQ
    let originID: UUID              // Who sent the RREQ (destination of RREP)
    let destinationID: UUID         // The found device (sender of RREP)
    let destinationName: String
    var hopCount: Int
    var hopPath: [UUID]             // Forward path from origin to destination
    let timestamp: Date
    
    init(
        requestID: UUID,
        originID: UUID,
        destinationID: UUID,
        destinationName: String,
        incomingPath: [UUID]
    ) {
        self.requestID = requestID
        self.originID = originID
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.hopCount = 0
        self.hopPath = incomingPath.reversed() // Reverse to get forward path
        self.timestamp = Date()
    }
    
    /// Create forwarded copy
    func forwarded() -> RouteReply {
        var copy = self
        copy.hopCount += 1
        return copy
    }
}

/// Route Error - notify that a path is broken
struct RouteError: Codable {
    let errorID: UUID
    let unreachableID: UUID         // The device that's unreachable
    let reporterID: UUID            // Who detected the break
    let affectedDestinations: [UUID] // All destinations using this link
    let timestamp: Date
    
    init(unreachableID: UUID, reporterID: UUID, affectedDestinations: [UUID] = []) {
        self.errorID = UUID()
        self.unreachableID = unreachableID
        self.reporterID = reporterID
        self.affectedDestinations = affectedDestinations
        self.timestamp = Date()
    }
}

/// Peer announcement for presence broadcast
struct PeerAnnounce: Codable {
    let deviceID: UUID
    let deviceName: String
    let timestamp: Date
    var hopCount: Int
    
    init(deviceID: UUID, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.timestamp = Date()
        self.hopCount = 0
    }
    
    func forwarded() -> PeerAnnounce? {
        guard hopCount < 2 else { return nil } // Limit announce propagation
        var copy = self
        copy.hopCount += 1
        return copy
    }
}

/// Delivery acknowledgment
struct DeliveryAck: Codable {
    let messageID: UUID
    let receiverID: UUID
    let timestamp: Date
    
    init(messageID: UUID, receiverID: UUID) {
        self.messageID = messageID
        self.receiverID = receiverID
        self.timestamp = Date()
    }
}

/// Read receipt - confirms message was read by recipient
struct ReadReceipt: Codable {
    let messageID: UUID             // The message that was read
    let readerID: UUID              // Who read it
    let originalSenderID: UUID      // Who sent the original message
    let timestamp: Date
    
    init(messageID: UUID, readerID: UUID, originalSenderID: UUID) {
        self.messageID = messageID
        self.readerID = readerID
        self.originalSenderID = originalSenderID
        self.timestamp = Date()
    }
}

/// Group key distribution message
struct GroupKeyDistribute: Codable {
    let groupID: UUID
    let groupName: String
    let memberIDs: [UUID]           // All group members
    let encryptedKey: Data          // Group key encrypted for recipient
    let nonce: Data
    let tag: Data
    let senderID: UUID
    let timestamp: Date
    
    init(
        groupID: UUID,
        groupName: String,
        memberIDs: [UUID],
        encryptedKey: Data,
        nonce: Data,
        tag: Data,
        senderID: UUID
    ) {
        self.groupID = groupID
        self.groupName = groupName
        self.memberIDs = memberIDs
        self.encryptedKey = encryptedKey
        self.nonce = nonce
        self.tag = tag
        self.senderID = senderID
        self.timestamp = Date()
    }
}

/// Wrapper for all control messages
struct ControlMessage: Codable {
    let type: ControlMessageType
    let payload: Data
    
    init<T: Codable>(type: ControlMessageType, content: T) throws {
        self.type = type
        self.payload = try JSONEncoder().encode(content)
    }
    
    func decode<T: Codable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
    
    func serialize() throws -> Data {
        try JSONEncoder().encode(self)
    }
    
    static func deserialize(from data: Data) throws -> ControlMessage {
        try JSONDecoder().decode(ControlMessage.self, from: data)
    }
}
