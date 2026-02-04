import Foundation
import Combine
import CoreBluetooth

/// Enhanced ViewModel for chat interface with routing and groups
@MainActor
final class ChatViewModel: ObservableObject {
    
    // MARK: - Published State
    
    @Published var messageText: String = ""
    @Published var messages: [MeshMessage] = []
    @Published var peers: [Peer] = []
    @Published var knownDevices: [RoutingService.PeerInfo] = []
    @Published var groups: [Conversation] = []
    @Published var connectedPeersCount: Int = 0
    @Published var isBluetoothReady: Bool = false
    @Published var bluetoothStatus: String = "Initializing..."
    @Published var errorMessage: String?
    @Published var isSending: Bool = false
    @Published var isScanning: Bool = false
    @Published var isAdvertising: Bool = false
    @Published var encryptionEnabled: Bool = false // Always false now
    
    // Target for direct messaging
    @Published var selectedDestination: UUID? = nil
    @Published var selectedGroup: Conversation? = nil
    @Published var activeConversation: Conversation? = nil
    
    // Debug stats
    @Published var stats: DebugStats = DebugStats()
    
    struct DebugStats {
        var messagesReceived: Int = 0
        var messagesSent: Int = 0
        var messagesRelayed: Int = 0
        var duplicatesBlocked: Int = 0
        var peersDiscovered: Int = 0
        var routeCount: Int = 0
        var pendingRoutes: Int = 0
        var encryptedMessages: Int = 0 // Legacy field, always 0
        var decryptedMessages: Int = 0 // Legacy field, always 0
    }
    
    // MARK: - Dependencies
    
    private let bluetoothManager: BluetoothManager
    private let routingService: RoutingService
    private let messageRelayService: MessageRelayService
    
    // MARK: - Private
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init(
        bluetoothManager: BluetoothManager,
        routingService: RoutingService,
        messageRelayService: MessageRelayService
    ) {
        self.bluetoothManager = bluetoothManager
        self.routingService = routingService
        self.messageRelayService = messageRelayService
        
        setupBindings()
        setupCallbacks()
        loadGroups()
        loadPersistedConversations()
        
        MeshLogger.app.info("ChatViewModel initialized (Unencrypted)")
    }
    
    // MARK: - Constants
    
    /// Maximum allowed message length in bytes (10KB)
    private static let maxMessageLength = 10 * 1024
    
    // MARK: - Public API
    
    /// Send a message (broadcast, direct, or group based on selection)
    func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        guard connectedPeersCount > 0 else {
            errorMessage = "No connected peers"
            return
        }
        
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Validate message length
        guard let contentData = content.data(using: .utf8),
              contentData.count <= Self.maxMessageLength else {
            errorMessage = "Message too long (max \(Self.maxMessageLength / 1024)KB)"
            return
        }
        
        messageText = ""
        
        isSending = true
        
