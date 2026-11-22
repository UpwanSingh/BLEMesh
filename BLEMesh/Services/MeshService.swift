import Foundation
import SwiftData
import UserNotifications
import UIKit
import MeshCore

/// App-wide coordinator: owns the mesh node and its transport, persists messages, and exposes
/// state to SwiftUI. All work happens on the main actor (same thread as `MeshNode`).
@MainActor
final class MeshService: ObservableObject {
    enum Mode: Equatable {
        case bluetooth
        /// Simulated neighbours for trying the app / UI tests without radios.
        case demo
    }

    // MARK: Published state

    @Published private(set) var peers: [PeerInfo] = []
    @Published private(set) var linkCount = 0
    @Published private(set) var radioStatus = "Starting…"
    @Published private(set) var isRadioReady = false
    @Published private(set) var stats = MeshStats()
    @Published private(set) var groups: [GroupInfo] = []
    @Published private(set) var digest: AreaDigest?
    @Published private(set) var digestOverview: String = ""
    @Published private(set) var isBuildingDigest = false
    /// Outstanding "Ask the mesh" questions: queryID → the helper we asked. Answers from anyone
    /// else (or to questions we never asked) are rejected.
    @Published private(set) var pendingQuestions: [UUID: PeerID] = [:]
    @Published var lastError: String?
    /// Conversation currently on screen (incoming messages there don't count as unread).
    @Published var openConversationKey: String?

    let mode: Mode
    let settings: AppSettings
    let trust: TrustStore
    let container: ModelContainer
    private(set) var ai: AIEngine
    private(set) var node: MeshNode
    private var bleTransport: BLETransport?
    private var demo: DemoMesh?
    private var tickTimer: Timer?
    private var snapshotDirty = false
    /// Changes on panic wipe; async work started before a wipe checks it and stands down.
    private var session = UUID()
    private let snapshotURL: URL?

    var context: ModelContext { container.mainContext }
    var myPeerID: PeerID { node.peerID }
    var myFingerprint: String { node.identity.publicIdentity.fingerprint }
    var nickname: String { node.nickname }

    init(mode: Mode, container: ModelContainer, settings: AppSettings, trust: TrustStore? = nil,
         ai: AIEngine? = nil, identity: MeshIdentity? = nil, persistSnapshot: Bool = true) {
        self.mode = mode
        self.container = container
        self.settings = settings
        self.trust = trust ?? TrustStore()
        self.ai = ai ?? AIEngineFactory.make()
        self.snapshotURL = persistSnapshot ? Self.defaultSnapshotURL : nil
        let identity = identity ?? (mode == .demo ? MeshIdentity() : IdentityStore.loadOrCreate())
        self.node = MeshNode(identity: identity, nickname: IdentityStore.nickname)
        configureNode()
        restoreSnapshot()
        start()
        startBatteryMonitoring()
        purgeExpiredMessages()
        ensureConversation(ConversationKey.nearby, kind: .nearby, title: "Nearby")
        ensureConversation(ConversationKey.askMesh, kind: .askMesh, title: "Ask the Mesh")
    }

    private func configureNode() {
        node.delegate = self
        var capabilities: PeerCapabilities = []
        if ai.hasGenerativeModel && settings.helpOthersWithAI { capabilities.insert(.onDeviceAI) }
        if #available(iOS 18.0, *) { capabilities.insert(.translation) }
        node.capabilities = capabilities
    }

    // MARK: - Lifecycle

    private func start() {
        switch mode {
        case .bluetooth:
            let transport = BLETransport(localPeerID: node.peerID)
            transport.node = node
            transport.onStateChange = { [weak self] in self?.refreshRadioState() }
            node.transport = transport
            bleTransport = transport
            transport.start()
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        case .demo:
            demo = DemoMesh(localNode: node, service: self)
            demo?.start()
            node.delegate = self
        }
        refreshRadioState()
    }

