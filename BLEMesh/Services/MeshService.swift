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
    @Published private(set) var pendingQuestions: Set<UUID> = []
    @Published var lastError: String?
    /// Conversation currently on screen (incoming messages there don't count as unread).
    @Published var openConversationKey: String?

    let mode: Mode
    let settings: AppSettings
    let container: ModelContainer
    private(set) var ai: AIEngine
    private(set) var node: MeshNode
    private var bleTransport: BLETransport?
    private var demo: DemoMesh?
    private var tickTimer: Timer?
    private var snapshotDirty = false
    private let snapshotURL: URL?

    var context: ModelContext { container.mainContext }
    var myPeerID: PeerID { node.peerID }
    var myFingerprint: String { node.identity.publicIdentity.fingerprint }
    var nickname: String { node.nickname }

    init(mode: Mode, container: ModelContainer, settings: AppSettings,
         ai: AIEngine? = nil, identity: MeshIdentity? = nil, persistSnapshot: Bool = true) {
        self.mode = mode
        self.container = container
        self.settings = settings
        self.ai = ai ?? AIEngineFactory.make()
        self.snapshotURL = persistSnapshot ? Self.defaultSnapshotURL : nil
        let identity = identity ?? (mode == .demo ? MeshIdentity() : IdentityStore.loadOrCreate())
        self.node = MeshNode(identity: identity, nickname: IdentityStore.nickname)
        configureNode()
        restoreSnapshot()
        start()
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

    func sendText(_ text: String, to key: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.utf8.count <= 8_000 else {
            lastError = "Message too long"
            return
        }
        send(.text(trimmed), to: key)
    }

    func retry(_ messageID: UUID) {
        node.retry(messageID)
        if let message = fetchMessage(messageID), let status = node.outgoingStatus(messageID) {
            message.status = status
        }
    }

    /// Triage (on-device), attach location if allowed, and broadcast an SOS to everyone nearby.
    func sendSOS(text: String, location: GeoPoint?) async -> SOSTriage {
        let triage = await ai.triage(text)
        let report = SOSReport(text: text, location: location, triage: triage)
        send(.sos(report), to: ConversationKey.nearby)
        return triage
    }

    /// Answer locally when this phone has a model; otherwise ask the nearest capable peer;
    /// otherwise fall back to the offline guidance library.
    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let query = AIQuery(prompt: trimmed)
        let questionID = UUID()
        storeLocal(id: questionID, content: .aiQuery(query), key: ConversationKey.askMesh, outgoing: true,
                   senderName: nickname)

        if !ai.hasGenerativeModel, let helper = node.bestAIHelper() {
            do {
                let messageID = try node.sendDirect(.aiQuery(query), to: helper.peerID)
                pendingQuestions.insert(query.queryID)
                if let stored = fetchMessage(questionID) { stored.status = node.outgoingStatus(messageID) ?? .sent }
                // If nobody answers in time, fall back to local guidance.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    await self?.fallbackIfUnanswered(query)
                }
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
        let answer = await ai.answer(trimmed)
        let source = ai.hasGenerativeModel ? "This phone (on-device AI)" : "Offline guide"
        storeLocal(id: UUID(), content: .aiResponse(AIResponse(queryID: query.queryID, text: answer, answeredBy: source)),
                   key: ConversationKey.askMesh, outgoing: false, senderName: source)
    }

    private func fallbackIfUnanswered(_ query: AIQuery) async {
        guard pendingQuestions.contains(query.queryID) else { return }
        pendingQuestions.remove(query.queryID)
        let answer = await OfflineKnowledgeEngine().answer(query.prompt)
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
        digestOverview = overview
    }

    // MARK: - Panic wipe

    /// Erase all messages, keys, groups and queued data, then start over with a new identity.
    func panicWipe() {
        tickTimer?.invalidate()
        bleTransport?.stop()
        demo?.stop()
        node.forgetAll()
        try? context.delete(model: StoredMessage.self)
        try? context.delete(model: StoredConversation.self)
        try? context.save()
        if let snapshotURL { try? FileManager.default.removeItem(at: snapshotURL) }
        IdentityStore.wipe()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        node = MeshNode(identity: mode == .demo ? MeshIdentity() : IdentityStore.loadOrCreate(), nickname: IdentityStore.nickname)
        configureNode()
        bleTransport = nil
        demo = nil
        start()
        ensureConversation(ConversationKey.nearby, kind: .nearby, title: "Nearby")
        ensureConversation(ConversationKey.askMesh, kind: .askMesh, title: "Ask the Mesh")
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
            if !outgoing && openConversationKey != key { conversation.unreadCount += 1 }
        }
        try? context.save()
        snapshotDirty = true
    }

    // MARK: - Incoming

    fileprivate func handle(_ message: ReceivedMessage) {
        let envelope = message.envelope
        let sender = message.sender
        let senderName = node.peer(sender)?.nickname ?? envelope.senderName

        switch envelope.content {
        case .aiQuery(let query):
            answerQuery(query, from: sender)
            return
        case .aiResponse(let response):
            pendingQuestions.remove(response.queryID)
            storeLocal(id: envelope.messageID, content: envelope.content, key: ConversationKey.askMesh, outgoing: false,
                       senderName: response.answeredBy, sender: sender, sentAt: envelope.sentAt, hops: message.hops)
            notify(title: "Answer from \(response.answeredBy)", body: response.text, key: ConversationKey.askMesh)
            return
        case .groupInvite(let invite):
            let key = ConversationKey.group(invite.groupID)
            ensureConversation(key, kind: .group, title: invite.name)
            storeLocal(id: envelope.messageID, content: .text("\(senderName) added you to “\(invite.name)”"), key: key,
                       outgoing: false, senderName: senderName, sender: sender, sentAt: envelope.sentAt, hops: message.hops)
            refreshPeers()
            return
        case .groupLeave(let groupID):
            let key = ConversationKey.group(groupID)
            guard fetchConversation(key) != nil else { return }
            storeLocal(id: envelope.messageID, content: .text("\(senderName) left the group"), key: key,
                       outgoing: false, senderName: senderName, sender: sender, sentAt: envelope.sentAt, hops: message.hops)
            refreshPeers()
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

        if openConversationKey == key, message.scope == .direct {
            node.sendReadReceipt(for: envelope.messageID, to: sender)
            fetchMessage(envelope.messageID)?.readReceiptSent = true
        }

        if case .sos(let report) = envelope.content {
            let priority = report.triage?.priority.label ?? "SOS"
            notify(title: "🆘 \(priority) SOS from \(senderName)", body: report.triage?.summary ?? report.text, key: key, critical: true)
        } else if message.scope != .broadcast {
            notify(title: senderName, body: envelope.content.previewText, key: key)
        }
    }

    private func answerQuery(_ query: AIQuery, from sender: PeerID) {
        guard settings.helpOthersWithAI, ai.hasGenerativeModel else { return }
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.ai.answer(query.prompt)
            let response = AIResponse(queryID: query.queryID, text: answer, answeredBy: "\(self.nickname)’s on-device AI")
            _ = try? self.node.sendDirect(.aiResponse(response), to: sender)
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
            guard let message = fetchMessage(messageID) else { return }
            if status > message.status || message.status == .failed {
                message.status = status
                try? context.save()
            }
            snapshotDirty = true
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
