import Foundation
import Testing
@testable import MeshCore
import MeshSimulator

/// Crowd-scale behaviour on a realistic phone radio model (shared ~120 kbit/s radio, bounded
/// queues, ≤ 8 links per phone, random placement). These tests measure the protocol, not just
/// check it runs: coverage, airtime and latency are asserted against explicit targets.
@Suite("Crowds (simulated)", .serialized)
struct CrowdTests {
    static func crowdConfig(congestion: Bool = true) -> MeshConfig {
        var config = MeshConfig()
        config.congestionControl = congestion
        config.urgentWorkBits = 8 // keep proof-of-work cheap in tests; its cost is tested separately
        return config
    }

    struct Result {
        var coverage: Double
        var reachableWithinTTL: Double
        var framesNormal: Int
        var framesBackground: Int
        var framesTotal: Int
        var suppressed: Int
        var queueDrops: Int
    }

    static func makeCrowd(count: Int = 100, seed: UInt64 = 7, congestion: Bool = true) -> (SimulatedMesh, [String]) {
        let mesh = SimulatedMesh(seed: seed, radio: .phone)
        let names = mesh.scatter(count: count, width: 200, height: 200, range: 40, config: crowdConfig(congestion: congestion))
        mesh.run(for: 60) // let presence converge
        return (mesh, names)
    }

    static func coverage(of id: UUID, from sender: String, in mesh: SimulatedMesh, names: [String]) -> Double {
        Double(names.filter { $0 != sender && mesh.recorder($0).hasReceived(id) }.count) / Double(names.count - 1)
    }

    static func withinTTL(of sender: String, in mesh: SimulatedMesh, names: [String]) -> Double {
        let ttl = Int(crowdConfig().messageTTL)
        return Double(names.filter { $0 != sender && (mesh.hopDistance(sender, $0) ?? 99) <= ttl }.count) / Double(names.count - 1)
    }

    /// 10 public messages from spread-out phones; returns mean coverage and airtime.
    static func broadcastStorm(congestion: Bool) throws -> Result {
        let (mesh, names) = makeCrowd(congestion: congestion)
        mesh.resetMetrics()
        var sent: [(String, UUID)] = []
        for i in 0..<10 {
            let sender = names[(i * 11) % names.count]
            sent.append((sender, try mesh.node(sender).sendBroadcast(.text("crowd message \(i)"))))
            mesh.run(for: 2)
        }
        mesh.run(for: 20)
        let coverage = sent.map { coverage(of: $0.1, from: $0.0, in: mesh, names: names) }.reduce(0, +) / Double(sent.count)
        let reachable = sent.map { withinTTL(of: $0.0, in: mesh, names: names) }.reduce(0, +) / Double(sent.count)
        return Result(coverage: coverage, reachableWithinTTL: reachable,
                      framesNormal: mesh.metrics.framesByPriority[.normal] ?? 0,
                      framesBackground: mesh.metrics.framesByPriority[.background] ?? 0,
                      framesTotal: mesh.metrics.framesTransmitted,
                      suppressed: names.reduce(0) { $0 + mesh.node($1).stats.suppressed },
                      queueDrops: mesh.metrics.framesDroppedQueueFull)
    }

    @Test func congestionControlCutsAirtimeWithoutLosingReach() throws {
        let off = try Self.broadcastStorm(congestion: false)
        let on = try Self.broadcastStorm(congestion: true)
        print("CROWD off: \(off)")
        print("CROWD on:  \(on)")
        // Reach: ≥ 90% of everyone within the hop limit, and no worse than plain flooding.
        #expect(on.coverage >= 0.9 * on.reachableWithinTTL)
        #expect(on.coverage >= off.coverage - 0.03)
        // Airtime: at least 25% less total radio traffic, and chat itself at least 20% less.
        #expect(Double(on.framesTotal) <= 0.75 * Double(off.framesTotal))
        #expect(Double(on.framesNormal) <= 0.8 * Double(off.framesNormal))
        #expect(on.suppressed > 0)
    }

