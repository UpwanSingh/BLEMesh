import Foundation
import Testing
@testable import MeshCore
import MeshSimulator

/// End-to-end behaviour of many nodes over the simulated network.
@Suite("Mesh network (simulated)")
struct MeshNetworkTests {

    /// Build a converged chain and return the mesh.
    func chain(_ names: [String], mtu: Int = 182, settle: TimeInterval = 5) -> SimulatedMesh {
        let mesh = SimulatedMesh()
        for name in names { mesh.addNode(name) }
        mesh.chain(names, profile: .init(mtu: mtu))
        mesh.run(for: settle)
        return mesh
    }

    @Test func neighborsDiscoverEachOtherByMeshID() {
        let mesh = chain(["A", "B"])
        let a = mesh.node("A"), b = mesh.node("B")
        let seenByA = a.peer(b.peerID)
        #expect(seenByA?.nickname == "B")
        #expect(seenByA?.hops == 0)
        #expect(seenByA?.identity == b.identity.publicIdentity)
        #expect(b.peer(a.peerID)?.isNeighbor == true)
    }

    @Test func directMessageToNeighborIsDeliveredAndAcknowledged() throws {
        let mesh = chain(["A", "B"])
        let id = try mesh.node("A").sendDirect(.text("hello B"), to: mesh.node("B").peerID)
        #expect(mesh.run(until: { mesh.recorder("A").latestStatus(id) == .delivered }, timeout: 5))
        let received = try #require(mesh.recorder("B").received.first)
        #expect(received.envelope.content == .text("hello B"))
        #expect(received.envelope.messageID == id)
        #expect(received.scope == .direct)
        #expect(received.sender == mesh.node("A").peerID)
        #expect(received.hops == 0)
        #expect(mesh.node("A").outgoingStatus(id) == .delivered)
    }