        Task {
            do {
                if let group = selectedGroup {
                    // Group message (now plaintext)
                    try await sendGroupMessage(to: group, content: content)
                } else if let destinationID = selectedDestination {
                    // Direct message (plaintext)
                    try await sendDirectMessage(to: destinationID, content: content)
                } else {
                    // Broadcast (plaintext)
                    try await sendBroadcastMessage(content: content)
                }
                
                stats.messagesSent += 1
                
            } catch {
                MeshLogger.message.error("Failed to send: \(error.localizedDescription)")
                errorMessage = "Failed to send: \(error.localizedDescription)"
            }
            
            isSending = false
        }
    }
    
    /// Send direct message
    private func sendDirectMessage(to destinationID: UUID, content: String) async throws {
        // Always send unencrypted
        try await messageRelayService.sendDirectMessage(to: destinationID, content: content)
        
        // Add to local messages
        var message = MeshMessage(
            senderID: bluetoothManager.localDeviceID.uuidString,
            senderName: bluetoothManager.localDeviceName,
            content: content
        )
        message.isFromLocalDevice = true
        messages.append(message)
        
        // Persist outgoing direct message
        persistMessage(message, conversationID: getOrCreateDirectConversation(with: destinationID, name: "Device \(destinationID.uuidString.prefix(4))").id)
    }
    
    /// Send group message
    private func sendGroupMessage(to group: Conversation, content: String) async throws {
        // Group messages are now just direct messages to all participants
        // Iterate and send to each member
        for memberID in group.participantIDs where memberID != bluetoothManager.localDeviceID {
             try await messageRelayService.sendDirectMessage(to: memberID, content: content)
        }
        
        // Add to local messages
        var message = MeshMessage(
            senderID: bluetoothManager.localDeviceID.uuidString,
            senderName: bluetoothManager.localDeviceName,
            content: content
        )
        message.isFromLocalDevice = true
        message.conversationID = group.id
        messages.append(message)
        
        group.updateWithMessage(message)
        
        // Persist outgoing group message
        persistMessage(message, conversationID: group.id)
        
        MeshLogger.message.info("Sent group message to \(group.name)")
    }
    
    /// Send broadcast message
    private func sendBroadcastMessage(content: String) async throws {
        try await messageRelayService.sendBroadcastMessage(content: content)
        MeshLogger.message.info("Broadcast message sent")
    }
    
    // MARK: - Group Management
    
    /// Create a new group
    func createGroup(name: String, members: Set<UUID>) {
        let group = Conversation(groupName: name, members: members)
        
        groups.append(group)
        saveGroups()
        
        // Notify members about new group (simplified)
        Task {
            for memberID in members {
                 try? await messageRelayService.sendDirectMessage(to: memberID, content: "Added to group: \(name)")
            }
        }
        
        MeshLogger.message.info("Created group '\(name)' with \(members.count) members")
    }
    
    /// Leave a group
    func leaveGroup(_ group: Conversation) {
        // Notify remaining members
        Task {
            await notifyGroupMemberLeft(group, memberID: bluetoothManager.localDeviceID)
        }
        
        groups.removeAll { $0.id == group.id }
        saveGroups()
        
        if selectedGroup?.id == group.id {
            selectedGroup = nil
        }
        
        MeshLogger.message.info("Left group '\(group.name)'")
    }
    
    /// Remove a member from a group
    func removeMemberFromGroup(_ memberID: UUID, group: Conversation) {
        guard let groupToUpdate = groups.first(where: { $0.id == group.id }) else { return }
        
        // Remove from participants
        groupToUpdate.participantIDs.remove(memberID)
        
        // Update in groups array
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = groupToUpdate
        }
        
        saveGroups()
        MeshLogger.message.info("Removed member from group '\(group.name)'")
    }
    
    /// Notify group members that someone left
    private func notifyGroupMemberLeft(_ group: Conversation, memberID: UUID) async {
        for participant in group.participantIDs where participant != memberID {
            do {
                try await messageRelayService.sendDirectMessage(to: participant, content: "[Member left the group]")
            } catch {
                MeshLogger.app.error("Failed to notify member of leave: \(error)")
            }
        }
    }
    
    /// Open a conversation
    func openConversation(_ conversation: Conversation) {
        activeConversation = conversation
        
        if conversation.type == .group {
            selectedGroup = conversation
            selectedDestination = nil
        } else if let peerID = conversation.peerID {
            selectedDestination = peerID
            selectedGroup = nil
        }
        
        // Load persisted messages for this conversation
        loadMessagesForConversation(conversation.id)
        
        // Mark messages as read and send receipts
        markMessagesAsRead(in: conversation.id)
        
        conversation.markAsRead()
        StorageService.shared.resetUnreadCount(conversation.id)
    }
    
    /// Load messages from storage for a conversation
    private func loadMessagesForConversation(_ conversationID: UUID) {
        let persistedMessages = StorageService.shared.getMessages(for: conversationID, limit: 100)
        
        // Convert to MeshMessage and merge with existing (avoid duplicates)
        let loaded = persistedMessages.map { persisted -> MeshMessage in
            var msg = MeshMessage(
                id: persisted.id,
                senderID: persisted.senderID.uuidString,
                senderName: persisted.senderName,
                content: persisted.content,
                timestamp: persisted.timestamp,
                ttl: persisted.ttl,
                originID: persisted.id,
                deliveryStatus: convertPersistedStatus(persisted.deliveryStatus)
            )
            msg.isFromLocalDevice = persisted.isFromLocalDevice
            msg.conversationID = conversationID
            return msg
        }
        
        // Merge: keep existing in-memory messages and add loaded ones that aren't there
        let existingIDs = Set(messages.map { $0.id })
        let newMessages = loaded.filter { !existingIDs.contains($0.id) }
        messages.append(contentsOf: newMessages)
        messages.sort { $0.timestamp < $1.timestamp }
        
        MeshLogger.app.info("Loaded \(newMessages.count) messages for conversation")
    }
    
    /// Convert persisted status to MeshMessage status
    private func convertPersistedStatus(_ status: PersistedMessage.DeliveryStatus) -> MessageDeliveryStatus {
        switch status {
        case .pending: return .pending
        case .sent: return .sent
        case .delivered: return .delivered
        case .read: return .read
        case .failed: return .failed
        }
    }
    
    // MARK: - Peer Actions
    
    func connect(to peer: Peer) {
        bluetoothManager.connect(to: peer)
    }
    
    func disconnect(from peer: Peer) {
        bluetoothManager.disconnect(from: peer)
    }
    
    func toggleScanning() {
        if bluetoothManager.isScanning {
            bluetoothManager.stopScanning()
        } else {
            bluetoothManager.startScanning()
        }
    }
    
    func toggleAdvertising() {
        if bluetoothManager.isAdvertising {
            bluetoothManager.stopAdvertising()
        } else {
            bluetoothManager.startAdvertising()
        }
    }
    
    func refreshPeers() {
        peers = Array(bluetoothManager.discoveredPeers.values)
            .sorted { $0.rssi > $1.rssi }
    }
    
    func clearMessages() {
        messages.removeAll()
    }
    
    func discoverRoute(to deviceID: UUID) {
        routingService.discoverRoute(to: deviceID) { [weak self] route in
            if let route = route {
                MeshLogger.relay.info("Route found: \(route.hopCount) hops")
            } else {
                self?.errorMessage = "Could not find route"
            }
        }
    }
    
    func selectDestination(_ deviceID: UUID?) {
        selectedDestination = deviceID
        selectedGroup = nil
        
        // Load persisted messages for this conversation
        if let destID = deviceID {
            loadMessagesForConversation(with: destID)
        }
    }
    
    func selectGroup(_ group: Conversation?) {
        selectedGroup = group
        selectedDestination = nil
        
        // Load persisted messages for this group
        if let groupConv = group {
            loadMessagesForGroupConversation(groupConv.id)
        }
    }
    
    /// Load messages for a direct conversation
    private func loadMessagesForConversation(with peerID: UUID) {
        // Find or create conversation
        let conversation = getOrCreateDirectConversation(with: peerID, name: "Device \(peerID.uuidString.prefix(4))")
        
        // Load from storage
        let persisted = StorageService.shared.getMessages(for: conversation.id, limit: 100)
        let loadedMessages = persisted.map { $0.toMeshMessage() }
        
        // Merge with in-memory messages (avoid duplicates)
        var allMessages = loadedMessages
        for msg in messages {
            if !allMessages.contains(where: { $0.id == msg.id }) {
                allMessages.append(msg)
            }
        }
        
        // Sort by timestamp
        messages = allMessages.sorted { $0.timestamp < $1.timestamp }
        
        MeshLogger.app.info("Loaded \(loadedMessages.count) messages for conversation")
    }
    
    /// Load messages for a group conversation
    private func loadMessagesForGroupConversation(_ groupID: UUID) {
        // Load from storage
        let persisted = StorageService.shared.getMessages(for: groupID, limit: 100)
        let loadedMessages = persisted.map { $0.toMeshMessage() }
        
        // Merge with in-memory messages (avoid duplicates)
        var allMessages = loadedMessages
        for msg in messages {
            if !allMessages.contains(where: { $0.id == msg.id }) {
                allMessages.append(msg)
            }
        }
        
        // Sort by timestamp
        messages = allMessages.sorted { $0.timestamp < $1.timestamp }
        
        MeshLogger.app.info("Loaded \(loadedMessages.count) messages for group")
    }
    
    func canReach(deviceID: UUID) -> Bool {
        routingService.hasRoute(to: deviceID) || bluetoothManager.connectedPeers[deviceID] != nil
    }
    
    func toggleEncryption() {
        // No-op or show error
        MeshLogger.app.info("Encryption is disabled in this version")
    }
    
    // MARK: - Private Methods
    
    private func setupBindings() {
        // Bluetooth state
        Publishers.CombineLatest(
            bluetoothManager.$centralState,
            bluetoothManager.$peripheralState
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] centralState, peripheralState in
            self?.updateBluetoothStatus(central: centralState, peripheral: peripheralState)
        }
        .store(in: &cancellables)
        
        // Discovered peers
        bluetoothManager.$discoveredPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peersDict in
                self?.peers = Array(peersDict.values).sorted { $0.rssi > $1.rssi }
                self?.stats.peersDiscovered = peersDict.count
            }
            .store(in: &cancellables)
        
        // Connected peers
        bluetoothManager.$connectedPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connectedDict in
                self?.connectedPeersCount = connectedDict.count
            }
            .store(in: &cancellables)
        
        // Scanning state
        bluetoothManager.$isScanning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scanning in
                self?.isScanning = scanning
            }
            .store(in: &cancellables)
        
        // Advertising state
        bluetoothManager.$isAdvertising
            .receive(on: DispatchQueue.main)
            .sink { [weak self] advertising in
                self?.isAdvertising = advertising
            }
            .store(in: &cancellables)
        
        // Received messages
        messageRelayService.$receivedMessages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] receivedMessages in
                guard let self = self else { return }
                
                for msg in receivedMessages {
                    if !self.messages.contains(where: { $0.id == msg.id }) {
                        self.messages.append(msg)
                        self.stats.messagesReceived += 1
                    }
                }
            }
            .store(in: &cancellables)
        
        // Relay stats
        messageRelayService.$relayedCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.stats.messagesRelayed = count
            }
            .store(in: &cancellables)
        
        messageRelayService.$duplicatesBlocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.stats.duplicatesBlocked = count
            }
            .store(in: &cancellables)
        
        // Known devices from routing
        routingService.$knownPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.knownDevices = Array(peers.values).sorted { $0.hopCount < $1.hopCount }
            }
            .store(in: &cancellables)
        
        // Route count
        routingService.$routeCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.stats.routeCount = count
            }
            .store(in: &cancellables)
        
        // Pending route discoveries
        routingService.$pendingDiscoveries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.stats.pendingRoutes = count
            }
            .store(in: &cancellables)
    }
    
    private func setupCallbacks() {
        // Direct message received
        messageRelayService.onMessageReceived = { message in
            MeshLogger.app.info("UI received message from: \(message.senderName)")
        }
        
        // Delivery callbacks
        messageRelayService.onDeliveryConfirmed = { [weak self] messageID in
            self?.updateMessageDeliveryStatus(messageID, status: .delivered)
        }
        
        messageRelayService.onDeliveryFailed = { [weak self] messageID in
            self?.updateMessageDeliveryStatus(messageID, status: .failed)
            self?.errorMessage = "Message delivery failed"
        }
        
        routingService.onRouteFound = { deviceID, route in
            MeshLogger.app.info("Route found to \(deviceID.uuidString.prefix(8)): \(route.hopCount) hops")
        }
        
        routingService.onRouteLost = { deviceID in
            MeshLogger.app.warning("Route lost to \(deviceID.uuidString.prefix(8))")
        }
        
        // Handle read receipts
        routingService.onReadReceiptReceived = { [weak self] messageID, readerID in
            self?.updateMessageDeliveryStatus(messageID, status: .read)
            MeshLogger.app.debug("Message \(messageID.uuidString.prefix(8)) was read by \(readerID.uuidString.prefix(8))")
        }
        
        // Message persistence callback
        messageRelayService.onPersistMessage = { [weak self] message, conversationID in
            self?.persistMessage(message, conversationID: conversationID)
        }
    }
    
    // MARK: - Read Receipts
    
    /// Send a read receipt for a message
    func sendReadReceipt(for message: MeshMessage) {
        guard !message.isFromLocalDevice,
              let senderUUID = UUID(uuidString: message.senderID) else {
            return
        }
        
        Task {
            do {
                let receipt = ReadReceipt(
                    messageID: message.id,
                    readerID: bluetoothManager.localDeviceID,
                    originalSenderID: senderUUID
                )
                
                let controlMsg = try ControlMessage(type: .readReceipt, content: receipt)
                
                try await messageRelayService.sendControlMessage(controlMsg, to: senderUUID)
                MeshLogger.app.debug("Sent read receipt for message \(message.id.uuidString.prefix(8))")
            } catch {
                MeshLogger.app.debug("Failed to send read receipt: \(error)")
            }
        }
    }
    
    /// Mark messages as read and send receipts
    func markMessagesAsRead(in conversationID: UUID) {
        let unreadMessages = messages.filter { msg in
            msg.conversationID == conversationID && !msg.isFromLocalDevice && msg.deliveryStatus != .read
        }
        
        for message in unreadMessages {
            sendReadReceipt(for: message)
        }
    }
    
    // MARK: - Message Persistence
    
    private func persistMessage(_ message: MeshMessage, conversationID: UUID?) {
        Task { @MainActor in
            // Determine conversation ID
            let convID: UUID
            if let cid = conversationID {
                convID = cid
            } else if let senderUUID = UUID(uuidString: message.senderID) {
                // Direct message - get or create conversation
                convID = getOrCreateDirectConversation(with: senderUUID, name: message.senderName).id
            } else {
                return // Can't persist without conversation
            }
            
            // Create persisted message
            let persisted = PersistedMessage(
                id: message.id,
                conversationID: convID,
                senderID: UUID(uuidString: message.senderID) ?? UUID(),
                senderName: message.senderName,
                content: message.content,
                timestamp: message.timestamp,
                ttl: message.ttl,
                hopCount: BLEConstants.maxTTL - message.ttl,
                isFromLocalDevice: message.isFromLocalDevice,
                isEncrypted: false,
                deliveryStatus: message.isFromLocalDevice ? .sent : .delivered
            )
            
            StorageService.shared.saveMessage(persisted)
            
            // Update conversation
            StorageService.shared.updateConversation(convID, lastMessageTime: message.timestamp)
            if !message.isFromLocalDevice {
                StorageService.shared.incrementUnreadCount(convID)
            }
        }
    }
    
    /// Update delivery status for a message
    private func updateMessageDeliveryStatus(_ messageID: UUID, status: MessageDeliveryStatus) {
        Task { @MainActor in
            // Update in-memory messages array
            if let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].deliveryStatus = status
            }
            
            // Update persisted status
            let persistedStatus: PersistedMessage.DeliveryStatus
            switch status {
            case .pending: persistedStatus = .pending
            case .sent: persistedStatus = .sent
            case .delivered: persistedStatus = .delivered
            case .read: persistedStatus = .read
            case .failed: persistedStatus = .failed
            }
            StorageService.shared.updateMessageStatus(messageID, status: persistedStatus)
            
            MeshLogger.message.info("Message \(messageID.uuidString.prefix(8)) status: \(String(describing: status))")
        }
    }
    
    private func getOrCreateDirectConversation(with peerID: UUID, name: String) -> Conversation {
        // Check if we already have a conversation
        if let existing = StorageService.shared.getDirectConversation(with: peerID) {
            return Conversation(
                id: existing.id,
                type: .direct,
                participantIDs: Set(existing.participantIDs),
                name: existing.name,
                createdAt: existing.createdAt,
                updatedAt: existing.updatedAt
            )
        }
        
        // Create new conversation
        let conversation = Conversation(with: peerID, peerName: name)
        
        // Persist it
        let persisted = PersistedConversation(
            id: conversation.id,
            type: .direct,
            participantIDs: Array(conversation.participantIDs),
            name: name,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt
        )
        StorageService.shared.saveConversation(persisted)
        
        return conversation
    }
    
    private func updateBluetoothStatus(central: CBManagerState, peripheral: CBManagerState) {
        isBluetoothReady = central == .poweredOn && peripheral == .poweredOn
        
        switch (central, peripheral) {
        case (.poweredOn, .poweredOn):
            bluetoothStatus = "Ready (Scanning & Advertising)"
        case (.poweredOff, _), (_, .poweredOff):
            bluetoothStatus = "Bluetooth is OFF"
        case (.unauthorized, _), (_, .unauthorized):
            bluetoothStatus = "Bluetooth permission denied"
        case (.unsupported, _), (_, .unsupported):
            bluetoothStatus = "Bluetooth not supported"
        default:
            bluetoothStatus = "Initializing... (C:\(central.rawValue) P:\(peripheral.rawValue))"
        }
    }
    
    // MARK: - Persistence
    
    private func loadPersistedConversations() {
        Task { @MainActor in
            guard StorageService.shared.isReady else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                loadPersistedConversations()
                return
            }
            
            let persistedConversations = StorageService.shared.getAllConversations()
            
            for persisted in persistedConversations {
                if groups.contains(where: { $0.id == persisted.id }) {
                    continue
                }
                
                let conversationType: Conversation.ConversationType = persisted.type == .group ? .group : .direct
                
                let conversation = Conversation(
                    id: persisted.id,
                    type: conversationType,
                    participantIDs: Set(persisted.participantIDs),
                    name: persisted.name,
                    createdAt: persisted.createdAt,
                    updatedAt: persisted.updatedAt,
                    groupKeyData: persisted.groupKeyData
                )
                
                if persisted.type == .group {
                    groups.append(conversation)
                }
            }
            
            MeshLogger.app.info("Loaded \(persistedConversations.count) conversations from storage")
        }
    }
    
    func loadMessages(for conversationID: UUID) -> [MeshMessage] {
        let persisted = StorageService.shared.getMessages(for: conversationID, limit: 100)
        return persisted.map { $0.toMeshMessage() }
    }
    
    private func loadGroups() {
        // Load group metadata from UserDefaults (non-sensitive data)
        guard let data = UserDefaults.standard.data(forKey: "mesh.groups"),
              let models = try? JSONDecoder().decode([Conversation.StorageModel].self, from: data) else {
            return
        }
        
        groups = models.map { Conversation(from: $0) }
    }
    
    private func saveGroups() {
        let models = groups.map { $0.storageModel }
        guard let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: "mesh.groups")
    }
    
    var localDeviceName: String {
        bluetoothManager.localDeviceName
    }
    
    var localDeviceID: String {
        bluetoothManager.localDeviceID.uuidString.prefix(8).description
    }
    
    var messagingMode: String {
        if let group = selectedGroup {
            return "Group: \(group.name)"
        } else if let destID = selectedDestination {
            return "Direct: \(destID.uuidString.prefix(8))"
        }
        return "Broadcast"
    }
    
    var isEncrypted: Bool {
        // ALWAYS FALSE
        false
    }
    
    /// Force route announcement to mesh
    func forceRouteDiscovery() {
        routingService.announceSelf()
    }
    
    /// Clear all routing table entries
    func clearRoutingTable() {
        routingService.routingTable.clear()
    }
    
    /// Get all current routes for display
    var routes: [RouteEntry] {
        routingService.routingTable.getAllRoutes()
    }
    
    /// Get available peers (connected + routable)
    var availablePeers: [Peer] {
        var result: [Peer] = Array(bluetoothManager.connectedPeers.values)
        
        // Add routable but not directly connected peers
        for route in routingService.routingTable.getAllRoutes() {
            if !result.contains(where: { $0.id == route.id }) {
                let peer = Peer(id: route.id, name: "Device \(route.id.uuidString.prefix(4))")
                result.append(peer)
            }
        }
        
        return result
    }
    
    /// Get hop count to a peer
    func hopCountTo(_ peerID: UUID) -> Int? {
        if bluetoothManager.connectedPeers[peerID] != nil {
            return 1
        }
        return routingService.getRoute(to: peerID)?.hopCount
    }
    
    /// Get route reliability (0.0-1.0)
    func routeReliability(to peerID: UUID) -> Float? {
        if bluetoothManager.connectedPeers[peerID] != nil {
            return 1.0
        }
        return routingService.getRoute(to: peerID)?.reliability
    }
    
    /// Get formatted route quality string
    func formattedRouteQuality(to peerID: UUID) -> String {
        if let reliability = routeReliability(to: peerID) {
            let percentage = Int(reliability * 100)
            return "Quality: \(percentage)%"
        }
        return "Unknown"
    }
    
    /// Get display name for a peer ID (uses nickname if available)
    func getDisplayName(for peerIDString: String) -> String? {
        guard let uuid = UUID(uuidString: peerIDString),
              let peer = peers.first(where: { $0.id == uuid }) else {
            return nil
        }
        return peer.displayName
    }
}

// MARK: - Preview Support

extension ChatViewModel {
    static var preview: ChatViewModel {
        let btManager = BluetoothManager()
        let routing = RoutingService()
        routing.configure(bluetoothManager: btManager)
        let relay = MessageRelayService(bluetoothManager: btManager, routingService: routing)
        return ChatViewModel(
            bluetoothManager: btManager,
            routingService: routing,
            messageRelayService: relay
        )
    }
}
