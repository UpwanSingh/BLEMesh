import Foundation

/// Tunables for a mesh node. Defaults target small phone meshes (≤ ~50 devices).
public struct MeshConfig: Sendable {
    /// Hop budget for user messages and acks (also the cap applied to inbound TTLs).
    public var messageTTL: UInt8 = 7
    /// Flood radius for presence announces (also the cap applied to inbound announce TTLs).
    public var announceTTL: UInt8 = 5
    public var announceInterval: TimeInterval = 20
    /// Routes not refreshed by an announce within this window are dropped.
    public var routeExpiry: TimeInterval = 75
    /// Delay before each retransmission of an unacknowledged direct message.
    public var retrySchedule: [TimeInterval] = [4, 8, 15, 30, 60, 120, 240]
    /// Transmissions before a direct message is reported failed (it can still be delivered later).
    public var maxDeliveryAttempts: Int = 8
    /// Minimum spacing between transmissions of one message, even when a route (re)appears.
    public var minRetrySpacing: TimeInterval = 2
    /// How long a message may wait for the recipient's keys / any link before failing.
    public var outboxLifetime: TimeInterval = 24 * 3600
    /// How long finished (delivered/read/failed) outbox entries are kept for late receipts.
    public var finishedRetention: TimeInterval = 24 * 3600
    public var maxOutboxEntries: Int = 1000
    /// Store-and-forward: directed packets carried for unreachable destinations.
    public var carryCapacity: Int = 200
    public var carryPerOriginCapacity: Int = 20
    public var carryLifetime: TimeInterval = 6 * 3600
    /// Oldest acceptable message/ack (must cover the carry lifetime so carried packets still land).
    public var maxMessageAge: TimeInterval = 6 * 3600
    /// Oldest acceptable announce/hello — presence is only meaningful when fresh.
    public var maxAnnounceAge: TimeInterval = 120
    /// Packets timestamped further in the future than this are rejected.
    public var maxFutureSkew: TimeInterval = 600
    /// Duplicate suppression; must outlive `maxMessageAge` so replays inside the window are caught.
    public var seenLifetime: TimeInterval = 7 * 3600
    public var seenCapacity: Int = 16_384
    /// Per-origin relay budget for fresh traffic (anti-flood).
    public var relayBurst: Double = 40
    public var relayRefillPerSecond: Double = 4
    /// Separate, smaller budget for old (carried/replayed) traffic so it can't starve live traffic.
    public var staleRelayBurst: Double = 20
    public var staleRelayRefillPerSecond: Double = 1
    /// Packets older than this count as "stale" for rate limiting.
    public var staleThreshold: TimeInterval = 120
    /// Peer directory bounds.
    public var maxKnownPeers: Int = 1000
    public var peerRetention: TimeInterval = 30 * 24 * 3600

    public init() {}
}

/// Counters for diagnostics.
public struct MeshStats: Equatable, Sendable {
    public var packetsReceived = 0
    public var packetsSent = 0
    public var relayed = 0
    public var duplicatesDropped = 0
    public var invalidDropped = 0
    public var staleDropped = 0
    public var rateLimited = 0
    public var messagesDelivered = 0
    public var carried = 0

    public init() {}
}

/// A group this device belongs to.
public struct GroupInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var members: Set<PeerID>
    public var key: Data
    /// Who created the group; only they may re-key / change an existing group.
    public var creator: PeerID?

    public init(id: UUID, name: String, members: Set<PeerID>, key: Data, creator: PeerID? = nil) {
        self.id = id
        self.name = name
        self.members = members
        self.key = key
        self.creator = creator
    }
}

/// A direct message this device is responsible for delivering.
public struct OutgoingMessage: Codable, Equatable, Sendable {
    public var messageID: UUID
    public var destination: PeerID
    public var envelope: Data
    public var status: DeliveryStatus
    public var attempts: Int
    public var createdAt: Date
    public var nextAttemptAt: Date
    public var packetIDs: [UUID]
    public var lastAttemptAt: Date?
}