    @Test func multiHopDirectMessageIsEndToEndEncrypted() throws {
        let mesh = chain(["A", "B", "C", "D", "E"], settle: 10)
        let a = mesh.node("A"), e = mesh.node("E")
        #expect(a.peer(e.peerID)?.hops == 3)

        let id = try a.sendDirect(.text("secret for E"), to: e.peerID)
        #expect(mesh.run(until: { mesh.recorder("A").latestStatus(id) == .delivered }, timeout: 10))
        #expect(mesh.recorder("E").texts() == ["secret for E"])
        #expect(mesh.recorder("E").received.first?.hops == 3)
        // Relays carried it but could not read it.
        for relay in ["B", "C", "D"] { #expect(mesh.recorder(relay).received.isEmpty) }
        #expect(mesh.node("C").stats.relayed > 0)
    }

    @Test func broadcastReachesEveryoneExactlyOnceInACyclicMesh() throws {
        let mesh = SimulatedMesh()
        let names = ["A", "B", "C", "D", "E", "F"]
        for n in names { mesh.addNode(n) }
        // Ring plus chords: lots of redundant paths.
        mesh.chain(names)
        mesh.connect("F", "A")
        mesh.connect("A", "C")
        mesh.connect("B", "E")
        mesh.run(for: 5)

        try mesh.node("A").sendBroadcast(.text("hello everyone"))
        mesh.run(for: 5)
        for n in names.dropFirst() {
            #expect(mesh.recorder(n).texts() == ["hello everyone"], "node \(n)")
            #expect(mesh.recorder(n).received.first?.scope == .broadcast)
        }
        #expect(mesh.recorder("A").received.isEmpty)
        let duplicates = names.map { mesh.node($0).stats.duplicatesDropped }.reduce(0, +)
        #expect(duplicates > 0) // redundancy was suppressed, not delivered
    }

    @Test func ttlLimitsHowFarABroadcastTravels() throws {
        var config = MeshConfig()
        config.messageTTL = 3
        config.announceTTL = 3
        let mesh = SimulatedMesh()
        let names = ["A", "B", "C", "D", "E", "F"]
        for n in names { mesh.addNode(n, config: config) }
        mesh.chain(names)
        mesh.run(for: 5)
        try mesh.node("A").sendBroadcast(.text("short range"))
        mesh.run(for: 5)
        #expect(mesh.recorder("B").texts().count == 1)
        #expect(mesh.recorder("C").texts().count == 1)
        #expect(mesh.recorder("D").texts().count == 1)
        #expect(mesh.recorder("E").texts().isEmpty)
        #expect(mesh.recorder("F").texts().isEmpty)
    }

    @Test func tinyMTUFragmentsLongMessages() throws {
        let mesh = chain(["A", "B", "C"], mtu: 40, settle: 8)
        let long = String(repeating: "mesh networking over bluetooth ", count: 80) // ~2.5 KB
        let id = try mesh.node("A").sendDirect(.text(long), to: mesh.node("C").peerID)
        #expect(mesh.run(until: { mesh.recorder("A").latestStatus(id) == .delivered }, timeout: 20))
        #expect(mesh.recorder("C").texts() == [long])
    }

    @Test func lossyLinksStillDeliverThroughRetries() throws {
        let mesh = SimulatedMesh(seed: 7)
        for n in ["A", "B", "C"] { mesh.addNode(n) }
        // 10% frame loss on every link (BLE writes are normally link-layer reliable; this
        // models interference / dropped notifications). Each DM is 2 fragments per hop.
        mesh.chain(["A", "B", "C"], profile: .init(mtu: 182, lossRate: 0.10))
        mesh.run(for: 30)
        let a = mesh.node("A"), c = mesh.node("C")
        #expect(a.peer(c.peerID) != nil)
        var ids: [UUID] = []
        for i in 0..<5 { ids.append(try a.sendDirect(.text("msg \(i)"), to: c.peerID)) }
        let ok = mesh.run(until: { ids.allSatisfy { mesh.recorder("A").latestStatus($0) == .delivered } }, timeout: 600)
        #expect(ok)
        // Each message shown once despite retransmissions.
        #expect(Set(mesh.recorder("C").texts()).count == 5)
        #expect(mesh.recorder("C").texts().count == 5)
    }

    @Test func storeAndForwardDeliversThroughADataMule() throws {
        // A and C are never connected at the same time; M physically carries the message.
        let mesh = chain(["A", "M", "C"], settle: 8) // learn keys first
        let a = mesh.node("A"), c = mesh.node("C")
        mesh.disconnect("M", "C")
        mesh.run(for: 100) // routes to C expire

        let id = try a.sendDirect(.text("carried"), to: c.peerID)
        mesh.run(for: 5)
        #expect(mesh.recorder("C").received.isEmpty)
        #expect(mesh.node("M").stats.carried > 0)

        mesh.disconnect("A", "M")
        mesh.run(for: 2)
        mesh.connect("M", "C")
        #expect(mesh.run(until: { mesh.recorder("C").texts() == ["carried"] }, timeout: 10))

        // The ack is carried back the same way.
        mesh.disconnect("M", "C")
        mesh.run(for: 2)
        mesh.connect("A", "M")
        #expect(mesh.run(until: { mesh.recorder("A").latestStatus(id) == .delivered }, timeout: 30))
    }

    @Test func messagesQueueWhileOfflineAndFlushOnReconnect() throws {
        let mesh = chain(["A", "B"])
        mesh.disconnect("A", "B")
        mesh.run(for: 100)
        let id = try mesh.node("A").sendDirect(.text("later"), to: mesh.node("B").peerID)
        mesh.run(for: 30)
        #expect(mesh.node("A").outgoingStatus(id) == .sent || mesh.node("A").outgoingStatus(id) == .queued)
        #expect(mesh.recorder("B").received.isEmpty)
        mesh.connect("A", "B")
        #expect(mesh.run(until: { mesh.recorder("A").latestStatus(id) == .delivered }, timeout: 10))
    }

    @Test func undeliverableMessagesEventuallyFailAndCanBeRetried() throws {
        var config = MeshConfig()
        config.retrySchedule = [1, 1, 1]
        config.maxDeliveryAttempts = 3
        let mesh = SimulatedMesh()
        mesh.addNode("A", config: config); mesh.addNode("B", config: config); mesh.addNode("X", config: config)
        mesh.chain(["A", "B", "X"])
        mesh.run(for: 5)
        let x = mesh.node("X").peerID
        mesh.disconnect("B", "X")
        mesh.run(for: 2)
        let id = try mesh.node("A").sendDirect(.text("into the void"), to: x)
        #expect(mesh.run(until: { mesh.recorder("A").latestStatus(id) == .failed }, timeout: 30))
        mesh.connect("B", "X")
        mesh.run(for: 3)
        mesh.node("A").retry(id)
        #expect(mesh.run(until: { mesh.recorder("A").latestStatus(id) == .delivered }, timeout: 15))
    }

    @Test func readReceiptsReachTheSender() throws {
        let mesh = chain(["A", "B", "C"], settle: 6)
        let a = mesh.node("A"), c = mesh.node("C")
        let id = try a.sendDirect(.text("did you see this?"), to: c.peerID)
        #expect(mesh.run(until: { mesh.recorder("A").latestStatus(id) == .delivered }, timeout: 5))
        c.sendReadReceipt(for: id, to: a.peerID)
        #expect(mesh.run(until: { mesh.recorder("A").latestStatus(id) == .read }, timeout: 5))
        // A late duplicate "delivered" must not downgrade read.
        #expect(a.outgoingStatus(id) == .read)
    }

    @Test func groupsAreEncryptedAndMembershipIsShared() throws {
        let mesh = chain(["A", "B", "C", "D"], settle: 8)
        let a = mesh.node("A"), b = mesh.node("B"), c = mesh.node("C"), d = mesh.node("D")
        let group = try a.createGroup(name: "Rescue team", members: [b.peerID, d.peerID])
        #expect(mesh.run(until: { b.groups[group.id] != nil && d.groups[group.id] != nil }, timeout: 10))
        #expect(c.groups[group.id] == nil)
        #expect(b.groups[group.id]?.members == [a.peerID, b.peerID, d.peerID])
        #expect(mesh.recorder("B").received.contains { if case .groupInvite = $0.envelope.content { return true }; return false })

        let msgID = try d.sendGroup(.text("north side clear"), groupID: group.id)
        mesh.run(for: 3)
        for member in ["A", "B"] {
            let got = mesh.recorder(member).received.first { $0.envelope.messageID == msgID }
            #expect(got?.scope == .group(group.id), "member \(member)")
            #expect(got?.envelope.content == .text("north side clear"))
        }
        // C relayed the ciphertext (it sits between B and D) but could not read it.
        #expect(!mesh.recorder("C").received.contains { $0.envelope.messageID == msgID })

        b.leaveGroup(group.id)
        #expect(mesh.run(until: { a.groups[group.id]?.members.contains(b.peerID) == false }, timeout: 10))
        #expect(b.groups[group.id] == nil)
        #expect(throws: MeshNodeError.unknownGroup) { try b.sendGroup(.text("x"), groupID: group.id) }
    }

    @Test func forgedAndReplayedPacketsAreDropped() throws {
        let mesh = chain(["A", "B"])
        let b = mesh.node("B")
        let mallory = MeshIdentity()
        var forged = try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                                     payload: try MessageEnvelope(sentAt: mesh.now, senderName: "A", content: .text("fake")).encode(),
                                     identity: mallory, now: mesh.now)
        forged.origin = mesh.node("A").peerID // impersonation attempt
        let before = b.stats.invalidDropped
        b.receive(frame: Framing.frames(for: forged.encode(), maxFrameSize: 500)[0], from: LinkID("B->A"))
        #expect(b.stats.invalidDropped == before + 1)
        #expect(mesh.recorder("B").received.isEmpty)

        // Replay of a legitimate packet is suppressed.
        let genuine = try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                                      payload: try MessageEnvelope(sentAt: mesh.now, senderName: "M", content: .text("once")).encode(),
                                      identity: mallory, now: mesh.now)
        let frame = Framing.frames(for: genuine.encode(), maxFrameSize: 500)[0]
        b.receive(frame: frame, from: LinkID("B->A"))
        b.receive(frame: frame, from: LinkID("B->A"))
        #expect(mesh.recorder("B").texts() == ["once"])

