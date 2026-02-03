import Foundation
import Combine

/// Service responsible for route discovery and maintenance
final class RoutingService: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var knownPeers: [UUID: PeerInfo] = [:]
    @Published private(set) var routeCount: Int = 0
    @Published private(set) var pendingDiscoveries: Int = 0
    
    struct PeerInfo {
        let deviceID: UUID
        var deviceName: String
        var hopCount: Int
        var lastSeen: Date
        var isDirect: Bool
    }
    
    // MARK: - Dependencies
    
    private weak var bluetoothManager: BluetoothManager?
    
    // MARK: - Internal State
    
    let routingTable = RoutingTable()
    private var seenRequestIDs = Set<UUID>()
    private var pendingRequests: [UUID: PendingRouteRequest] = [:]
    private var cleanupTimer: Timer?
    private let lock = NSLock()
    
    private struct PendingRouteRequest {
        let destinationID: UUID
        let startTime: Date
        var completion: ((RouteEntry?) -> Void)?
    }
    
    // MARK: - Callbacks
    
    var onRouteFound: ((UUID, RouteEntry) -> Void)?
    var onRouteLost: ((UUID) -> Void)?
    var sendData: ((Data, Peer?) -> Bool)?  // Injected send function
    var broadcastData: ((Data, Set<UUID>) -> Int)? // Broadcast to all except
    
    // MARK: - Initialization
    
    init() {
        startCleanupTimer()
        MeshLogger.relay.info("RoutingService initialized")
    }
    
    deinit {
        cleanupTimer?.invalidate()
    }
    
    func configure(bluetoothManager: BluetoothManager) {
        self.bluetoothManager = bluetoothManager
        
        // Set up callbacks
        self.sendData = { [weak bluetoothManager] data, peer in
            guard let peer = peer else { return false }
            return bluetoothManager?.send(data: data, to: peer) ?? false
        }
        
        self.broadcastData = { [weak bluetoothManager] data, excluding in
            bluetoothManager?.broadcast(data: data, excluding: excluding) ?? 0
        }
        
        // Listen for peer disconnections
        bluetoothManager.onPeerDisconnected = { [weak self] peer in
            self?.handlePeerDisconnected(peer)
        }
    }
    
    // MARK: - Public API
    
    /// Discover route to a destination device
    func discoverRoute(to destinationID: UUID, completion: @escaping (RouteEntry?) -> Void) {
        guard let bluetoothManager = bluetoothManager else {
            completion(nil)
            return
        }
        
        // Check if we already have a valid route
        if let existingRoute = routingTable.getRoute(to: destinationID) {
            MeshLogger.relay.info("Using cached route to \(destinationID.uuidString.prefix(8))")
            completion(existingRoute)
            return
        }
        
        // Check if destination is directly connected
        if bluetoothManager.connectedPeers[destinationID] != nil {
            let route = RouteEntry(
                destinationID: destinationID,
                nextHopID: destinationID,
                hopCount: 0,
                hopPath: [destinationID]
            )
            routingTable.updateRoute(route)
            completion(route)
            return
        }
        
        // Start route discovery
        initiateRouteRequest(to: destinationID, completion: completion)
    }
    
    /// Get route if available (non-blocking)
    func getRoute(to destinationID: UUID) -> RouteEntry? {
        routingTable.getRoute(to: destinationID)
    }
    
    /// Check if route exists
    func hasRoute(to destinationID: UUID) -> Bool {
        routingTable.hasRoute(to: destinationID)
    }
    
    /// Process incoming control message
    func handleControlMessage(_ controlMessage: ControlMessage, from peer: Peer) {
        switch controlMessage.type {
        case .routeRequest:
            handleRouteRequest(controlMessage, from: peer)
        case .routeReply:
            handleRouteReply(controlMessage, from: peer)
        case .routeError:
            handleRouteError(controlMessage, from: peer)
        case .peerAnnounce:
            handlePeerAnnounce(controlMessage, from: peer)
        case .ack:
            handleAck(controlMessage, from: peer)
        case .readReceipt:
            handleReadReceipt(controlMessage, from: peer)
        case .groupKeyDistribute:
            handleGroupKeyDistribute(controlMessage, from: peer)
        }
    }
    
    // MARK: - Read Receipts
    
    /// Callback for read receipt received (set by ChatViewModel)
    var onReadReceiptReceived: ((UUID, UUID) -> Void)?  // messageID, readerID
    
    private func handleReadReceipt(_ controlMessage: ControlMessage, from peer: Peer) {
        do {
            let receipt = try controlMessage.decode(ReadReceipt.self)
            
            // Only process if we're the original sender
            if receipt.originalSenderID == bluetoothManager?.localDeviceID {
                DispatchQueue.main.async {
                    self.onReadReceiptReceived?(receipt.messageID, receipt.readerID)
                }
                MeshLogger.relay.debug("Read receipt for message \(receipt.messageID.uuidString.prefix(8))")
            }
        } catch {
            MeshLogger.relay.error("Failed to decode read receipt: \(error)")
        }
    }
    
    // MARK: - Group Key Distribution
    
    /// Callback for group key received (set by ChatViewModel)
    var onGroupKeyReceived: ((UUID, String, [UUID], EncryptionService.EncryptedPayload, UUID) -> Void)?
    
    private func handleGroupKeyDistribute(_ controlMessage: ControlMessage, from peer: Peer) {
        do {
            let gkd = try controlMessage.decode(GroupKeyDistribute.self)
            
            // Convert to EncryptedPayload
            let encryptedPayload = EncryptionService.EncryptedPayload(
                ciphertext: gkd.encryptedKey,
                nonce: gkd.nonce,
                tag: gkd.tag
            )
            
            // Notify ChatViewModel to import the key
            DispatchQueue.main.async {
                self.onGroupKeyReceived?(
                    gkd.groupID,
                    gkd.groupName,
                    gkd.memberIDs,
                    encryptedPayload,
                    gkd.senderID
                )
            }
            
            MeshLogger.relay.info("Received group key for '\(gkd.groupName)' from \(gkd.senderID.uuidString.prefix(8))")
        } catch {
            MeshLogger.relay.error("Failed to decode group key distribute: \(error)")
        }
    }
    
    /// Register directly connected peer
    func registerDirectPeer(_ peer: Peer) {
        // Add direct route
        let route = RouteEntry(
            destinationID: peer.id,
            nextHopID: peer.id,
            hopCount: 0,
            hopPath: [peer.id]
        )
        routingTable.updateRoute(route)
        
        // Update known peers
        DispatchQueue.main.async {
            self.knownPeers[peer.id] = PeerInfo(
                deviceID: peer.id,
                deviceName: peer.name,
                hopCount: 0,
                lastSeen: Date(),
                isDirect: true
            )
            self.routeCount = self.routingTable.count
        }
        
        MeshLogger.relay.info("Registered direct peer: \(peer.name)")
    }
    
    /// Broadcast peer announcement
    func announceSelf() {
        guard let bluetoothManager = bluetoothManager else { return }
        
        let announce = PeerAnnounce(
            deviceID: bluetoothManager.localDeviceID,
            deviceName: bluetoothManager.localDeviceName
        )
        
        do {
            let controlMsg = try ControlMessage(type: .peerAnnounce, content: announce)
            let envelope = try MessageEnvelope(
                originID: bluetoothManager.localDeviceID,
                originName: bluetoothManager.localDeviceName,
                controlMessage: controlMsg,
                ttl: 2
            )
            let data = try envelope.serialize()
            _ = broadcastData?(data, [])
            
            MeshLogger.relay.debug("Broadcast peer announcement")
        } catch {
            MeshLogger.relay.error("Failed to broadcast announcement: \(error)")
        }
    }
    
    // MARK: - Route Discovery
    
    private func initiateRouteRequest(to destinationID: UUID, completion: @escaping (RouteEntry?) -> Void) {
        guard let bluetoothManager = bluetoothManager else {
            completion(nil)
            return
        }
        
        let rreq = RouteRequest(
            originID: bluetoothManager.localDeviceID,
            originName: bluetoothManager.localDeviceName,
            destinationID: destinationID
        )
        
        // Store pending request
        lock.lock()
        pendingRequests[rreq.requestID] = PendingRouteRequest(
            destinationID: destinationID,
            startTime: Date(),
            completion: completion
        )
        seenRequestIDs.insert(rreq.requestID)
        lock.unlock()
        
        DispatchQueue.main.async {
            self.pendingDiscoveries = self.pendingRequests.count
        }
        
        // Broadcast RREQ
        do {
            let controlMsg = try ControlMessage(type: .routeRequest, content: rreq)
            let envelope = try MessageEnvelope(
                originID: bluetoothManager.localDeviceID,
                originName: bluetoothManager.localDeviceName,
                controlMessage: controlMsg
            )
            let data = try envelope.serialize()
            let sent = broadcastData?(data, []) ?? 0
            
            MeshLogger.relay.info("Initiated RREQ for \(destinationID.uuidString.prefix(8)), broadcast to \(sent) peers")
        } catch {
            MeshLogger.relay.error("Failed to send RREQ: \(error)")
            completion(nil)
        }
        
        // Timeout after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.handleRouteRequestTimeout(requestID: rreq.requestID)
        }
    }
    
    private func handleRouteRequest(_ controlMessage: ControlMessage, from peer: Peer) {
        guard let bluetoothManager = bluetoothManager else { return }
        
        do {
            let rreq = try controlMessage.decode(RouteRequest.self)
            
            // Check if we've seen this request
            lock.lock()
            let alreadySeen = seenRequestIDs.contains(rreq.requestID)
            if !alreadySeen {
                seenRequestIDs.insert(rreq.requestID)
            }
            lock.unlock()
            
            if alreadySeen {
                MeshLogger.relay.debug("Ignoring duplicate RREQ: \(rreq.requestID.uuidString.prefix(8))")
                return
            }
            
            // Store reverse route to origin (for RREP)
            routingTable.setReverseRoute(from: rreq.originID, via: peer.id)
            
            // Create route entry for origin
            let originRoute = RouteEntry(
                destinationID: rreq.originID,
                nextHopID: peer.id,
                hopCount: rreq.hopCount + 1,
                hopPath: rreq.hopPath.reversed()
            )
            routingTable.updateRoute(originRoute)
            
            // Update known peers
            DispatchQueue.main.async {
                self.knownPeers[rreq.originID] = PeerInfo(
                    deviceID: rreq.originID,
                    deviceName: rreq.originName,
                    hopCount: rreq.hopCount + 1,
                    lastSeen: Date(),
                    isDirect: false
                )
            }
            
            MeshLogger.relay.info("Received RREQ from \(rreq.originName) looking for \(rreq.destinationID.uuidString.prefix(8))")
            
            // Am I the destination?
            if rreq.destinationID == bluetoothManager.localDeviceID {
                sendRouteReply(for: rreq, via: peer)
                return
            }
            
            // Do I have a route to destination?
            if let existingRoute = routingTable.getRoute(to: rreq.destinationID) {
                // Send RREP on behalf of destination (proxy reply)
                sendProxyRouteReply(for: rreq, existingRoute: existingRoute, via: peer)
                return
            }
            
            // Forward RREQ
            if let forwardedRreq = rreq.forwarded(by: bluetoothManager.localDeviceID) {
                let controlMsg = try ControlMessage(type: .routeRequest, content: forwardedRreq)
                let envelope = try MessageEnvelope(
                    originID: bluetoothManager.localDeviceID,
                    originName: bluetoothManager.localDeviceName,
                    controlMessage: controlMsg,
                    ttl: forwardedRreq.ttl - forwardedRreq.hopCount
                )
                let data = try envelope.serialize()
                _ = broadcastData?(data, [peer.id, rreq.originID])
                
                MeshLogger.relay.debug("Forwarded RREQ, hop \(forwardedRreq.hopCount)")
            }
            
        } catch {
            MeshLogger.relay.error("Failed to process RREQ: \(error)")
        }
    }
    
    private func sendRouteReply(for rreq: RouteRequest, via peer: Peer) {
        guard let bluetoothManager = bluetoothManager else { return }
        
        let rrep = RouteReply(
            requestID: rreq.requestID,
            originID: rreq.originID,
            destinationID: bluetoothManager.localDeviceID,
            destinationName: bluetoothManager.localDeviceName,
            incomingPath: rreq.hopPath
        )
        
        do {
            let controlMsg = try ControlMessage(type: .routeReply, content: rrep)
            let envelope = try MessageEnvelope(
                originID: bluetoothManager.localDeviceID,
                originName: bluetoothManager.localDeviceName,
                controlMessage: controlMsg
            )
            let data = try envelope.serialize()
            _ = sendData?(data, peer)
            
            MeshLogger.relay.info("Sent RREP to \(rreq.originName) via \(peer.name)")
        } catch {
            MeshLogger.relay.error("Failed to send RREP: \(error)")
        }
    }
    
    private func sendProxyRouteReply(for rreq: RouteRequest, existingRoute: RouteEntry, via peer: Peer) {
        guard let bluetoothManager = bluetoothManager else { return }
        
        // Combine paths
        var combinedPath = rreq.hopPath
        combinedPath.append(contentsOf: existingRoute.hopPath)
        
        let rrep = RouteReply(
            requestID: rreq.requestID,
            originID: rreq.originID,
            destinationID: rreq.destinationID,
            destinationName: "Cached",
            incomingPath: combinedPath
        )
        
        do {
            let controlMsg = try ControlMessage(type: .routeReply, content: rrep)
            let envelope = try MessageEnvelope(
                originID: bluetoothManager.localDeviceID,
                originName: bluetoothManager.localDeviceName,
                controlMessage: controlMsg
            )
            let data = try envelope.serialize()
            _ = sendData?(data, peer)
            
            MeshLogger.relay.info("Sent proxy RREP for \(rreq.destinationID.uuidString.prefix(8))")
        } catch {
            MeshLogger.relay.error("Failed to send proxy RREP: \(error)")
        }
    }
    
    private func handleRouteReply(_ controlMessage: ControlMessage, from peer: Peer) {
        guard let bluetoothManager = bluetoothManager else { return }
        
        do {
            let rrep = try controlMessage.decode(RouteReply.self)
            
            MeshLogger.relay.info("Received RREP for \(rrep.destinationID.uuidString.prefix(8)) from \(peer.name)")
            
            // Create forward route to destination
            let route = RouteEntry(
                destinationID: rrep.destinationID,
                nextHopID: peer.id,
                hopCount: rrep.hopCount + 1,
                hopPath: rrep.hopPath
            )
            routingTable.updateRoute(route)
            
            // Update known peers
            DispatchQueue.main.async {
                self.knownPeers[rrep.destinationID] = PeerInfo(
                    deviceID: rrep.destinationID,
                    deviceName: rrep.destinationName,
                    hopCount: rrep.hopCount + 1,
                    lastSeen: Date(),
                    isDirect: false
                )
                self.routeCount = self.routingTable.count
            }
            
            // Is this RREP for us?
            if rrep.originID == bluetoothManager.localDeviceID {
                // Complete pending request
                lock.lock()
                if let pending = pendingRequests.removeValue(forKey: rrep.requestID) {
                    lock.unlock()
                    
                    DispatchQueue.main.async {
                        self.pendingDiscoveries = self.pendingRequests.count
                    }
                    
                    pending.completion?(route)
                    onRouteFound?(rrep.destinationID, route)
                } else {
                    lock.unlock()
                }
            } else {
                // Forward RREP toward origin
                if let reverseHop = routingTable.getReverseRoute(to: rrep.originID),
                   let nextPeer = bluetoothManager.connectedPeers[reverseHop] {
                    let forwardedRrep = rrep.forwarded()
                    let controlMsg = try ControlMessage(type: .routeReply, content: forwardedRrep)
                    let envelope = try MessageEnvelope(
                        originID: bluetoothManager.localDeviceID,
                        originName: bluetoothManager.localDeviceName,
                        controlMessage: controlMsg
                    )
                    let data = try envelope.serialize()
                    _ = sendData?(data, nextPeer)
                    
                    MeshLogger.relay.debug("Forwarded RREP toward \(rrep.originID.uuidString.prefix(8))")
                }
            }
            
        } catch {
            MeshLogger.relay.error("Failed to process RREP: \(error)")
        }
    }
    
    private func handleRouteError(_ controlMessage: ControlMessage, from peer: Peer) {
        do {
            let rerr = try controlMessage.decode(RouteError.self)
            
            // Remove routes using the broken link
            let affected = routingTable.removeRoutesVia(nextHopID: rerr.unreachableID)
            
            for destID in affected {
                DispatchQueue.main.async {
                    self.knownPeers.removeValue(forKey: destID)
                }
                onRouteLost?(destID)
            }
            
            MeshLogger.relay.warning("Route error: \(rerr.unreachableID.uuidString.prefix(8)) unreachable")
            
        } catch {
            MeshLogger.relay.error("Failed to process RERR: \(error)")
        }
    }
    
    private func handlePeerAnnounce(_ controlMessage: ControlMessage, from peer: Peer) {
        guard let bluetoothManager = bluetoothManager else { return }
        
        do {
            let announce = try controlMessage.decode(PeerAnnounce.self)
            
            // Ignore our own announcements
            guard announce.deviceID != bluetoothManager.localDeviceID else { return }
            
            // Update known peers
            let hopCount = announce.hopCount + 1
            
            DispatchQueue.main.async {
                self.knownPeers[announce.deviceID] = PeerInfo(
                    deviceID: announce.deviceID,
                    deviceName: announce.deviceName,
                    hopCount: hopCount,
                    lastSeen: Date(),
                    isDirect: hopCount == 1
                )
            }
            
            // Add route if it's a better path
            if !routingTable.hasRoute(to: announce.deviceID) || 
               (routingTable.getRoute(to: announce.deviceID)?.hopCount ?? Int.max) > hopCount {
                let route = RouteEntry(
                    destinationID: announce.deviceID,
                    nextHopID: peer.id,
                    hopCount: hopCount,
                    hopPath: [announce.deviceID]
                )
                routingTable.updateRoute(route)
                
                DispatchQueue.main.async {
                    self.routeCount = self.routingTable.count
                }
            }
            
            // Forward announcement if TTL allows
            if let forwarded = announce.forwarded() {
                let controlMsg = try ControlMessage(type: .peerAnnounce, content: forwarded)
                let envelope = try MessageEnvelope(
                    originID: bluetoothManager.localDeviceID,
                    originName: bluetoothManager.localDeviceName,
                    controlMessage: controlMsg,
                    ttl: 2
                )
                let data = try envelope.serialize()
                _ = broadcastData?(data, [peer.id, announce.deviceID])
            }
            
            MeshLogger.relay.debug("Peer announced: \(announce.deviceName) (hop \(hopCount))")
            
        } catch {
            MeshLogger.relay.error("Failed to process peer announce: \(error)")
        }
    }
    
    private func handleAck(_ controlMessage: ControlMessage, from peer: Peer) {
        do {
            let ack = try controlMessage.decode(DeliveryAck.self)
            routingTable.recordSuccess(for: ack.receiverID)
            
            // Forward to DeliveryService for tracking
            DeliveryService.shared.handleAck(ack)
            
            MeshLogger.relay.debug("Received ACK for message \(ack.messageID.uuidString.prefix(8))")
        } catch {
            MeshLogger.relay.error("Failed to process ACK: \(error)")
        }
    }
    
    // MARK: - Event Handlers
    
    private func handlePeerDisconnected(_ peer: Peer) {
        // Remove routes through disconnected peer
        let affected = routingTable.removeRoutesVia(nextHopID: peer.id)
        
        // Remove direct route to peer
        routingTable.removeRoute(to: peer.id)
        
        DispatchQueue.main.async {
            self.knownPeers.removeValue(forKey: peer.id)
            for destID in affected {
                self.knownPeers.removeValue(forKey: destID)
            }
            self.routeCount = self.routingTable.count
        }
        
        // Notify about lost routes
        for destID in affected {
            onRouteLost?(destID)
        }
        
        // Broadcast route error
        if !affected.isEmpty, let bluetoothManager = bluetoothManager {
            let rerr = RouteError(
                unreachableID: peer.id,
                reporterID: bluetoothManager.localDeviceID,
                affectedDestinations: affected
            )
            
            do {
                let controlMsg = try ControlMessage(type: .routeError, content: rerr)
                let envelope = try MessageEnvelope(
                    originID: bluetoothManager.localDeviceID,
                    originName: bluetoothManager.localDeviceName,
                    controlMessage: controlMsg,
                    ttl: 2
                )
                let data = try envelope.serialize()
                _ = broadcastData?(data, [peer.id])
            } catch {
                MeshLogger.relay.error("Failed to broadcast RERR: \(error)")
            }
        }
    }
    
    private func handleRouteRequestTimeout(requestID: UUID) {
        lock.lock()
        if let pending = pendingRequests.removeValue(forKey: requestID) {
            lock.unlock()
            
            DispatchQueue.main.async {
                self.pendingDiscoveries = self.pendingRequests.count
            }
            
            MeshLogger.relay.warning("Route discovery timeout for \(pending.destinationID.uuidString.prefix(8))")
            pending.completion?(nil)
        } else {
            lock.unlock()
        }
    }
    
    // MARK: - Maintenance
    
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.performMaintenance()
        }
    }
    
    private func performMaintenance() {
        routingTable.cleanupExpired()
        
        // Clean old seen request IDs
        lock.lock()
        if seenRequestIDs.count > 1000 {
            seenRequestIDs.removeAll()
        }
        lock.unlock()
        
        DispatchQueue.main.async {
            self.routeCount = self.routingTable.count
        }
    }
}