/// Persistable node state (outbox, groups, known peer keys).
public struct MeshNodeSnapshot: Codable, Sendable {
    public struct KnownPeer: Codable, Sendable {
        public var signingKey: Data
        public var agreementKey: Data
        public var nickname: String
        public var capabilities: UInt8
        public var lastSeen: Date
    }

    public var outgoing: [OutgoingMessage]
    public var groups: [GroupInfo]
    public var peers: [KnownPeer]
    public var leftGroups: [UUID: Date]?
}

/// The mesh protocol engine.
///
/// Transport-agnostic and single-threaded: call every method from the same thread/actor.
/// Time comes from the injected clock and periodic work runs in `tick()`, which makes the
/// node fully deterministic under the simulator.
///
/// Threat model: any device may inject packets and relays are untrusted. Every packet is
/// signed by its origin; direct/group ciphertexts are bound to the signer; neighbour status
/// requires a per-link nonce proof; replays are bounded by per-type age limits plus a
/// duplicate cache that outlives them; relays are rate limited per origin.
public final class MeshNode {
    static let nullUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public let identity: MeshIdentity
    public var nickname: String
    public var capabilities: PeerCapabilities
    public let config: MeshConfig
    public weak var delegate: MeshNodeDelegate?
    public weak var transport: MeshTransport?

    public var peerID: PeerID { identity.peerID }
    public private(set) var stats = MeshStats()
    public private(set) var groups: [UUID: GroupInfo] = [:]

    private let clock: () -> Date
    private var links: Set<LinkID> = []
    /// Our hello nonce per link, and the neighbour that proved itself on it.
    private var linkNonces: [LinkID: Data] = [:]
    private var answeredNonce: [LinkID: Data] = [:]
    private var provenNeighbor: [LinkID: PeerID] = [:]
    private var directory: [PeerID: PeerInfo] = [:]
    private var routing: RoutingTable
    private var seenPackets: SeenCache<UUID>
    /// Delivered (origin, messageID) pairs — app-level dedup across retransmissions.
    private var deliveredMessages: SeenCache<String>
    private let reassembler = Reassembler()
    private var freshLimiter: RateLimiter
    private var staleLimiter: RateLimiter
    private var outgoing: [UUID: OutgoingMessage] = [:]
    private var carry: [UUID: (packet: Packet, storedAt: Date)] = [:]
    private var lastAnnounceByPeer: [PeerID: Packet] = [:]
    private var leftGroups: [UUID: Date] = [:]
    private var lastAnnounceAt: Date?
    private var lastHousekeepingAt: Date?