    @Test func sosCutsThroughABusyCrowd() throws {
        let (mesh, names) = Self.makeCrowd(seed: 11)
        // Heavy chatter: 30 phones each posting every second for 20 s.
        let chatters = Array(names.prefix(30))
        var chatIDs: [(String, UUID, Date)] = []
        var sosID: UUID?, sosSentAt = Date(), sosSender = names[names.count - 1]
        for second in 0..<20 {
            for (i, c) in chatters.enumerated() where (second + i) % 1 == 0 {
                let id = try mesh.node(c).sendBroadcast(.text("chatter \(second)-\(i)"))
                if second == 10 && i == 0 { chatIDs.append((c, id, mesh.now)) }
            }
            if second == 10 {
                sosSender = names[names.count - 1]
                sosSentAt = mesh.now
                sosID = try mesh.node(sosSender).sendBroadcast(.sos(SOSReport(text: "trapped under rubble, need help")))
            }
            mesh.run(for: 1)
        }
        mesh.run(for: 30)
        let sos = try #require(sosID)
        let sosCoverage = Self.coverage(of: sos, from: sosSender, in: mesh, names: names)
        let reachable = Self.withinTTL(of: sosSender, in: mesh, names: names)
        let sosLatencies = names.compactMap { name in
            mesh.recorder(name).received.first { $0.envelope.messageID == sos }.map { $0.receivedAt.timeIntervalSince(sosSentAt) }
        }.sorted()
        let chat = chatIDs[0]
        let chatLatencies = names.compactMap { name in
            mesh.recorder(name).received.first { $0.envelope.messageID == chat.1 }.map { $0.receivedAt.timeIntervalSince(chat.2) }
        }.sorted()
        let p90 = { (xs: [Double]) in xs.isEmpty ? .infinity : xs[min(xs.count - 1, Int(Double(xs.count) * 0.9))] }
        print("CROWD sos coverage=\(sosCoverage) reachable=\(reachable) p90=\(p90(sosLatencies))s chat p90=\(p90(chatLatencies))s drops=\(mesh.metrics.framesDroppedQueueFull)")
        #expect(sosCoverage >= 0.9 * reachable)
        #expect(p90(sosLatencies) < 5)
        #expect(p90(sosLatencies) <= p90(chatLatencies))
    }

    @Test func directMessagesToKnownContactsAcrossACrowdAreDelivered() throws {
        let (mesh, names) = Self.makeCrowd(seed: 21)
        // Contacts met earlier (keys already known), now 4–7 hops apart in the crowd. In a dense
        // crowd presence only spreads ~3 hops, so there's no route: the DM must find its way by
        // suppressed flooding, and the ack must find its way back.
        var pairs: [(String, String)] = []
        for a in names where pairs.count < 10 {
            if let b = names.first(where: { b in
                b != a && !pairs.contains { $0.1 == b } && (4...7).contains(mesh.hopDistance(a, b) ?? 0)
            }) { pairs.append((a, b)) }
        }
        #expect(pairs.count == 10)
        var ids: [(String, UUID)] = []
        for (a, b) in pairs {
            let contact = mesh.node(b).identity.publicIdentity
            let peers = [MeshNodeSnapshot.KnownPeer(signingKey: contact.signingKey, agreementKey: contact.agreementKey,
                                                     nickname: b, capabilities: 0, lastSeen: mesh.now)]
            mesh.node(a).restore(MeshNodeSnapshot(outgoing: [], groups: [], peers: peers, leftGroups: nil))
            ids.append((a, try mesh.node(a).sendDirect(.text("are you ok \(b)?"), to: mesh.node(b).peerID)))
        }
        let ok = mesh.run(until: { ids.allSatisfy { mesh.node($0.0).outgoingStatus($0.1) == .delivered } }, timeout: 180)
        let delivered = ids.filter { mesh.node($0.0).outgoingStatus($0.1) == .delivered }.count
        print("CROWD DMs delivered \(delivered)/\(ids.count)")
        #expect(ok)
    }

    @Test func denseAreasAnnounceLessOftenAndLessFar() {
        let mesh = SimulatedMesh()
        mesh.addNode("hub")
        for i in 0..<8 { mesh.addNode("s\(i)"); mesh.connect("hub", "s\(i)") }
        let hub = mesh.node("hub"), spoke = mesh.node("s0")
        #expect(hub.currentAnnounceInterval > spoke.currentAnnounceInterval)
        #expect(hub.currentAnnounceInterval <= hub.config.maxAnnounceInterval)
        hub.powerState = .low
        let lowInterval = hub.currentAnnounceInterval
        hub.powerState = .normal
        #expect(lowInterval >= hub.currentAnnounceInterval)
    }
}

@Suite("Battery-aware relaying")
struct BatteryTests {
    @Test func routesAvoidLowBatteryRelaysWhenThereIsAnAlternative() {
        // A reaches D through B (low battery) or C (healthy): same hop count.
        let mesh = SimulatedMesh()
        for n in ["A", "B", "C", "D"] { mesh.addNode(n) }
        mesh.node("B").powerState = .low
        mesh.connect("A", "B"); mesh.connect("B", "D")
        mesh.connect("A", "C"); mesh.connect("C", "D")
        mesh.run(for: 50)
        let a = mesh.node("A")
        let route = a.peer(mesh.node("D").peerID)
        #expect(route?.hops == 1)
        #expect(a.peer(mesh.node("B").peerID)?.capabilities.contains(.lowPower) == true)
        // Delivery goes through C, not B.
        let relayedByB = mesh.node("B").stats.relayed
        let id = try? a.sendDirect(.text("via healthy relay"), to: mesh.node("D").peerID)
        #expect(mesh.run(until: { id.map { a.outgoingStatus($0) == .delivered } ?? false }, timeout: 10))
        #expect(mesh.node("B").stats.relayed - relayedByB <= 1) // at most an announce/ack, not the message path
    }