    private func tick() {
        node.tick()
        refreshStats()
        if snapshotDirty { saveSnapshot() }
    }

    /// True when the user can actually see the screen (receipts / unread logic depend on it).
    private var isVisible: Bool { mode == .demo || UIApplication.shared.applicationState == .active }

    func appDidBecomeActive() {
        if let key = openConversationKey { markRead(key: key) }
    }

    func appDidEnterBackground() {
        saveSnapshot()
        try? context.save()
    }

    func applySettingsChange() {
        configureNode()
        node.announce()
    }

    func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        IdentityStore.nickname = trimmed
        node.nickname = String(trimmed.prefix(32))
        node.announce()
        objectWillChange.send()
    }

    private func refreshRadioState() {
        switch mode {
        case .demo:
            isRadioReady = true
            radioStatus = "Demo mesh (simulated devices)"
            linkCount = node.linkCount
        case .bluetooth:
            guard let transport = bleTransport else { return }
            isRadioReady = transport.isPoweredOn
            linkCount = transport.linkCount
            switch (transport.centralState, transport.peripheralState) {
            case (.poweredOn, .poweredOn):
                radioStatus = linkCount == 0 ? "Searching for nearby devices…" : "Connected to \(linkCount) device\(linkCount == 1 ? "" : "s")"
            case (.poweredOff, _), (_, .poweredOff):
                radioStatus = "Bluetooth is off"
            case (.unauthorized, _), (_, .unauthorized):
                radioStatus = "Bluetooth permission needed — enable it in Settings"
            case (.unsupported, _), (_, .unsupported):
                radioStatus = "Bluetooth LE isn't supported on this device"
            default:
                radioStatus = "Starting Bluetooth…"
            }
        }
        refreshPeers()
    }

    func refreshPeers() {
        peers = node.peers
        groups = node.groups.values.sorted { $0.name < $1.name }
        if mode == .demo { linkCount = node.linkCount }
        for peer in peers {
            if let conversation = fetchConversation(ConversationKey.direct(peer.peerID)), conversation.title != peer.nickname {
                conversation.title = peer.nickname
            }
        }
    }

    private func refreshStats() {
        if stats != node.stats { stats = node.stats }
    }

    // MARK: - Sending

    /// Send a text or voice note to a conversation.
    @discardableResult
    func send(_ content: MeshContent, to key: String) -> UUID? {
        do {
            let id: UUID
            var status: DeliveryStatus = .sent
            if (key == ConversationKey.nearby || ConversationKey.groupID(from: key) != nil) && node.linkCount == 0 {
                // Broadcast/group traffic isn't queued; don't pretend it went out.
                lastError = "Nobody is in range yet, so this wasn't sent. Direct messages wait and send automatically; public and group messages need someone nearby."
                return nil
            }
            if key == ConversationKey.nearby {
                id = try node.sendBroadcast(content)
            } else if let peer = ConversationKey.peer(from: key) {
                id = try node.sendDirect(content, to: peer)
                status = node.outgoingStatus(id) ?? .queued
            } else if let groupID = ConversationKey.groupID(from: key) {
                id = try node.sendGroup(content, groupID: groupID)
            } else {
                return nil
            }
            storeOutgoing(id: id, content: content, key: key, status: status)
            return id
        } catch {
            lastError = "Couldn't send: \(error.localizedDescription)"
            return nil
        }
    }

    /// Returns false when nothing was sent (so the composer can keep the text).
    @discardableResult
    func sendText(_ text: String, to key: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.utf8.count <= 8_000 else {
            lastError = "Message too long"
            return false
        }
        return send(.text(trimmed), to: key) != nil
    }

    func retry(_ messageID: UUID) {
        node.retry(messageID)
        if let message = fetchMessage(messageID), let status = node.outgoingStatus(messageID) {
            message.status = status
        }
    }

    /// Triage (on-device), attach location (and, if chosen, the medical ID), and broadcast an SOS.
    func sendSOS(text: String, location: GeoPoint?, includeMedical: Bool = false) async -> SOSTriage {
        let triage = await ai.triage(text)
        let medical = includeMedical && !trust.medical.isEmpty ? trust.medical : nil
        let report = SOSReport(text: text, location: location, triage: triage, medical: medical)
        send(.sos(report), to: ConversationKey.nearby)
        return triage
    }

    /// Respond to (or, for your own SOS, close) an SOS. Broadcast so every board updates.
    @discardableResult
    func sendSOSUpdate(sosID: UUID, status: SOSStatus, note: String? = nil) -> Bool {
        send(.sosUpdate(SOSUpdate(sosID: sosID, status: status, note: note)), to: ConversationKey.nearby) != nil
    }

    /// Live status of an SOS from the updates stored in the Nearby channel.
    func sosState(for sos: StoredMessage) -> SOSState {
        let key = ConversationKey.nearby
        let since = sos.sentAt.addingTimeInterval(-1)
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationKey == key && $0.sentAt >= since })
        let updates: [SOSTracker.Update] = ((try? context.fetch(descriptor)) ?? []).compactMap { message in
            guard case .sosUpdate(let update)? = message.content, let from = message.sender else { return nil }
            return SOSTracker.Update(from: from, update: update, at: message.sentAt)
        }
        return SOSTracker.state(sosID: sos.id, sender: sos.sender ?? myPeerID, sentAt: sos.sentAt, updates: updates)
    }

    /// "I'm safe" / "I need help" to the given groups (defaults to every group you're in).
    func sendCheckIn(_ status: CheckIn.Status, note: String? = nil, location: GeoPoint? = nil,
                     inReplyTo: UUID? = nil, groups groupIDs: [UUID]? = nil) -> Int {
        let targets = groupIDs ?? Array(node.groups.keys)
        let checkIn = CheckIn(status: status, location: location, batteryPercent: batteryPercent, note: note, inReplyTo: inReplyTo)
        return targets.reduce(0) { $0 + (send(.checkIn(checkIn), to: ConversationKey.group($1)) != nil ? 1 : 0) }
    }

    /// Ask everyone in a group "Are you safe?".
    @discardableResult
    func askAreYouSafe(groupKey: String, note: String? = nil) -> Bool {
        send(.safetyCheck(SafetyCheck(note: note)), to: groupKey) != nil
    }

    /// Latest check-in per member of a group, for the family locator.
    func familyEntries(groupKey: String) -> [FamilyLocator.Entry] {
        guard let group = group(for: groupKey) else { return [] }
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationKey == groupKey })
        let checkIns: [(PeerID, CheckIn, Date)] = ((try? context.fetch(descriptor)) ?? []).compactMap { message in
            guard case .checkIn(let checkIn)? = message.content, let from = message.sender else { return nil }
            return (from, checkIn, message.sentAt)
        }
        return FamilyLocator.entries(members: group.members, checkIns: checkIns, now: Date())
    }

    /// Admin only: remove a member from a group (re-keys so they can't read anything newer).
    func removeMember(_ peer: PeerID, groupKey: String) {
        guard let groupID = ConversationKey.groupID(from: groupKey) else { return }
        do {
            try node.removeMember(peer, from: groupID)
            storeLocal(id: UUID(), content: .text("You removed \(displayName(for: peer)) and changed the group key"),
                       key: groupKey, outgoing: true, senderName: nickname)
            refreshPeers()
            saveSnapshot()
        } catch {
            lastError = "Only the group admin can remove members."
        }
    }

    func isGroupAdmin(groupKey: String) -> Bool { group(for: groupKey)?.admin == myPeerID }

    // MARK: - Battery

    private(set) var batteryPercent: Int?

    private func startBatteryMonitoring() {
        guard mode == .bluetooth else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePowerState() }
            }
        }
        updatePowerState()
    }

    /// Low (<20%) and critical (<10%) batteries relay and carry less; plugged in is always normal.
    func updatePowerState(level: Float? = nil, state: UIDevice.BatteryState? = nil) {
        let level = level ?? UIDevice.current.batteryLevel
        let state = state ?? UIDevice.current.batteryState
        batteryPercent = level >= 0 ? Int((level * 100).rounded()) : nil
        let charging = state == .charging || state == .full
        let power: MeshNode.PowerState
        if charging || level < 0 { power = .normal } else if level < 0.10 { power = .critical } else if level < 0.20 { power = .low } else { power = .normal }
        if node.powerState != power { node.powerState = power }
    }

    /// Answer locally when this phone has a model; otherwise ask the nearest capable peer;
    /// otherwise fall back to the offline guidance library.
    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let query = AIQuery(prompt: trimmed)
        let session = self.session

        if !ai.hasGenerativeModel, let helper = node.bestAIHelper() {
            do {
                // Stored under the mesh message ID so delivery updates / retry apply to it.
                let messageID = try node.sendDirect(.aiQuery(query), to: helper.peerID)
                storeLocal(id: messageID, content: .aiQuery(query), key: ConversationKey.askMesh, outgoing: true,
                           senderName: nickname, status: node.outgoingStatus(messageID) ?? .sent)
                pendingQuestions[query.queryID] = helper.peerID
                // If nobody answers in time, fall back to local guidance.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    await self?.fallbackIfUnanswered(query, session: session)
                }
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
        storeLocal(id: UUID(), content: .aiQuery(query), key: ConversationKey.askMesh, outgoing: true, senderName: nickname)
        let answer = await ai.answer(trimmed)
        guard session == self.session else { return }
        let source = ai.hasGenerativeModel ? "This phone (on-device AI)" : "Offline guide"
        storeLocal(id: UUID(), content: .aiResponse(AIResponse(queryID: query.queryID, text: answer, answeredBy: source)),
                   key: ConversationKey.askMesh, outgoing: false, senderName: source)
    }

    private func fallbackIfUnanswered(_ query: AIQuery, session: UUID) async {
        guard session == self.session, pendingQuestions[query.queryID] != nil else { return }
        pendingQuestions[query.queryID] = nil
        let answer = await OfflineKnowledgeEngine().answer(query.prompt)
        guard session == self.session else { return }
        storeLocal(id: UUID(), content: .aiResponse(AIResponse(queryID: query.queryID, text: answer,
                                                               answeredBy: "Offline guide (no reply from mesh)")),
                   key: ConversationKey.askMesh, outgoing: false, senderName: "Offline guide")
    }

    // MARK: - Conversations

    @discardableResult
    func startDirectConversation(with peer: PeerInfo) -> String {
        startDirectConversation(with: peer.peerID, name: peer.nickname)
    }

    @discardableResult
    func startDirectConversation(with peer: PeerID, name: String) -> String {
        let key = ConversationKey.direct(peer)
        ensureConversation(key, kind: .direct, title: node.peer(peer)?.nickname ?? name)
        return key
    }

    /// Demo mode only: refresh published state as the simulated mesh advances.
    func refreshPeersIfChanged() {
        if node.peers != peers { refreshPeers() }
        if node.linkCount != linkCount { linkCount = node.linkCount }
        refreshStats()
    }

    /// Demo mode only: simulate walking out of / back into range of everyone.
    func setDemoLinks(enabled: Bool) {
        demo?.setLocalLinks(enabled: enabled)
        refreshPeers()
    }

    @discardableResult
    func createGroup(name: String, members: Set<PeerID>) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !members.isEmpty else { return nil }
        do {
            let group = try node.createGroup(name: trimmed, members: members)
            let key = ConversationKey.group(group.id)
            ensureConversation(key, kind: .group, title: trimmed)
            storeLocal(id: UUID(), content: .text("You created “\(trimmed)” with \(members.count) member\(members.count == 1 ? "" : "s")"),
                       key: key, outgoing: true, senderName: nickname)
            refreshPeers()
            saveSnapshot() // group keys must survive an immediate app kill
            return key
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func leaveGroup(key: String) {
        guard let groupID = ConversationKey.groupID(from: key) else { return }
        node.leaveGroup(groupID)
        deleteConversation(key: key)
        refreshPeers()
        saveSnapshot()
    }

    func group(for key: String) -> GroupInfo? {
        ConversationKey.groupID(from: key).flatMap { node.groups[$0] }
    }

    func deleteConversation(key: String) {
        guard key != ConversationKey.nearby, key != ConversationKey.askMesh else { return }
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationKey == key })
        for message in (try? context.fetch(descriptor)) ?? [] { context.delete(message) }
        if let conversation = fetchConversation(key) { context.delete(conversation) }
        try? context.save()
    }

    /// Mark a conversation read and send read receipts for direct messages.
    func markRead(key: String) {
        guard let conversation = fetchConversation(key) else { return }
        conversation.unreadCount = 0
        guard let peer = ConversationKey.peer(from: key) else { return }
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate {
            $0.conversationKey == key && $0.isOutgoing == false && $0.readReceiptSent == false
        })
        for message in (try? context.fetch(descriptor)) ?? [] {
            node.sendReadReceipt(for: message.id, to: peer)
            message.readReceiptSent = true
        }
        try? context.save()
    }

    func displayName(for peer: PeerID) -> String {
        if peer == myPeerID { return nickname }
        return node.peer(peer)?.nickname ?? "Device \(peer.short)"
    }

    func peerInfo(_ id: PeerID) -> PeerInfo? { node.peer(id) }

    var aiHelperAvailable: Bool { ai.hasGenerativeModel || node.bestAIHelper() != nil }

    // MARK: - Digest

    func refreshDigest() async {
        let session = self.session
        isBuildingDigest = true
        defer { isBuildingDigest = false }
        let since = Date().addingTimeInterval(-3600)
        let key = ConversationKey.nearby
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate {
            $0.conversationKey == key && $0.sentAt > since
        })
        let messages = (try? context.fetch(descriptor)) ?? []
        let inputs: [DigestInput] = messages.compactMap { message in
            guard let sender = message.sender, let content = message.content else { return nil }
            switch content {
            case .text(let text): return DigestInput(sender: sender, text: text, date: message.sentAt)
            case .voice(let note): return DigestInput(sender: sender, text: note.transcript, date: message.sentAt)
            case .sos(let report): return DigestInput(sender: sender, text: report.text, date: message.sentAt, triage: report.triage)
            default: return nil
            }
        }
        let built = DigestBuilder.build(from: inputs, now: Date())
        digest = built
        digestOverview = built.overview
        let overview = await ai.overview(for: built, recentTexts: inputs.map(\.text))
        guard session == self.session else { return }
        digestOverview = overview
    }

    // MARK: - Panic wipe

    /// Erase all messages, keys, groups and queued data, then start over with a new identity.
    func panicWipe() {
        session = UUID() // in-flight tasks from the old identity stand down
        tickTimer?.invalidate()
        bleTransport?.stop()
        demo?.stop()
        node.forgetAll()
        try? context.delete(model: StoredMessage.self)
        try? context.delete(model: StoredConversation.self)
        try? context.save()
        if let snapshotURL { try? FileManager.default.removeItem(at: snapshotURL) }
        IdentityStore.wipe()
        trust.wipe()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        node = MeshNode(identity: mode == .demo ? MeshIdentity() : IdentityStore.loadOrCreate(), nickname: IdentityStore.nickname)
        configureNode()
        bleTransport = nil
        demo = nil
        start()
        ensureConversation(ConversationKey.nearby, kind: .nearby, title: "Nearby")
        ensureConversation(ConversationKey.askMesh, kind: .askMesh, title: "Ask the Mesh")
        digest = nil
        digestOverview = ""
        pendingQuestions = [:]
        stats = MeshStats()
        lastError = nil
        refreshPeers()
    }

    // MARK: - Persistence helpers

    private static var defaultSnapshotURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mesh-node.json")
    }

    private func saveSnapshot() {
        snapshotDirty = false
        guard let snapshotURL, let data = try? JSONEncoder().encode(node.snapshot()) else { return }
        try? data.write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func restoreSnapshot() {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(MeshNodeSnapshot.self, from: data) else { return }
        node.restore(snapshot)
        refreshPeers()
    }

    func purgeExpiredMessages() {
        guard settings.retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(settings.retentionDays) * 86_400)
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.receivedAt < cutoff })
        for message in (try? context.fetch(descriptor)) ?? [] { context.delete(message) }
        try? context.save()
    }

    @discardableResult
    func ensureConversation(_ key: String, kind: ConversationKind, title: String) -> StoredConversation {
        if let existing = fetchConversation(key) { return existing }
        let conversation = StoredConversation(key: key, kind: kind, title: title)
        context.insert(conversation)
        try? context.save()
        return conversation
    }

    func fetchConversation(_ key: String) -> StoredConversation? {
        var descriptor = FetchDescriptor<StoredConversation>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func fetchMessage(_ id: UUID) -> StoredMessage? {
        var descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func storeOutgoing(id: UUID, content: MeshContent, key: String, status: DeliveryStatus) {
        storeLocal(id: id, content: content, key: key, outgoing: true, senderName: nickname, status: status)
    }

    private func storeLocal(id: UUID, content: MeshContent, key: String, outgoing: Bool, senderName: String,
                            sender: PeerID? = nil, sentAt: Date = Date(), hops: Int = 0, status: DeliveryStatus = .sent) {
        guard fetchMessage(id) == nil else { return }
        let message = StoredMessage(id: id, conversationKey: key, senderHex: (sender ?? myPeerID).hex,
                                    senderName: senderName, isOutgoing: outgoing, content: content,
                                    sentAt: sentAt, hops: hops, status: status)
        context.insert(message)
        if let conversation = fetchConversation(key) {
            conversation.updatedAt = Date()
            conversation.lastPreview = content.previewText
            if !outgoing && !(openConversationKey == key && isVisible) { conversation.unreadCount += 1 }
        }
        try? context.save()
        snapshotDirty = true
    }

    // MARK: - Incoming

    fileprivate func handle(_ message: ReceivedMessage) {
        let envelope = message.envelope
        let sender = message.sender
        let senderName = node.peer(sender)?.nickname ?? envelope.senderName
        // Blocked devices are invisible on this phone (their traffic is still relayed for others).
        guard !trust.isBlocked(sender) else { return }

        switch envelope.content {
        case .aiQuery(let query):
            answerQuery(query, from: sender)
            return
        case .aiResponse(let response):
            // Only answers to questions we asked, from the phone we asked. The display name comes
            // from the verified mesh identity, not from the (sender-controlled) `answeredBy` text.
            guard pendingQuestions[response.queryID] == sender else { return }
            pendingQuestions[response.queryID] = nil
            let label = "\(senderName)’s on-device AI"
            let verified = AIResponse(queryID: response.queryID, text: response.text, answeredBy: label)
            storeLocal(id: envelope.messageID, content: .aiResponse(verified), key: ConversationKey.askMesh, outgoing: false,
                       senderName: label, sender: sender, sentAt: envelope.sentAt, hops: message.hops)
            notify(title: "Answer from \(label)", body: response.text, key: ConversationKey.askMesh)
            return
        case .groupInvite(let invite):
            let key = ConversationKey.group(invite.groupID)
            let isRekey = fetchConversation(key) != nil
            ensureConversation(key, kind: .group, title: invite.name)
            let note = isRekey ? "🔑 \(senderName) changed the group key (membership changed)" : "\(senderName) added you to “\(invite.name)”"
            storeLocal(id: envelope.messageID, content: .text(note), key: key,
                       outgoing: false, senderName: senderName, sender: sender, sentAt: envelope.sentAt, hops: message.hops)
            refreshPeers()
            saveSnapshot()
            return
        case .groupLeave(let groupID):
            let key = ConversationKey.group(groupID)
            guard fetchConversation(key) != nil else { return }
            storeLocal(id: envelope.messageID, content: .text("\(senderName) left the group"), key: key,
                       outgoing: false, senderName: senderName, sender: sender, sentAt: envelope.sentAt, hops: message.hops)
            refreshPeers()
            saveSnapshot()
            return
        default:
            break
        }

        let key: String
        switch message.scope {
        case .broadcast:
            key = ConversationKey.nearby
        case .direct:
            key = ConversationKey.direct(sender)
            ensureConversation(key, kind: .direct, title: senderName)
        case .group(let groupID):
            key = ConversationKey.group(groupID)
            ensureConversation(key, kind: .group, title: node.groups[groupID]?.name ?? "Group")
        }
        storeLocal(id: envelope.messageID, content: envelope.content, key: key, outgoing: false,
                   senderName: senderName, sender: sender, sentAt: envelope.sentAt, hops: message.hops)

        if openConversationKey == key, isVisible, message.scope == .direct {
            node.sendReadReceipt(for: envelope.messageID, to: sender)
            fetchMessage(envelope.messageID)?.readReceiptSent = true
        }

        switch envelope.content {
        case .sos(let report):
            let priority = report.triage?.priority.label ?? "SOS"
            notify(title: "🆘 \(priority) SOS from \(senderName)", body: report.triage?.summary ?? report.text, key: key, critical: true)
        case .safetyCheck:
            notify(title: "\(senderName) asks: are you safe?", body: "Tap to answer “I'm safe” or “I need help”.", key: key, critical: true)
        case .checkIn(let checkIn) where checkIn.status == .needHelp:
            notify(title: "⚠️ \(senderName) needs help", body: checkIn.note ?? "Open the family locator.", key: key, critical: true)
        case .sosUpdate:
            break // shown on the SOS board; no alert
        default:
            guard message.scope != .broadcast else { break }
            notify(title: senderName, body: envelope.content.previewText, key: key)
        }
    }

    private func answerQuery(_ query: AIQuery, from sender: PeerID) {
        guard settings.helpOthersWithAI, ai.hasGenerativeModel else { return }
        let node = self.node
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.ai.answer(query.prompt)
            // Never answer from a new identity after a panic wipe (would link old and new).
            guard self.node === node else { return }
            let response = AIResponse(queryID: query.queryID, text: answer, answeredBy: "\(self.nickname)’s on-device AI")
            _ = try? node.sendDirect(.aiResponse(response), to: sender)
        }
    }

    private func notify(title: String, body: String, key: String, critical: Bool = false) {
        guard settings.notificationsEnabled, mode == .bluetooth,
              UIApplication.shared.applicationState != .active || (openConversationKey != key && critical) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = critical ? .defaultCritical : .default
        content.threadIdentifier = key
        content.userInfo = ["conversation": key]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}

// MARK: - MeshNodeDelegate

extension MeshService: MeshNodeDelegate {
    nonisolated func meshNode(_ node: MeshNode, didReceive message: ReceivedMessage) {
        MainActor.assumeIsolated { handle(message) }
    }

    nonisolated func meshNode(_ node: MeshNode, didUpdateDelivery messageID: UUID, status: DeliveryStatus) {
        MainActor.assumeIsolated {
            snapshotDirty = true // the outbox changed even if no stored message matches (control traffic)
            guard let message = fetchMessage(messageID) else { return }
            if status > message.status || message.status == .failed {
                message.status = status
                try? context.save()
            }
        }
    }

    nonisolated func meshNodeDidUpdatePeers(_ node: MeshNode) {
        MainActor.assumeIsolated {
            refreshPeers()
            refreshRadioState()
            snapshotDirty = true
        }
    }
}