    public init(
        identity: MeshIdentity,
        nickname: String,
        capabilities: PeerCapabilities = [],
        config: MeshConfig = MeshConfig(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.identity = identity
        self.nickname = nickname
        self.capabilities = capabilities
        self.config = config
        self.clock = clock
        self.routing = RoutingTable(expiry: config.routeExpiry)
        self.seenPackets = SeenCache(capacity: config.seenCapacity, lifetime: config.seenLifetime)
        self.deliveredMessages = SeenCache(capacity: config.seenCapacity, lifetime: 7 * 24 * 3600)
        self.freshLimiter = RateLimiter(burst: config.relayBurst, refillPerSecond: config.relayRefillPerSecond)
        self.staleLimiter = RateLimiter(burst: config.staleRelayBurst, refillPerSecond: config.staleRelayRefillPerSecond)
    }

    // MARK: - Peers

    /// All peers we hold keys for, with current reachability.
    public var peers: [PeerInfo] {
        let now = clock()
        return directory.values.map { info in
            var copy = info
            copy.hops = routing.route(to: info.peerID, now: now)?.hops
            return copy
        }.sorted { ($0.hops ?? .max, $0.nickname) < ($1.hops ?? .max, $1.nickname) }
    }

    public var reachablePeers: [PeerInfo] { peers.filter(\.isReachable) }

    public func peer(_ id: PeerID) -> PeerInfo? {
        guard var info = directory[id] else { return nil }
        info.hops = routing.route(to: id, now: clock())?.hops
        return info
    }

    /// Nearest reachable peer that advertises an on-device model.
    public func bestAIHelper() -> PeerInfo? {
        reachablePeers.first { $0.capabilities.contains(.onDeviceAI) }
    }

    public var linkCount: Int { links.count }

    public func outgoingStatus(_ messageID: UUID) -> DeliveryStatus? { outgoing[messageID]?.status }

    // MARK: - Sending

    /// Send to the public nearby channel (signed, not encrypted).
    @discardableResult
    public func sendBroadcast(_ content: MeshContent) throws -> UUID {
        let now = clock()
        let envelope = MessageEnvelope(sentAt: now, senderName: nickname, content: content)
        let packet = try Packet.make(type: .message, ttl: config.messageTTL, destination: .broadcast,
                                     payload: try envelope.encode(), identity: identity, now: now)
        originate(packet)
        return envelope.messageID
    }

    /// Send an end-to-end encrypted message. Tracked until acknowledged; queued if the
    /// recipient's keys are unknown or no link exists yet.
    @discardableResult
    public func sendDirect(_ content: MeshContent, to destination: PeerID) throws -> UUID {
        let now = clock()
        let envelope = MessageEnvelope(sentAt: now, senderName: nickname, content: content)
        let message = OutgoingMessage(
            messageID: envelope.messageID, destination: destination,
            envelope: try envelope.encode(), status: .queued, attempts: 0,
            createdAt: now, nextAttemptAt: now, packetIDs: [], lastAttemptAt: nil
        )
        outgoing[message.messageID] = message
        attemptDelivery(message.messageID, now: now)
        return message.messageID
    }

    /// Manually retry a failed message.
    public func retry(_ messageID: UUID) {
        guard var message = outgoing[messageID], message.status == .failed else { return }
        let now = clock()
        message.status = message.attempts > 0 ? .sent : .queued
        message.attempts = 0
        message.createdAt = now
        message.nextAttemptAt = now
        message.lastAttemptAt = nil
        outgoing[messageID] = message
        attemptDelivery(messageID, now: now)
    }

    /// Send to a group (encrypted with the group key, flooded).
    @discardableResult
    public func sendGroup(_ content: MeshContent, groupID: UUID) throws -> UUID {
        guard let group = groups[groupID] else { throw MeshNodeError.unknownGroup }
        let now = clock()
        let envelope = MessageEnvelope(sentAt: now, senderName: nickname, groupID: groupID, content: content)
        let sealed = try MeshCrypto.sealGroup(try envelope.encode(), groupID: groupID, key: group.key,
                                              from: identity.publicIdentity.signingKey)
        let packet = try Packet.make(type: .message, flags: .groupEncrypted, ttl: config.messageTTL,
                                     destination: .broadcast, payload: sealed, identity: identity, now: now)
        originate(packet)
        return envelope.messageID
    }

    /// Create a group and invite members over E2E direct messages.
    @discardableResult
    public func createGroup(name: String, members: Set<PeerID>) throws -> GroupInfo {
        let all = members.union([peerID])
        let group = GroupInfo(id: UUID(), name: name, members: all, key: MeshCrypto.makeGroupKey(), creator: peerID)
        groups[group.id] = group
        let invite = GroupInvite(groupID: group.id, name: name, members: Array(all).sorted(), key: group.key)
        for member in all where member != peerID {
            try sendDirect(.groupInvite(invite), to: member)
        }
        return group
    }

    /// Leave a group and tell the other members.
    public func leaveGroup(_ groupID: UUID) {
        guard let group = groups.removeValue(forKey: groupID) else { return }
        leftGroups[groupID] = clock()
        for member in group.members where member != peerID {
            _ = try? sendDirect(.groupLeave(groupID: groupID), to: member)
        }
    }

    /// Tell `sender` that we read `messageID` (best effort, not retried).
    public func sendReadReceipt(for messageID: UUID, to sender: PeerID) {
        sendAck(.read, messageID: messageID, ackedPacketID: Self.nullUUID, to: sender, now: clock())
    }

    /// Broadcast presence now.
    public func announce() {
        let now = clock()
        lastAnnounceAt = now
        let payload = AnnouncePayload(agreementKey: identity.publicIdentity.agreementKey,
                                      capabilities: capabilities, nickname: nickname)
        guard let packet = try? Packet.make(type: .announce, ttl: config.announceTTL, destination: .broadcast,
                                            payload: payload.encode(), identity: identity, now: now) else { return }
        originate(packet)
    }

    // MARK: - Transport events

    public func linkDidConnect(_ link: LinkID) {
        let now = clock()
        links.insert(link)
        // Prove ourselves to the new neighbour (and ask it to prove itself).
        let nonce = Self.randomNonce()
        linkNonces[link] = nonce
        sendHello(nonce: nonce, echo: HelloPayload.zeroNonce, on: link, now: now)
        announce()
        // Share what we know so the newcomer converges quickly (only still-fresh announces).
        for (peer, packet) in lastAnnounceByPeer
        where routing.route(to: peer, now: now) != nil
            && now.timeIntervalSince(packet.timestamp) < config.maxAnnounceAge - 15 {
            forward(packet, on: [link])
        }
        // Store-and-forward: hand carried packets to the newcomer.
        purgeCarry(now: now)
        for (_, entry) in carry { forward(entry.packet, on: [link]) }
        // Messages that never went out (no link existed) go now. Already-sent messages keep
        // their backoff; they are retried early only when their destination's route appears.
        for id in outgoing.keys where outgoing[id]!.status == .queued {
            outgoing[id]!.nextAttemptAt = now
        }
        processOutgoing(now: now)
    }

    public func linkDidDisconnect(_ link: LinkID) {
        links.remove(link)
        linkNonces[link] = nil
        answeredNonce[link] = nil
        provenNeighbor[link] = nil
        reassembler.reset(link: link)
        routing.removeRoutes(via: link)
        delegate?.meshNodeDidUpdatePeers(self)
    }

    /// Feed one inbound frame from the transport.
    public func receive(frame: Data, from link: LinkID) {
        let now = clock()
        guard let bytes = try? reassembler.accept(frame, from: link, now: now) else {
            return
        }
        guard var packet = try? Packet.decode(bytes), packet.verify() else {
            stats.invalidDropped += 1
            return
        }
        stats.packetsReceived += 1
        guard packet.origin != peerID else { return } // our own packet echoed back

        let age = now.timeIntervalSince(packet.timestamp)
        let maxAge = (packet.type == .announce || packet.type == .hello) ? config.maxAnnounceAge : config.maxMessageAge
        guard age >= -config.maxFutureSkew, age <= maxAge else {
            stats.staleDropped += 1
            return
        }
        guard seenPackets.insert(packet.packetID, now: now) else {
            stats.duplicatesDropped += 1
            return
        }
        // TTL is unsigned; never let a relay widen the flood radius beyond our own limits.
        packet.ttl = min(packet.ttl, packet.type == .announce ? config.announceTTL : config.messageTTL)

        switch packet.type {
        case .hello: handleHello(packet, from: link, now: now)
        case .announce: handleAnnounce(packet, from: link, now: now)
        case .message: handleMessage(packet, from: link, now: now)
        case .ack: handleAck(packet, from: link, now: now)
        }
    }

    /// Periodic maintenance: announces, retries, expiry. Call about once per second.
    public func tick() {
        let now = clock()
        if !links.isEmpty, lastAnnounceAt.map({ now.timeIntervalSince($0) >= config.announceInterval }) ?? true {
            announce()
        }
        let expired = routing.purge(now: now)
        for id in expired { lastAnnounceByPeer[id] = nil }
        if !expired.isEmpty { delegate?.meshNodeDidUpdatePeers(self) }
        reassembler.purge(now: now)
        purgeCarry(now: now)
        processOutgoing(now: now)
        if lastHousekeepingAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            lastHousekeepingAt = now
            housekeeping(now: now)
        }
    }