        // Stale timestamps are rejected.
        let ancient = try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                                      payload: try MessageEnvelope(sentAt: mesh.now, senderName: "M", content: .text("old")).encode(),
                                      identity: mallory, now: mesh.now.addingTimeInterval(-3 * 24 * 3600))
        b.receive(frame: Framing.frames(for: ancient.encode(), maxFrameSize: 500)[0], from: LinkID("B->A"))
        #expect(!mesh.recorder("B").texts().contains("old"))
    }

    @Test func floodingSenderIsRateLimitedByRelays() throws {
        let mesh = chain(["A", "B", "C"], settle: 5)
        for i in 0..<150 { try mesh.node("A").sendBroadcast(.text("spam \(i)")) }
        mesh.run(for: 5)
        #expect(mesh.node("B").stats.rateLimited > 0)
        #expect(mesh.recorder("B").texts().count == 150) // B itself still reads them
        #expect(mesh.recorder("C").texts().count < 150)   // but doesn't amplify them all
    }

    @Test func disconnectMakesPeersUnreachable() {
        let mesh = chain(["A", "B", "C"], settle: 6)
        let a = mesh.node("A")
        let c = mesh.node("C").peerID
        #expect(a.peer(c)?.hops == 1)
        mesh.disconnect("A", "B")
        #expect(a.peer(c)?.isReachable == false)
        #expect(a.peer(c)?.nickname == "C") // keys/nickname remembered for later
        #expect(a.reachablePeers.isEmpty)
    }

    @Test func askTheMeshFindsTheNearestAIHelper() throws {
        let mesh = SimulatedMesh()
        mesh.addNode("Old"); mesh.addNode("Relay"); mesh.addNode("Smart", capabilities: [.onDeviceAI])
        mesh.chain(["Old", "Relay", "Smart"])
        mesh.run(for: 6)
        let old = mesh.node("Old"), smart = mesh.node("Smart")
        let helper = try #require(old.bestAIHelper())
        #expect(helper.peerID == smart.peerID)

        // Simple helper loop: answer queries.
        mesh.recorder("Smart").onReceive = { message in
            if case .aiQuery(let q) = message.envelope.content {
                _ = try? smart.sendDirect(.aiResponse(AIResponse(queryID: q.queryID, text: "Cool the burn with running water for 20 minutes.", answeredBy: "Smart")), to: message.sender)
            }
        }
        let query = AIQuery(prompt: "How do I treat a burn?")
        try old.sendDirect(.aiQuery(query), to: helper.peerID)
        #expect(mesh.run(until: {
            mesh.recorder("Old").received.contains {
                if case .aiResponse(let r) = $0.envelope.content { return r.queryID == query.queryID }
                return false
            }
        }, timeout: 10))
    }

    @Test func snapshotRestoresOutboxGroupsAndPeers() throws {
        let mesh = chain(["A", "B"])
        let a = mesh.node("A"), b = mesh.node("B")
        let group = try a.createGroup(name: "G", members: [b.peerID])
        mesh.run(for: 3)
        mesh.disconnect("A", "B")
        let pending = try a.sendDirect(.text("survives restart"), to: b.peerID)
        let data = try JSONEncoder().encode(a.snapshot())

        // "Restart" A with the same identity.
        let restarted = MeshSimulatorRestart.restart(mesh: mesh, name: "A2", identity: a.identity)
        restarted.restore(try JSONDecoder().decode(MeshNodeSnapshot.self, from: data))
        #expect(restarted.groups[group.id]?.name == "G")
        #expect(restarted.peer(b.peerID)?.nickname == "B")
        #expect(restarted.outgoingStatus(pending) != nil)
        mesh.connect("A2", "B")
        #expect(mesh.run(until: { mesh.recorder("B").texts().contains("survives restart") }, timeout: 10))
    }
}

enum MeshSimulatorRestart {
    static func restart(mesh: SimulatedMesh, name: String, identity: MeshIdentity) -> MeshNode {
        mesh.addNode(name, identity: identity)
    }
}