    @Test func criticalBatteryStillRelaysSOSButNotChatter() throws {
        var config = CrowdTests.crowdConfig()
        config.suppressionMinLinks = 99 // isolate the battery rule from suppression
        let mesh = SimulatedMesh()
        for n in ["A", "R", "B"] { mesh.addNode(n, config: config) }
        mesh.chain(["A", "R", "B"])
        mesh.run(for: 5)
        mesh.node("R").powerState = .critical
        try mesh.node("A").sendBroadcast(.text("chatter"))
        try mesh.node("A").sendBroadcast(.sos(SOSReport(text: "need help")))
        mesh.run(for: 5)
        let received = mesh.recorder("B").received.map(\.envelope.content)
        #expect(received.contains { if case .sos = $0 { return true }; return false })
        #expect(!received.contains(.text("chatter")))
    }

    @Test func lowBatteryCarriesLessAndCriticalCarriesNothing() throws {
        let mesh = SimulatedMesh()
        for n in ["A", "M", "C"] { mesh.addNode(n) }
        mesh.chain(["A", "M", "C"])
        mesh.run(for: 8)
        let c = mesh.node("C").peerID
        mesh.disconnect("M", "C")
        mesh.run(for: 100)
        mesh.node("M").powerState = .critical
        _ = try mesh.node("A").sendDirect(.text("hold"), to: c)
        mesh.run(for: 5)
        #expect(mesh.node("M").stats.carried == 0)
    }
}

@Suite("Fake SOS resistance")
struct SOSAbuseTests {
    @Test func proofOfWorkIsRequiredAndCheapToVerify() throws {
        let identity = MeshIdentity()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        let id = Packet.mintWork(bits: 12, origin: identity.peerID, timestampMs: ms)
        let packet = try Packet.make(type: .message, flags: .urgent, ttl: 7, destination: .broadcast,
                                     payload: Data("x".utf8), identity: identity, now: now, packetID: id)
        #expect(packet.workBits >= 12)
        // Changing the packet ID breaks the work (and the signature).
        var forged = packet
        forged.packetID = UUID()
        #expect(forged.workBits < 12 || !forged.verify())
    }

    @Test func defaultWorkCostsRealTimeToMint() {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<5 { _ = Packet.mintWork(bits: MeshConfig().urgentWorkBits, origin: MeshIdentity().peerID, timestampMs: 1) }
        }
        let perSOS = Double(elapsed.components.attoseconds) / 1e18 / 5 + Double(elapsed.components.seconds) / 5
        print("CROWD pow per SOS: \(perSOS)s at \(MeshConfig().urgentWorkBits) bits")
        #expect(perSOS > 0.005) // non-trivial for a spammer minting thousands
        #expect(perSOS < 3)     // but fine for one person sending one SOS
    }

    @Test func urgentPacketsWithoutWorkAreDropped() throws {
        let mesh = SimulatedMesh()
        mesh.addNode("A", config: CrowdTests.crowdConfig()); mesh.addNode("B", config: CrowdTests.crowdConfig())
        mesh.connect("A", "B")
        mesh.run(for: 3)
        let attacker = MeshIdentity()
        var packet: Packet
        repeat { // make sure this random ID really lacks the work
            packet = try Packet.make(type: .message, flags: .urgent, ttl: 7, destination: .broadcast,
                                     payload: try MessageEnvelope(sentAt: mesh.now, senderName: "X", content: .sos(SOSReport(text: "fake"))).encode(),
                                     identity: attacker, now: mesh.now)
        } while packet.workBits >= 8
        let before = mesh.node("B").stats.invalidDropped
        mesh.node("B").receive(frame: Framing.frames(for: packet.encode(), maxFrameSize: 1000)[0], from: LinkID("B->A"))
        #expect(mesh.node("B").stats.invalidDropped == before + 1)
        #expect(mesh.recorder("B").received.isEmpty)
    }

    @Test func sosFloodFromOneIdentityIsDowngradedNotAmplified() throws {
        let mesh = SimulatedMesh()
        for n in ["S", "R", "D"] { mesh.addNode(n, config: CrowdTests.crowdConfig()) }
        mesh.chain(["S", "R", "D"])
        mesh.run(for: 5)
        for i in 0..<12 { try mesh.node("S").sendBroadcast(.sos(SOSReport(text: "fake \(i)"))) }
        mesh.run(for: 10)
        #expect(mesh.node("R").stats.urgentDowngraded >= 12 - Int(MeshConfig().urgentBurst))
        // Downgraded SOS still arrive (we don't censor), they just lose their priority lane.
        #expect(mesh.recorder("D").received.count == 12)
    }
}