    // MARK: - Persistence

    public func snapshot() -> MeshNodeSnapshot {
        MeshNodeSnapshot(
            outgoing: Array(outgoing.values),
            groups: Array(groups.values),
            peers: directory.values.map {
                .init(signingKey: $0.identity.signingKey, agreementKey: $0.identity.agreementKey,
                      nickname: $0.nickname, capabilities: $0.capabilities.rawValue, lastSeen: $0.lastSeen)
            },
            leftGroups: leftGroups
        )
    }

    public func restore(_ snapshot: MeshNodeSnapshot) {
        for message in snapshot.outgoing { outgoing[message.messageID] = message }
        for group in snapshot.groups { groups[group.id] = group }
        for (id, date) in snapshot.leftGroups ?? [:] { leftGroups[id] = date }
        for known in snapshot.peers {
            let identity = PublicIdentity(signingKey: known.signingKey, agreementKey: known.agreementKey)
            guard identity.peerID != peerID else { continue }
            directory[identity.peerID] = PeerInfo(
                peerID: identity.peerID, identity: identity, nickname: known.nickname,
                capabilities: PeerCapabilities(rawValue: known.capabilities), lastSeen: known.lastSeen, hops: nil
            )
        }
    }

    /// Drop all stored state (used by "panic wipe" together with discarding the node).
    public func forgetAll() {
        outgoing.removeAll()
        groups.removeAll()
        leftGroups.removeAll()
        directory.removeAll()
        carry.removeAll()
        lastAnnounceByPeer.removeAll()
    }

