import Foundation
import Combine

/// Enhanced service for message routing and relay with targeted delivery (Plaintext Version)
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
    
    /// Callback for persisting messages (set by ChatViewModel)
    var onPersistMessage: ((MeshMessage, UUID?) -> Void)?  // message, conversationID
    
    // Added for compatibility with ChatViewModel although always nil now
    var getGroupKey: ((UUID) -> Any?)?
    
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
    
    // MARK: - Bitchat Relay Enhancement Properties
    
    /// Link identifier for ingress tracking
    private enum LinkID: Hashable {
        case peripheral(UUID)  // Peer ID when we're acting as central
        case central(UUID)     // Peer ID when we're acting as peripheral
    }
    
    /// Track which link each message arrived from (prevents echo)
    private var ingressByMessageID: [String: (link: LinkID, timestamp: Date)] = [:]
    
    /// Scheduled relay work items (for jitter and deduplication)
    private var scheduledRelays: [String: DispatchWorkItem] = [:]
    
    /// Store-and-forward queue for directed messages when links unavailable
    private var pendingDirectedRelays: [UUID: [String: (envelope: MessageEnvelope, enqueuedAt: Date)]] = [:]
    
    /// High degree threshold for adaptive relay behavior
    private let highDegreeThreshold = 5
    
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
        
        MeshLogger.message.info("MessageRelayService initialized (Unencrypted)")
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
        
        // Create MeshMessage for UI
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
        
        for chunk in chunks {
            let chunkData = try chunk.serialize()
            _ = bluetoothManager.send(data: chunkData, to: peer)
            
            if chunks.count > 1 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
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
            self?.routingService.announceSelf()
            self?.offlineQueue.flushForDestination(peer.id)
            self?.offlineQueue.networkStatusChanged(isConnected: true)
            // Flush any spooled directed messages for this peer
            self?.flushDirectedSpool(for: peer.id)
        }
    }
    
    private func handleIncomingData(_ data: Data, from peer: Peer) {
        do {
            let chunk = try MessageChunk.deserialize(from: data)
            if let completeData = chunkAssembler.addChunk(chunk) {
                // Determine link type for ingress tracking
                let linkID: LinkID = peer.peripheral != nil ? .peripheral(peer.id) : .central(peer.id)
                processCompleteEnvelope(completeData, from: peer, ingressLink: linkID)
            }
        } catch {
            MeshLogger.chunk.error("Failed to process chunk: \(error)")
        }
    }
    
    private func processCompleteEnvelope(_ data: Data, from peer: Peer, ingressLink: LinkID) {
        do {
            let envelope = try MessageEnvelope.deserialize(from: data)
            
            // Create message ID for deduplication and ingress tracking
            let messageID = makeMessageID(for: envelope)
            
            if checkAndMarkSeen(envelope.messageHash, messageID: messageID, ingressLink: ingressLink) {
                // Check if we should cancel scheduled relay in dense networks
                let connectedCount = bluetoothManager.getAllConnectedPeers().count
                if connectedCount > 2 {
                    lock.lock()
                    if let workItem = scheduledRelays.removeValue(forKey: messageID) {
                        workItem.cancel()
                        MeshLogger.relay.info("Cancelled duplicate relay for \(messageID.prefix(8))")
                    }
                    lock.unlock()
                }
                
                DispatchQueue.main.async {
                    self.duplicatesBlocked += 1
                }
                return
            }
            
            if envelope.isControlMessage {
                if let controlMessage = try envelope.getControlMessage() {
                    routingService.handleControlMessage(controlMessage, from: peer)
                }
                return
            }
            
            let isForUs = envelope.isFor(deviceID: bluetoothManager.localDeviceID)
            
            if isForUs {
                processUserMessage(envelope, from: peer)
                if envelope.destinationID != nil {
                    sendAck(for: envelope, via: peer)
                }
            }
            
            if envelope.isBroadcast || !isForUs {
                Task {
                    await relayEnvelopeWithJitter(envelope, excludingPeer: peer, messageID: messageID, ingressLink: ingressLink)
                }
            }
            
        } catch {
            MeshLogger.message.error("Failed to process envelope: \(error)")
        }
    }
    
    private func processUserMessage(_ envelope: MessageEnvelope, from peer: Peer) {
        do {
            let payload = try MessagePayload.deserialize(from: envelope.payload)
            let content = payload.text
            
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
                self.onPersistMessage?(meshMessage, envelope.conversationID)
                
                if envelope.isGroupMessage {
                    self.onGroupMessageReceived?(meshMessage, envelope.conversationID ?? UUID())
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
        } catch {
            MeshLogger.message.error("Failed to send ACK: \(error)")
        }
    }
    
    private func relayEnvelopeWithJitter(_ envelope: MessageEnvelope, excludingPeer: Peer, messageID: String, ingressLink: LinkID) async {
        // Get relay decision from controller
        let connectedPeers = bluetoothManager.getAllConnectedPeers()
        let degree = connectedPeers.count
        
        let decision = RelayController.decide(
            ttl: envelope.ttl,
            senderIsSelf: envelope.originID == bluetoothManager.localDeviceID,
            isEncrypted: envelope.isEncrypted,
            isDirectedEncrypted: envelope.isEncrypted && envelope.destinationID != nil,
            isFragment: false, // Chunks are handled separately
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            degree: degree,
            highDegreeThreshold: highDegreeThreshold
        )
        
        guard decision.shouldRelay else {
            MeshLogger.relay.debug("Relay suppressed for \(messageID.prefix(8))")
            return
        }
        
        // Schedule relay with jitter
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            // Remove from scheduled relays
            self.lock.lock()
            _ = self.scheduledRelays.removeValue(forKey: messageID)
            self.lock.unlock()
            
            // Execute relay
            Task {
                await self.executeRelay(envelope, excludingPeer: excludingPeer, ingressLink: ingressLink, newTTL: decision.newTTL)
            }
        }
        
        // Track the scheduled relay
        lock.lock()
        scheduledRelays[messageID] = workItem
        lock.unlock()
        
        // Schedule with jitter delay
        let delay = DispatchTimeInterval.milliseconds(decision.delayMs)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: workItem)
        
        MeshLogger.relay.debug("Scheduled relay for \(messageID.prefix(8)) with \(decision.delayMs)ms jitter")
    }
    
    private func executeRelay(_ envelope: MessageEnvelope, excludingPeer: Peer, ingressLink: LinkID, newTTL: Int) async {
        // Create forwarded envelope with new TTL
        guard var forwardedEnvelope = envelope.forwarded(by: bluetoothManager.localDeviceID) else {
            return
        }
        forwardedEnvelope.ttl = newTTL
        
        do {
            let data = try forwardedEnvelope.serialize()
            let chunks = ChunkCreator.createChunks(messageID: forwardedEnvelope.id, data: data)
            
            var targetPeers: [Peer] = []
            
            if let destinationID = envelope.destinationID {
                // Directed message - use routing
                if let route = routingService.getRoute(to: destinationID),
                   let nextPeer = bluetoothManager.connectedPeers[route.nextHopID],
                   nextPeer.id != excludingPeer.id {
                    targetPeers = [nextPeer]
                } else {
                    // No route - store and forward
                    spoolDirectedMessage(forwardedEnvelope, to: destinationID)
                    return
                }
            } else {
                // Broadcast - use K-of-N fanout with ingress exclusion
                let allPeers = bluetoothManager.getAllConnectedPeers()
                    .filter { $0.id != excludingPeer.id && !envelope.hopPath.contains($0.id) }
                
                // Exclude ingress link
                let peersExcludingIngress = allPeers.filter { peer in
                    switch ingressLink {
                    case .peripheral(let id):
                        return peer.id != id
                    case .central(let id):
                        return peer.id != id
                    }
                }
                
                // Apply K-of-N fanout for broadcasts
                targetPeers = selectDeterministicSubset(
                    peers: peersExcludingIngress,
                    k: subsetSizeForFanout(peersExcludingIngress.count),
                    seed: makeMessageID(for: envelope)
                )
            }
            
            // Send to selected peers
            for peer in targetPeers {
                for chunk in chunks {
                    let chunkData = try chunk.serialize()
                    _ = bluetoothManager.send(data: chunkData, to: peer)
                }
            }
            
            if !targetPeers.isEmpty {
                DispatchQueue.main.async {
                    self.relayedCount += targetPeers.count
                }
                MeshLogger.relay.info("Relayed to \(targetPeers.count) peers (K-of-N)")
            }
            
        } catch {
            MeshLogger.relay.error("Relay error: \(error)")
        }
    }
    
    // MARK: - Maintenance
    
    private func checkAndMarkSeen(_ hash: String, messageID: String, ingressLink: LinkID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        if seenMessageIDs.contains(hash) {
            return true
        }
        
        seenMessageIDs.insert(hash)
        messageTimestamps[hash] = Date()
        
        // Track ingress link
        ingressByMessageID[messageID] = (link: ingressLink, timestamp: Date())
        
        return false
    }
    
    private func markAsSeen(_ hash: String) {
        lock.lock()
        defer { lock.unlock() }
        seenMessageIDs.insert(hash)
        messageTimestamps[hash] = Date()
    }
    
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.performCleanup()
        }
    }
    
    private func performCleanup() {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        
        // Clean up expired message hashes (5 minutes)
        let expiredHashes = messageTimestamps.filter { now.timeIntervalSince($0.value) > 300 }.map { $0.key }
        for hash in expiredHashes {
            seenMessageIDs.remove(hash)
            messageTimestamps.removeValue(forKey: hash)
        }
        
        // Clean up old ingress records (5 minutes)
        let expiredIngress = ingressByMessageID.filter { now.timeIntervalSince($0.value.timestamp) > 300 }.map { $0.key }
        for id in expiredIngress {
            ingressByMessageID.removeValue(forKey: id)
        }
        
        // Clean up stale scheduled relays (> 2 seconds means something went wrong)
        let staleRelays = scheduledRelays.filter { _ in true } // Get all for safety
        for (id, _) in staleRelays {
            scheduledRelays.removeValue(forKey: id)
        }
        
        // Clean up old store-and-forward entries (30 seconds)
        for (peerID, messages) in pendingDirectedRelays {
            let freshMessages = messages.filter { now.timeIntervalSince($0.value.enqueuedAt) < 30 }
            if freshMessages.isEmpty {
                pendingDirectedRelays.removeValue(forKey: peerID)
            } else {
                pendingDirectedRelays[peerID] = freshMessages
            }
        }
        
        chunkAssembler.cleanupExpired()
    }
    
    // MARK: - Helper Methods
    
    /// Create deterministic message ID for tracking
    private func makeMessageID(for envelope: MessageEnvelope) -> String {
        return "\(envelope.originID.uuidString)-\(envelope.timestamp.timeIntervalSince1970)-\(envelope.id.uuidString.prefix(8))"
    }
    
    /// Calculate subset size for K-of-N fanout
    private func subsetSizeForFanout(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        // For N peers, relay to K = ceil(sqrt(N)) + 1 peers
        return Int(ceil(sqrt(Double(n)))) + 1
    }
    
    /// Select deterministic subset of peers using message ID as seed
    private func selectDeterministicSubset(peers: [Peer], k: Int, seed: String) -> [Peer] {
        guard k > 0 && !peers.isEmpty else { return [] }
        guard k < peers.count else { return peers }
        
        // Use seed hash to deterministically shuffle
        let seedHash = abs(seed.hashValue)
        var rng = SeededRandomNumberGenerator(seed: UInt64(seedHash))
        var shuffled = peers
        
        // Fisher-Yates shuffle with seeded RNG
        for i in (1..<shuffled.count).reversed() {
            let j = Int(rng.next() % UInt64(i + 1))
            shuffled.swapAt(i, j)
        }
        
        return Array(shuffled.prefix(k))
    }
    
    /// Store directed message when no route available
    private func spoolDirectedMessage(_ envelope: MessageEnvelope, to destinationID: UUID) {
        let messageID = makeMessageID(for: envelope)
        
        lock.lock()
        defer { lock.unlock() }
        
        var messages = pendingDirectedRelays[destinationID] ?? [:]
        if messages[messageID] == nil {
            messages[messageID] = (envelope: envelope, enqueuedAt: Date())
            pendingDirectedRelays[destinationID] = messages
            MeshLogger.relay.info("Spooled directed message for \(destinationID.uuidString.prefix(8))")
        }
    }
    
    /// Flush spooled messages for a destination
    private func flushDirectedSpool(for destinationID: UUID) {
        lock.lock()
        let messages = pendingDirectedRelays.removeValue(forKey: destinationID)
        lock.unlock()
        
        guard let messages = messages else { return }
        
        MeshLogger.relay.info("Flushing \(messages.count) spooled messages for \(destinationID.uuidString.prefix(8))")
        
        for (_, entry) in messages {
            Task {
                try? await sendEnvelope(entry.envelope)
            }
        }
    }
}

// MARK: - Seeded Random Number Generator

/// Simple LCG-based RNG for deterministic peer selection
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64
    
    init(seed: UInt64) {
        self.state = seed
    }
    
    mutating func next() -> UInt64 {
        // Linear Congruential Generator (LCG) constants
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
