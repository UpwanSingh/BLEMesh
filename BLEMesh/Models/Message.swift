import Foundation

/// Delivery status for messages
enum MessageDeliveryStatus: Int, Codable {
    case pending = 0    // Queued, not yet sent
    case sent = 1       // Sent to network
    case delivered = 2  // ACK received
    case read = 3       // Read receipt received
    case failed = 4     // Delivery failed after retries
}

/// Represents a mesh message
struct MeshMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let senderID: String
    let senderName: String
    let content: String
    let timestamp: Date
    var ttl: Int
    let originID: UUID // Original message ID for tracking relays
    
    var isFromLocalDevice: Bool = false
    var conversationID: UUID? = nil // Group or conversation ID if applicable
    var deliveryStatus: MessageDeliveryStatus = .pending
    
    enum CodingKeys: String, CodingKey {
        case id, senderID, senderName, content, timestamp, ttl, originID, conversationID, deliveryStatus
    }
    
    init(
        id: UUID = UUID(),
        senderID: String,
        senderName: String,
        content: String,
        timestamp: Date = Date(),
        ttl: Int = BLEConstants.maxTTL,
        originID: UUID? = nil,
        deliveryStatus: MessageDeliveryStatus = .pending
    ) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.content = content
        self.timestamp = timestamp
        self.ttl = ttl
        self.originID = originID ?? id
        self.deliveryStatus = deliveryStatus
    }
    
    /// Create a relayed copy with decremented TTL
    func relayed() -> MeshMessage? {
        guard ttl > 1 else { return nil }
        var copy = self
        copy.ttl = ttl - 1
        return copy
    }
    
    /// Serialize to Data for transmission
    func serialize() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    
    /// Deserialize from Data
    static func deserialize(from data: Data) throws -> MeshMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeshMessage.self, from: data)
    }
}

// MARK: - Message Chunk for transmission

struct MessageChunk: Codable {
    let messageID: UUID
    let chunkIndex: Int
    let totalChunks: Int
    let flags: UInt8
    let payload: Data
    
    var isFirstChunk: Bool {
        MessageFlags(rawValue: flags).contains(.isFirstChunk)
    }
    
    var isLastChunk: Bool {
        MessageFlags(rawValue: flags).contains(.isLastChunk)
    }
    
    func serialize() throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(self)
    }
    
    static func deserialize(from data: Data) throws -> MessageChunk {
        let decoder = JSONDecoder()
        return try decoder.decode(MessageChunk.self, from: data)
    }
}

// MARK: - Chunk Assembler

final class ChunkAssembler {
    private var pendingChunks: [UUID: [Int: MessageChunk]] = [:]
    private var expectedCounts: [UUID: Int] = [:]
    private var timestamps: [UUID: Date] = [:]
    
    /// Add a chunk and return assembled data if complete
    func addChunk(_ chunk: MessageChunk) -> Data? {
        let messageID = chunk.messageID
        
        // Initialize storage if needed
        if pendingChunks[messageID] == nil {
            pendingChunks[messageID] = [:]
            expectedCounts[messageID] = chunk.totalChunks
            timestamps[messageID] = Date()
        }
        
        // Store chunk
        pendingChunks[messageID]?[chunk.chunkIndex] = chunk
        
        MeshLogger.chunk.chunkReceived(
            messageId: messageID.uuidString.prefix(8).description,
            index: chunk.chunkIndex,
            total: chunk.totalChunks
        )
        
        // Check if complete
        guard let chunks = pendingChunks[messageID],
              chunks.count == chunk.totalChunks else {
            return nil
        }
        
        // Assemble in order
        var assembledData = Data()
        for i in 0..<chunk.totalChunks {
            guard let c = chunks[i] else {
                MeshLogger.chunk.error("Missing chunk \(i) for message \(messageID)")
                return nil
            }
            assembledData.append(c.payload)
        }
        
        // Clean up
        cleanup(messageID: messageID)
        
        return assembledData
    }
    
    /// Clean up expired pending chunks
    func cleanupExpired() {
        let now = Date()
        let expiredIDs = timestamps.filter { 
            now.timeIntervalSince($0.value) > BLEConstants.messageCacheExpiry 
        }.map { $0.key }
        
        for id in expiredIDs {
            cleanup(messageID: id)
        }
    }
    
    private func cleanup(messageID: UUID) {
        pendingChunks.removeValue(forKey: messageID)
        expectedCounts.removeValue(forKey: messageID)
        timestamps.removeValue(forKey: messageID)
    }
}

// MARK: - Chunk Creator

enum ChunkCreator {
    /// Split data into chunks for transmission
    static func createChunks(messageID: UUID, data: Data, mtu: Int = BLEConstants.defaultMTU) -> [MessageChunk] {
        let maxPayload = mtu - BLEConstants.chunkHeaderSize
        guard maxPayload > 0 else {
            MeshLogger.chunk.error("MTU too small: \(mtu)")
            return []
        }
        
        var chunks: [MessageChunk] = []
        var offset = 0
        let totalChunks = Int(ceil(Double(data.count) / Double(maxPayload)))
        
        while offset < data.count {
            let end = min(offset + maxPayload, data.count)
            let payload = data.subdata(in: offset..<end)
            let chunkIndex = chunks.count
            
            var flags: MessageFlags = []
            if chunkIndex == 0 {
                flags.insert(.isFirstChunk)
            }
            if chunkIndex == totalChunks - 1 {
                flags.insert(.isLastChunk)
            }
            
            let chunk = MessageChunk(
                messageID: messageID,
                chunkIndex: chunkIndex,
                totalChunks: totalChunks,
                flags: flags.rawValue,
                payload: payload
            )
            chunks.append(chunk)
            offset = end
        }
        
        return chunks
    }
}