    // MARK: - Inbound handling

    private func handleHello(_ packet: Packet, from link: LinkID, now: Date) {
        guard let hello = try? HelloPayload.decode(packet.payload) else {
            stats.invalidDropped += 1
            return
        }
        if let mine = linkNonces[link], hello.echoedNonce == mine, provenNeighbor[link] != packet.origin {
            provenNeighbor[link] = packet.origin
            routing.offer(packet.origin, link: link, hops: 0, now: now)
            routeAppeared(for: packet.origin, now: now)
            delegate?.meshNodeDidUpdatePeers(self)
        }
        if answeredNonce[link] != hello.nonce, let mine = linkNonces[link] {
            answeredNonce[link] = hello.nonce
            sendHello(nonce: mine, echo: hello.nonce, on: link, now: now)
        }
    }

    private func handleAnnounce(_ packet: Packet, from link: LinkID, now: Date) {
        guard let payload = try? AnnouncePayload.decode(packet.payload), payload.agreementKey.count == 32 else {
            stats.invalidDropped += 1
            return
        }
        let origin = packet.origin
        // `hops` is unsigned: a claimed 0 only counts for the neighbour proven on this link.
        let hops = packet.hops == 0 && provenNeighbor[link] != origin ? 1 : Int(packet.hops)
        let isNew = directory[origin] == nil
        let identity = PublicIdentity(signingKey: packet.originSigningKey, agreementKey: payload.agreementKey)
        directory[origin] = PeerInfo(
            peerID: origin, identity: identity, nickname: payload.nickname,
            capabilities: payload.capabilities, lastSeen: now, hops: hops
        )
        if isNew { enforcePeerLimit(now: now) }
        let routeChanged = routing.offer(origin, link: link, hops: hops, now: now)
        lastAnnounceByPeer[origin] = packet

        if isNew || routeChanged {
            routeAppeared(for: origin, now: now)
            delegate?.meshNodeDidUpdatePeers(self)
        }
        relay(packet, from: link, now: now)
    }

    private func handleMessage(_ packet: Packet, from link: LinkID, now: Date) {
        if packet.destination == peerID {
            guard packet.flags.contains(.directEncrypted),
                  let plaintext = try? MeshCrypto.openDirect(packet.payload, with: identity.agreementKey,
                                                              from: packet.originSigningKey),
                  let envelope = try? MessageEnvelope.decode(plaintext) else {
                stats.invalidDropped += 1
                return
            }
            // Always acknowledge (also for retransmissions, so the sender stops retrying).
            sendAck(.delivered, messageID: envelope.messageID, ackedPacketID: packet.packetID, to: packet.origin, now: now)
            deliverOnce(envelope, from: packet, scope: .direct, now: now) {
                self.applyControl(envelope, from: packet.origin, sentAt: packet.timestamp)
            }
            return
        }

        if packet.isBroadcast {
            if packet.flags.contains(.groupEncrypted) {
                if let groupID = MeshCrypto.groupID(ofSealed: packet.payload),
                   let group = groups[groupID],
                   group.members.contains(packet.origin),
                   let plaintext = try? MeshCrypto.openGroup(packet.payload, key: group.key, from: packet.originSigningKey),
                   let envelope = try? MessageEnvelope.decode(plaintext),
                   envelope.groupID == groupID,
                   envelope.content.isAllowedInSharedChannels {
                    deliverOnce(envelope, from: packet, scope: .group(groupID), now: now)
                }
            } else if let envelope = try? MessageEnvelope.decode(packet.payload),
                      envelope.groupID == nil,
                      envelope.content.isAllowedInSharedChannels {
                deliverOnce(envelope, from: packet, scope: .broadcast, now: now)
            }
            relay(packet, from: link, now: now)
            return
        }

        // Directed to someone else.
        relay(packet, from: link, now: now)
        if routing.route(to: packet.destination, now: now) == nil {
            store(packet, now: now)
        }
    }

