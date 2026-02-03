import Foundation
import Combine
import CryptoKit

/// Enhanced service for message routing and relay with targeted delivery
final class MessageRelayService: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var receivedMessages: [MeshMessage] = []
    @Published private(set) var relayedCount: Int = 0
    @Published private(set) var duplicatesBlocked: Int = 0
    @Published private(set) var deliveredCount: Int = 0
    @Published private(set) var failedCount: Int = 0
    
    // MARK: - Callbacks
    
    var onMessageReceived: ((MeshMessage) -> Void)?
    var onGroupMessageReceived: ((MeshMessage, UUID) -> Void)?  // message, groupID
    var onDeliveryConfirmed: ((UUID) -> Void)?
    var onDeliveryFailed: ((UUID) -> Void)?
    
    /// Callback to get group key for decryption (set by ChatViewModel)
    var getGroupKey: ((UUID) -> SymmetricKey?)?
    
    /// Callback for persisting messages (set by ChatViewModel)
    var onPersistMessage: ((MeshMessage, UUID?) -> Void)?  // message, conversationID
    
    // MARK: - Dependencies
    
    private let bluetoothManager: BluetoothManager
    private let routingService: RoutingService
    private let deliveryService = DeliveryService.shared
    private let offlineQueue = OfflineQueueService.shared
    
    // MARK: - Private State
    
    /// Cache of seen message IDs to prevent duplicate processing
    private var seenMessageIDs: Set<String> = []
    private var messageTimestamps: [String: Date] = [:]
    
    /// Pending messages waiting for route discovery
    private var pendingMessages: [UUID: (MessageEnvelope, Int)] = [:] // envelope, retry count
    
    /// Messages awaiting acknowledgment
    private var awaitingAck: [UUID: Date] = [:]
    
    /// Chunk assembler for incoming data
    private let chunkAssembler = ChunkAssembler()
    
    private let lock = NSLock()
    private var cleanupTimer: Timer?
    
    // MARK: - Initialization
    
    init(bluetoothManager: BluetoothManager, routingService: RoutingService) {
        self.bluetoothManager = bluetoothManager
        self.routingService = routingService
        
        setupMessageHandling()
        setupPeerHandling()
        setupReliabilityServices()
        startCleanupTimer()
        
        MeshLogger.message.info("MessageRelayService initialized with routing")
    }
    
    deinit {
        cleanupTimer?.invalidate()
    }
    
    // MARK: - Reliability Setup
    
    private func setupReliabilityServices() {
        // Wire up DeliveryService retry
        deliveryService.onRetryNeeded = { [weak self] envelope in
            Task {
                try? await self?.sendEnvelope(envelope)
            }
        }
        
        deliveryService.onDeliveryFailed = { [weak self] messageID in
            DispatchQueue.main.async {
                self?.failedCount += 1
                self?.onDeliveryFailed?(messageID)
            }
        }
        
        // Wire up OfflineQueue flush when peer connects
        offlineQueue.onMessageReady = { [weak self] queued in
            guard let self = self else { return }
            
            // Try to deserialize and send
            if let envelope = try? MessageEnvelope.deserialize(from: queued.content) {
                Task {
                    try? await self.sendEnvelope(envelope)
                }
            }
        }
    }
    
    // MARK: - Public API
    
    /// Send a message to a specific device (routed)
    func sendDirectMessage(to destinationID: UUID, content: String) async throws {
        let payload = MessagePayload(text: content)
        let payloadData = try payload.serialize()
        
        let envelope = MessageEnvelope(
            originID: bluetoothManager.localDeviceID,
            originName: bluetoothManager.localDeviceName,
            destinationID: destinationID,
            content: payloadData
        )
        
        try await sendEnvelope(envelope)
    }
    
    /// Send a broadcast message to all reachable devices
    func sendBroadcastMessage(content: String) async throws {
        let payload = MessagePayload(text: content)
        let payloadData = try payload.serialize()
        
        let envelope = MessageEnvelope(
            originID: bluetoothManager.localDeviceID,
            originName: bluetoothManager.localDeviceName,
            destinationID: nil, // Broadcast
            content: payloadData
        )
        
        markAsSeen(envelope.messageHash)
        
        // Create legacy MeshMessage for UI
        var meshMessage = MeshMessage(
            id: envelope.id,
            senderID: envelope.originID.uuidString,
            senderName: envelope.originName,
            content: content,
            ttl: envelope.ttl,
            originID: envelope.id
        )
        meshMessage.isFromLocalDevice = true
        
        DispatchQueue.main.async {
            self.receivedMessages.append(meshMessage)
        }
        
        // Broadcast to all connected peers
        let data = try envelope.serialize()
        let chunks = ChunkCreator.createChunks(messageID: envelope.id, data: data)
        
        for chunk in chunks {
            let chunkData = try chunk.serialize()
            _ = bluetoothManager.broadcast(data: chunkData, excluding: [])
            
            if chunks.count > 1 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        
        MeshLogger.message.messageSent(
            id: envelope.id.uuidString.prefix(8).description,
            to: "broadcast",
            size: data.count
        )
    }
    
    /// Send an encrypted message to a specific device
    func sendEncryptedMessage(to destinationID: UUID, content: String) async throws {
        let securePayload = try SecureMessagePayload.encrypt(text: content, for: destinationID)
        let payloadData = try securePayload.serialize()
        
        let envelope = MessageEnvelope(
            originID: bluetoothManager.localDeviceID,
            originName: bluetoothManager.localDeviceName,
            destinationID: destinationID,
            content: payloadData,
            isEncrypted: true
        )
        
        try await sendEnvelope(envelope)
        
        // Create local message for UI
        var meshMessage = MeshMessage(
            id: envelope.id,
            senderID: envelope.originID.uuidString,
            senderName: envelope.originName,
            content: content,
            ttl: envelope.ttl,
            originID: envelope.id
        )
        meshMessage.isFromLocalDevice = true
        
        DispatchQueue.main.async {
            self.receivedMessages.append(meshMessage)
        }
        
        MeshLogger.message.info("Sent encrypted message to \(destinationID.uuidString.prefix(8))")
    }
    
    /// Send an encrypted group message to all group members
    func sendGroupMessage(
        to groupID: UUID,
        memberIDs: [UUID],
        content: String,
        groupKey: CryptoKit.SymmetricKey
    ) async throws {
        // Encrypt with group key
        let groupPayload = try GroupMessagePayload.encrypt(
            text: content,
            for: groupID,
            using: groupKey
        )
        let payloadData = try groupPayload.serialize()
        
        // Send to each member via their route
        for memberID in memberIDs where memberID != bluetoothManager.localDeviceID {
            let envelope = MessageEnvelope(
                originID: bluetoothManager.localDeviceID,
                originName: bluetoothManager.localDeviceName,
                destinationID: memberID,
                conversationID: groupID,  // Important: marks this as a group message
                content: payloadData,
                isEncrypted: true,
                isGroupMessage: true
            )
            
            try await sendEnvelope(envelope)
        }
        
        MeshLogger.message.info("Sent group message to \(memberIDs.count - 1) members")
    }
    
    /// Legacy method - send message (maintains compatibility)
    func sendMessage(_ message: MeshMessage) async throws {
        try await sendBroadcastMessage(content: message.content)
    }
    
    /// Send a control message to a specific device (routed)
    func sendControlMessage(_ controlMessage: ControlMessage, to destinationID: UUID) async throws {
        let envelope = try MessageEnvelope(
            originID: bluetoothManager.localDeviceID,
            originName: bluetoothManager.localDeviceName,
            controlMessage: controlMessage
        )
        
        // For control messages, we need to manually set destination
        let targetedEnvelope = MessageEnvelope(
            originID: envelope.originID,
            originName: envelope.originName,
            destinationID: destinationID,
            content: envelope.payload,
            isEncrypted: false,
            isGroupMessage: false
        )
        
        try await sendEnvelope(targetedEnvelope)
    }
    
    // MARK: - Envelope Sending
    
    private func sendEnvelope(_ envelope: MessageEnvelope) async throws {
        markAsSeen(envelope.messageHash)
        
        guard let destinationID = envelope.destinationID else {
            // Broadcast
            try await broadcastEnvelope(envelope)
            return
        }
        
        // Track for delivery confirmation (direct messages only)
        if !envelope.isControlMessage {
            deliveryService.trackMessage(envelope, to: destinationID) { [weak self] success in
                if success {
                    self?.onDeliveryConfirmed?(envelope.id)
                }
            }
        }
        
        // Check for direct connection first
        if let directPeer = bluetoothManager.connectedPeers[destinationID] {
            try await sendToPeer(envelope, peer: directPeer)
            return
        }
        
        // Try to use existing route
        if let route = routingService.getRoute(to: destinationID),
           let nextPeer = bluetoothManager.connectedPeers[route.nextHopID] {
            try await sendToPeer(envelope, peer: nextPeer)
            routingService.routingTable.markRouteUsed(destinationID)
            return
        }
        
        // No route available - queue for offline delivery if not a control message
        if !envelope.isControlMessage {
            offlineQueue.enqueue(envelope, to: destinationID)
            MeshLogger.message.info("Queued message for offline delivery to \(destinationID.uuidString.prefix(8))")
        }
        
        // Discover route
        MeshLogger.message.info("No route to \(destinationID.uuidString.prefix(8)), initiating discovery")
        
        // Store pending message
        lock.lock()
        pendingMessages[envelope.id] = (envelope, 0)
        lock.unlock()
        
        routingService.discoverRoute(to: destinationID) { [weak self] route in
            guard let self = self else { return }
            
            self.lock.lock()
            let pending = self.pendingMessages.removeValue(forKey: envelope.id)
            self.lock.unlock()
            
            guard let (pendingEnvelope, _) = pending else { return }
            
            if let route = route,
               let nextPeer = self.bluetoothManager.connectedPeers[route.nextHopID] {
                Task {
                    do {
                        try await self.sendToPeer(pendingEnvelope, peer: nextPeer)
                    } catch {
                        MeshLogger.message.error("Failed to send after route discovery: \(error)")
                        self.onDeliveryFailed?(pendingEnvelope.id)
                    }
                }
            } else {
                MeshLogger.message.error("Route discovery failed for \(destinationID.uuidString.prefix(8))")
                self.onDeliveryFailed?(pendingEnvelope.id)
                
                DispatchQueue.main.async {
                    self.failedCount += 1
                }
            }
        }
    }
    
    private func sendToPeer(_ envelope: MessageEnvelope, peer: Peer) async throws {
        let data = try envelope.serialize()
        let chunks = ChunkCreator.createChunks(messageID: envelope.id, data: data)
        
        var failedChunks = 0
        let maxRetries = 2
        
        for chunk in chunks {
            let chunkData = try chunk.serialize()
            var sent = false
            
            // Retry chunk sending with backoff
            for attempt in 0..<maxRetries {
                if bluetoothManager.send(data: chunkData, to: peer) {
                    sent = true
                    break
                }
                
                // Brief delay before retry
                if attempt < maxRetries - 1 {
                    try await Task.sleep(nanoseconds: UInt64(50_000_000 * (attempt + 1))) // 50ms, 100ms
                }
            }
            
            if !sent {
                failedChunks += 1
                MeshLogger.chunk.error("Failed to send chunk \(chunk.chunkIndex)/\(chunk.totalChunks) for message \(envelope.id.uuidString.prefix(8)) after \(maxRetries) attempts")
            } else {
                MeshLogger.chunk.chunkSent(
                    messageId: envelope.id.uuidString.prefix(8).description,
                    index: chunk.chunkIndex,
                    total: chunk.totalChunks
                )
            }
            
            if chunks.count > 1 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        
        // If any chunks failed, notify delivery failure
        if failedChunks > 0 {
            MeshLogger.message.error("Message \(envelope.id.uuidString.prefix(8)) had \(failedChunks) failed chunks out of \(chunks.count)")
            // Still track for ACK - peer might receive enough to reconstruct
        }
        
        // Track for ACK
        lock.lock()
        awaitingAck[envelope.id] = Date()
        lock.unlock()
        
        MeshLogger.message.messageSent(
            id: envelope.id.uuidString.prefix(8).description,
            to: peer.name,
            size: data.count
        )
    }
    
    private func broadcastEnvelope(_ envelope: MessageEnvelope) async throws {
        let data = try envelope.serialize()
        let chunks = ChunkCreator.createChunks(messageID: envelope.id, data: data)
        
        for chunk in chunks {
            let chunkData = try chunk.serialize()
            _ = bluetoothManager.broadcast(data: chunkData, excluding: [])
            
            if chunks.count > 1 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        
        MeshLogger.message.messageSent(
            id: envelope.id.uuidString.prefix(8).description,
            to: "broadcast",
            size: data.count
        )
    }
    
    // MARK: - Message Receiving
    
    private func setupMessageHandling() {
        bluetoothManager.onMessageReceived = { [weak self] data, peer in
            self?.handleIncomingData(data, from: peer)
        }
    }
    
    private func setupPeerHandling() {
        bluetoothManager.onPeerConnected = { [weak self] peer in
            self?.routingService.registerDirectPeer(peer)
            // Announce ourselves through new connection
            self?.routingService.announceSelf()
            
            // Flush offline queue for this peer
            self?.offlineQueue.flushForDestination(peer.id)
            
            // Notify that peer is now reachable
            self?.offlineQueue.networkStatusChanged(isConnected: true)
        }
    }
    
    private func handleIncomingData(_ data: Data, from peer: Peer) {
        do {
            let chunk = try MessageChunk.deserialize(from: data)
            
            if let completeData = chunkAssembler.addChunk(chunk) {
                processCompleteEnvelope(completeData, from: peer)
            }
        } catch {
            MeshLogger.chunk.error("Failed to process chunk: \(error)")
        }
    }
    
    private func processCompleteEnvelope(_ data: Data, from peer: Peer) {
        do {
            let envelope = try MessageEnvelope.deserialize(from: data)
            
            // Atomic check-and-mark to prevent race condition
            if checkAndMarkSeen(envelope.messageHash) {
                DispatchQueue.main.async {
                    self.duplicatesBlocked += 1
                }
                MeshLogger.relay.debug("Duplicate blocked: \(envelope.id.uuidString.prefix(8))")
                return
            }
            
            // Handle control messages
            if envelope.isControlMessage {
                if let controlMessage = try envelope.getControlMessage() {
                    routingService.handleControlMessage(controlMessage, from: peer)
                }
                return
            }
            
            // Is this message for us?
            let isForUs = envelope.isFor(deviceID: bluetoothManager.localDeviceID)
            
            if isForUs {
                // Process the message
                processUserMessage(envelope, from: peer)
                
                // Send ACK for direct messages
                if envelope.destinationID != nil {
                    sendAck(for: envelope, via: peer)
                }
            }
            
            // Relay to other peers if broadcast or TTL allows
            if envelope.isBroadcast || !isForUs {
                Task {
                    await relayEnvelope(envelope, excludingPeer: peer)
                }
            }
            
        } catch {
            MeshLogger.message.error("Failed to process envelope: \(error)")
        }
    }
    
    private func processUserMessage(_ envelope: MessageEnvelope, from peer: Peer) {
        // Verify signature first
        guard envelope.verifySignature() else {
            MeshLogger.message.error("Message signature verification failed - rejecting message")
            return
        }
        
        // Replay protection: check and update sequence number
        guard EncryptionService.shared.checkAndUpdateSequence(from: envelope.originID, sequenceNumber: envelope.sequenceNumber) else {
            MeshLogger.message.warning("Replay attack blocked - message from \(envelope.originName) has old sequence number")
            return
        }
        
        do {
            var content: String
            var groupID: UUID? = nil
            
            // Check if this is a group message
            if envelope.isGroupMessage, let _ = envelope.conversationID {
                // Group message - decrypt with group key
                let groupPayload = try GroupMessagePayload.deserialize(from: envelope.payload)
                groupID = groupPayload.groupID
                
                guard let groupKey = getGroupKey?(groupPayload.groupID) else {
                    MeshLogger.message.error("No group key for group \(groupPayload.groupID.uuidString.prefix(8))")
                    return
                }
                
                content = try groupPayload.decrypt(using: groupKey)
                MeshLogger.message.debug("Decrypted group message from \(envelope.originName)")
                
            } else if envelope.isEncrypted {
                // Direct encrypted message - decrypt with session key
                let securePayload = try SecureMessagePayload.deserialize(from: envelope.payload)
                content = try securePayload.decrypt(from: envelope.originID)
                MeshLogger.message.debug("Decrypted message from \(envelope.originName)")
            } else {
                // Regular unencrypted message
                let payload = try MessagePayload.deserialize(from: envelope.payload)
                content = payload.text
            }
            
            var meshMessage = MeshMessage(
                id: envelope.id,
                senderID: envelope.originID.uuidString,
                senderName: envelope.originName,
                content: content,
                timestamp: envelope.timestamp,
                ttl: envelope.ttl,
                originID: envelope.id
            )
            meshMessage.conversationID = envelope.conversationID
            
            DispatchQueue.main.async {
                self.receivedMessages.append(meshMessage)
                
                // Persist the message
                self.onPersistMessage?(meshMessage, envelope.conversationID)
                
                if let gid = groupID {
                    self.onGroupMessageReceived?(meshMessage, gid)
                } else {
                    self.onMessageReceived?(meshMessage)
                }
            }
            
            MeshLogger.message.messageReceived(
                id: envelope.id.uuidString.prefix(8).description,
                from: envelope.originName,
                size: envelope.payload.count
            )
            
        } catch {
            MeshLogger.message.error("Failed to decode message payload: \(error)")
        }
    }
    
    private func sendAck(for envelope: MessageEnvelope, via peer: Peer) {
        let ack = DeliveryAck(
            messageID: envelope.id,
            receiverID: bluetoothManager.localDeviceID
        )
        
        do {
            let controlMsg = try ControlMessage(type: .ack, content: ack)
            let ackEnvelope = try MessageEnvelope(
                originID: bluetoothManager.localDeviceID,
                originName: bluetoothManager.localDeviceName,
                controlMessage: controlMsg,
                ttl: envelope.hopPath.count + 1
            )
            
            let data = try ackEnvelope.serialize()
            let chunks = ChunkCreator.createChunks(messageID: ackEnvelope.id, data: data)
            
            for chunk in chunks {
                if let chunkData = try? chunk.serialize() {
                    _ = bluetoothManager.send(data: chunkData, to: peer)
                }
            }
            
            MeshLogger.message.debug("Sent ACK for \(envelope.id.uuidString.prefix(8))")
        } catch {
            MeshLogger.message.error("Failed to send ACK: \(error)")
        }
    }
    
    // MARK: - Relay
    
    private func relayEnvelope(_ envelope: MessageEnvelope, excludingPeer: Peer) async {
        guard let forwardedEnvelope = envelope.forwarded(by: bluetoothManager.localDeviceID) else {
            MeshLogger.relay.info("Message \(envelope.id.uuidString.prefix(8)) reached TTL limit")
            return
        }
        
        do {
            let data = try forwardedEnvelope.serialize()
            let chunks = ChunkCreator.createChunks(messageID: forwardedEnvelope.id, data: data)
            
            // Determine where to send
            var targetPeers: [Peer] = []
            
            if let destinationID = envelope.destinationID {
                // Targeted message - use routing
                if let route = routingService.getRoute(to: destinationID),
                   let nextPeer = bluetoothManager.connectedPeers[route.nextHopID],
                   nextPeer.id != excludingPeer.id {
                    targetPeers = [nextPeer]
                }
            } else {
                // Broadcast - send to all except source
                targetPeers = bluetoothManager.getAllConnectedPeers()
                    .filter { $0.id != excludingPeer.id && !envelope.hopPath.contains($0.id) }
            }
            
            for peer in targetPeers {
                for chunk in chunks {
                    let chunkData = try chunk.serialize()
                    _ = bluetoothManager.send(data: chunkData, to: peer)
                    
                    if chunks.count > 1 {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                
                MeshLogger.relay.messageRelayed(
                    id: envelope.id.uuidString.prefix(8).description,
                    ttl: forwardedEnvelope.ttl,
                    to: peer.name
                )
            }
            
            if !targetPeers.isEmpty {
                DispatchQueue.main.async {
                    self.relayedCount += targetPeers.count
                }
            }
            
        } catch {
            MeshLogger.relay.error("Relay error: \(error)")
        }
    }
    
    // MARK: - Helpers
    
    private func hasSeenMessage(_ hash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seenMessageIDs.contains(hash)
    }
    
    private func markAsSeen(_ hash: String) {
        lock.lock()
        defer { lock.unlock() }
        seenMessageIDs.insert(hash)
        messageTimestamps[hash] = Date()
    }
    
    /// Atomic check-and-mark operation to prevent race conditions
    /// Returns true if message was already seen (duplicate), false if newly marked
    private func checkAndMarkSeen(_ hash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        if seenMessageIDs.contains(hash) {
            return true // Already seen (duplicate)
        }
        
        seenMessageIDs.insert(hash)
        messageTimestamps[hash] = Date()
        return false // Newly seen
    }
    
    func hasSeenMessage(_ id: UUID) -> Bool {
        hasSeenMessage("\(id.uuidString)-*")
    }
    
    // MARK: - Maintenance
    
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.performCleanup()
        }
    }
    
    private func performCleanup() {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        let expiry: TimeInterval = 300 // 5 minutes
        
        // Clean old seen messages
        let expiredHashes = messageTimestamps.filter {
            now.timeIntervalSince($0.value) > expiry
        }.map { $0.key }
        
        for hash in expiredHashes {
            seenMessageIDs.remove(hash)
            messageTimestamps.removeValue(forKey: hash)
        }
        
        // Clean old pending messages
        let expiredPending = pendingMessages.filter {
            now.timeIntervalSince($0.value.0.timestamp) > 30
        }.map { $0.key }
        
        for id in expiredPending {
            pendingMessages.removeValue(forKey: id)
        }
        
        // Clean old ACK tracking
        let expiredAcks = awaitingAck.filter {
            now.timeIntervalSince($0.value) > 30
        }.map { $0.key }
        
        for id in expiredAcks {
            awaitingAck.removeValue(forKey: id)
        }
        
        chunkAssembler.cleanupExpired()
    }
}