    private func handleAck(_ packet: Packet, from link: LinkID, now: Date) {
        guard !packet.isBroadcast, let ack = try? AckPayload.decode(packet.payload) else {
            stats.invalidDropped += 1
            return
        }
        // A carrier drops its copy only when the real recipient acknowledges it to the real sender.
        if let carried = carry[ack.ackedPacketID]?.packet,
           carried.destination == packet.origin, carried.origin == packet.destination {
            carry[ack.ackedPacketID] = nil
        }

        guard packet.destination == peerID else {
            relay(packet, from: link, now: now)
            // Acks travel back through partitions the same way messages do.
            if routing.route(to: packet.destination, now: now) == nil { store(packet, now: now) }
            return
        }
        guard var message = outgoing[ack.messageID], message.destination == packet.origin else { return }
        let newStatus: DeliveryStatus = ack.kind == .read ? .read : .delivered
        guard message.status < newStatus || message.status == .failed else { return }
        message.status = newStatus
        outgoing[ack.messageID] = message
        delegate?.meshNode(self, didUpdateDelivery: ack.messageID, status: newStatus)
    }

    /// Apply group control messages. Returns false when the message must not reach the app
    /// (e.g. a rejected invite), so spoofed "X added you" notices never appear.
    private func applyControl(_ envelope: MessageEnvelope, from sender: PeerID, sentAt: Date) -> Bool {
        switch envelope.content {
        case .groupInvite(let invite):
            guard invite.key.count == 32, invite.members.contains(peerID), invite.members.contains(sender) else { return false }
            if let leftAt = leftGroups[invite.groupID], sentAt <= leftAt { return false }
            if let existing = groups[invite.groupID] {
                // Only the creator may change an existing group (re-key / membership).
                guard existing.creator == sender else { return false }
            }
            groups[invite.groupID] = GroupInfo(id: invite.groupID, name: invite.name, members: Set(invite.members),
                                               key: invite.key, creator: sender)
            leftGroups[invite.groupID] = nil
            return true
        case .groupLeave(let groupID):
            guard groups[groupID]?.members.contains(sender) == true else { return false }
            groups[groupID]?.members.remove(sender)
            return true
        default:
            return true
        }
    }

    /// Deliver an envelope once per (origin, messageID). `prepare` runs first (exactly once)
    /// and may veto delivery.
    private func deliverOnce(_ envelope: MessageEnvelope, from packet: Packet, scope: MessageScope, now: Date,
                             prepare: () -> Bool = { true }) {
        guard deliveredMessages.insert("\(packet.origin.hex):\(envelope.messageID.uuidString)", now: now) else { return }
        guard prepare() else { return }
        stats.messagesDelivered += 1
        delegate?.meshNode(self, didReceive: ReceivedMessage(
            envelope: envelope, sender: packet.origin, scope: scope, hops: Int(packet.hops), receivedAt: now
        ))
    }

    // MARK: - Outbound

    /// A route to `destination` (re)appeared: retry its pending messages and hand over carried packets.
    private func routeAppeared(for destination: PeerID, now: Date) {
        for id in outgoing.keys {
            guard let message = outgoing[id], message.destination == destination, message.status < .delivered else { continue }
            let spacingOK = message.lastAttemptAt.map { now.timeIntervalSince($0) >= config.minRetrySpacing } ?? true
            if spacingOK && message.nextAttemptAt > now { outgoing[id]!.nextAttemptAt = now }
        }
        processOutgoing(now: now)
        if let route = routing.route(to: destination, now: now) {
            for (_, entry) in carry where entry.packet.destination == destination {
                forward(entry.packet, on: [route.link])
            }
        }
    }

    private func processOutgoing(now: Date) {
        for id in Array(outgoing.keys) {
            guard let message = outgoing[id], message.status < .delivered, message.nextAttemptAt <= now else { continue }
            attemptDelivery(id, now: now)
        }
    }

    private func attemptDelivery(_ id: UUID, now: Date) {
        guard var message = outgoing[id], message.status < .delivered else { return }

        if now.timeIntervalSince(message.createdAt) > config.outboxLifetime || message.attempts >= config.maxDeliveryAttempts {
            fail(id)
            return
        }
        guard let recipient = directory[message.destination], !links.isEmpty else {
            // Wait for the recipient's announce or for any link; re-checked on those events.
            message.nextAttemptAt = now.addingTimeInterval(config.retrySchedule.first ?? 5)
            outgoing[id] = message
            return
        }
        guard let sealed = try? MeshCrypto.sealDirect(message.envelope, to: recipient.identity.agreementKey,
                                                     from: identity.publicIdentity.signingKey),
              let packet = try? Packet.make(type: .message, flags: .directEncrypted, ttl: config.messageTTL,
                                            destination: message.destination, payload: sealed,
                                            identity: identity, now: now) else {
            fail(id)
            return
        }
        message.attempts += 1
        message.lastAttemptAt = now
        message.packetIDs.append(packet.packetID)
        if message.packetIDs.count > 16 { message.packetIDs.removeFirst() }
        let delay = config.retrySchedule[min(message.attempts - 1, config.retrySchedule.count - 1)]
        message.nextAttemptAt = now.addingTimeInterval(delay)
        let wasQueued = message.status == .queued
        message.status = .sent
        outgoing[id] = message
        originate(packet)
        if wasQueued { delegate?.meshNode(self, didUpdateDelivery: id, status: .sent) }
    }

    private func fail(_ id: UUID) {
        guard var message = outgoing[id], message.status != .failed else { return }
        message.status = .failed
        outgoing[id] = message
        delegate?.meshNode(self, didUpdateDelivery: id, status: .failed)
    }

    private func sendAck(_ kind: AckKind, messageID: UUID, ackedPacketID: UUID, to destination: PeerID, now: Date) {
        guard !destination.isBroadcast else { return }
        let payload = AckPayload(kind: kind, messageID: messageID, ackedPacketID: ackedPacketID)
        guard let packet = try? Packet.make(type: .ack, ttl: config.messageTTL, destination: destination,
                                            payload: payload.encode(), identity: identity, now: now) else { return }
        originate(packet)
    }

    private func sendHello(nonce: Data, echo: Data, on link: LinkID, now: Date) {
        guard let packet = try? Packet.make(type: .hello, ttl: 1, destination: .broadcast,
                                            payload: HelloPayload(nonce: nonce, echoedNonce: echo).encode(),
                                            identity: identity, now: now) else { return }
        seenPackets.insert(packet.packetID, now: now)
        send(packet, on: [link])
    }

    /// Send a packet we created.
    private func originate(_ packet: Packet) {
        seenPackets.insert(packet.packetID, now: clock())
        route(packet, excluding: nil)
    }

    /// Forward someone else's packet (ttl/hops adjusted), subject to rate limits.
    private func relay(_ packet: Packet, from link: LinkID, now: Date) {
        guard packet.ttl > 1 else { return }
        // Old (carried or replayed) traffic draws on a separate budget so it can't starve live traffic.
        let isStale = now.timeIntervalSince(packet.timestamp) > config.staleThreshold
        let allowed = isStale ? staleLimiter.allow(packet.origin, now: now) : freshLimiter.allow(packet.origin, now: now)
        guard allowed else {
            stats.rateLimited += 1
            return
        }
        var copy = packet
        copy.ttl -= 1
        copy.hops = copy.hops &+ 1
        stats.relayed += 1
        route(copy, excluding: link)
    }

    /// Directed packets follow the routing table when possible; everything else floods.
    private func route(_ packet: Packet, excluding ingress: LinkID?) {
        let now = clock()
        if !packet.isBroadcast, let route = routing.route(to: packet.destination, now: now), route.link != ingress {
            send(packet, on: [route.link])
        } else {
            send(packet, on: links.filter { $0 != ingress })
        }
    }

    /// Re-send a stored packet (announce/carry) to specific links as a relay hop.
    private func forward(_ packet: Packet, on targets: [LinkID]) {
        guard packet.ttl > 1 else { return }
        var copy = packet
        copy.ttl -= 1
        copy.hops = copy.hops &+ 1
        send(copy, on: Set(targets))
    }

    private func send(_ packet: Packet, on targets: Set<LinkID>) {
        guard let transport, !targets.isEmpty else { return }
        let bytes = packet.encode()
        for link in targets {
            let frames = Framing.frames(for: bytes, maxFrameSize: transport.maximumFrameSize(for: link))
            if transport.send(frames: frames, over: link) { stats.packetsSent += 1 }
        }
    }

    private func store(_ packet: Packet, now: Date) {
        guard packet.ttl > 1, !packet.isBroadcast, carry[packet.packetID] == nil else { return }
        purgeCarry(now: now)
        // Per-origin cap so one sender can't monopolise every carrier's storage.
        let fromOrigin = carry.filter { $0.value.packet.origin == packet.origin }
        if fromOrigin.count >= config.carryPerOriginCapacity,
           let oldest = fromOrigin.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            carry[oldest] = nil
        }
        if carry.count >= config.carryCapacity,
           let oldest = carry.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            carry[oldest] = nil
        }
        // Stored as received; `forward` applies the relay hop when it is handed to a new link.
        carry[packet.packetID] = (packet, now)
        stats.carried += 1
    }

    private func purgeCarry(now: Date) {
        carry = carry.filter { now.timeIntervalSince($0.value.storedAt) < config.carryLifetime }
    }

    // MARK: - Housekeeping (bounded memory)

    private func housekeeping(now: Date) {
        // Finished outbox entries are kept a while for late read receipts, then dropped.
        outgoing = outgoing.filter { _, message in
            let age = now.timeIntervalSince(message.createdAt)
            switch message.status {
            case .delivered, .read: return age < config.finishedRetention
            case .failed: return age < config.outboxLifetime + config.finishedRetention
            default: return true
            }
        }
        if outgoing.count > config.maxOutboxEntries {
            let finished = outgoing.values.filter { $0.status >= .delivered }.sorted { $0.createdAt < $1.createdAt }
            for message in finished.prefix(outgoing.count - config.maxOutboxEntries) { outgoing[message.messageID] = nil }
        }
        // Forget peers not seen for a long time (unless still routable).
        directory = directory.filter { id, info in
            now.timeIntervalSince(info.lastSeen) < config.peerRetention || routing.route(to: id, now: now) != nil
        }
        leftGroups = leftGroups.filter { now.timeIntervalSince($0.value) < config.peerRetention }
    }

    private func enforcePeerLimit(now: Date) {
        guard directory.count > config.maxKnownPeers else { return }
        let evictable = directory.values
            .filter { routing.route(to: $0.peerID, now: now) == nil }
            .sorted { $0.lastSeen < $1.lastSeen }
        for info in evictable.prefix(directory.count - config.maxKnownPeers) { directory[info.peerID] = nil }
    }

    private static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }
}

public enum MeshNodeError: Error {
    case unknownGroup
}

extension MeshContent {
    /// Content that may appear on public/group channels. Control and AI traffic is
    /// direct-only, so it can't be spoofed by broadcasting it.
    var isAllowedInSharedChannels: Bool {
        switch self {
        case .text, .voice, .sos: return true
        case .groupInvite, .groupLeave, .aiQuery, .aiResponse: return false
        }
    }
}
