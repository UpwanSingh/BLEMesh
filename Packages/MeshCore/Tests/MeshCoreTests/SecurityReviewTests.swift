import Foundation
import Testing
@testable import MeshCore
import MeshSimulator

/// Regression tests for issues found in the security/correctness review.
/// Each asserts the desired behaviour; all failed before the fixes in MeshNode/MeshCrypto/Framing.
@Suite("Security review findings")
struct SecurityReviewTests {

    // MARK: - Harness

    /// Transport that records every frame a node sends.
    final class CaptureTransport: MeshTransport {
        var sent: [(link: LinkID, frames: [Data])] = []
        func send(frames: [Data], over link: LinkID, priority: TrafficPriority) -> Bool {
            sent.append((link, frames))
            return true
        }
        func maximumFrameSize(for link: LinkID) -> Int { 4096 }

        /// Decoded packets sent on `link` (whole frames only; frame size is large).
        func packets(on link: LinkID? = nil) -> [Packet] {
            sent.filter { link == nil || $0.link == link }.flatMap(\.frames).compactMap {
                guard $0.first == 0xA1 else { return nil }
                return try? Packet.decode($0.dropFirst())
            }
        }
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    final class Recorder: MeshNodeDelegate {
        var received: [ReceivedMessage] = []
        var statuses: [(UUID, DeliveryStatus)] = []
        func meshNode(_ node: MeshNode, didReceive message: ReceivedMessage) { received.append(message) }
        func meshNode(_ node: MeshNode, didUpdateDelivery messageID: UUID, status: DeliveryStatus) {
            statuses.append((messageID, status))
        }
    }

    struct Harness {
        let node: MeshNode
        let transport = CaptureTransport()
        let recorder = Recorder()
        init(_ name: String, clock: Clock, identity: MeshIdentity = MeshIdentity()) {
            node = MeshNode(identity: identity, nickname: name, clock: { clock.now })
            node.transport = transport
            node.delegate = recorder
        }
    }

    static func frame(_ packet: Packet) -> Data { Data([0xA1]) + packet.encode() }

    static func announce(_ identity: MeshIdentity, name: String, hops: UInt8 = 0, now: Date) throws -> Packet {
        let payload = AnnouncePayload(agreementKey: identity.publicIdentity.agreementKey, capabilities: [], nickname: name)
        var packet = try Packet.make(type: .announce, ttl: 5, destination: .broadcast,
                                     payload: payload.encode(), identity: identity, now: now)
        packet.hops = hops
        return packet
    }

    // MARK: - Group invites

    /// Any peer that knows a group's ID (it is sent in clear in every group ciphertext)
    /// can overwrite a member's key/roster for that group with a forged invite.
    @Test func forgedInviteCannotReplaceKeyOfExistingGroup() throws {
        let mesh = SimulatedMesh()
        for n in ["A", "B", "M"] { mesh.addNode(n) }
        mesh.connect("A", "B")
        mesh.connect("B", "M")
        mesh.run(for: 5)
        let a = mesh.node("A"), b = mesh.node("B"), m = mesh.node("M")

        let group = try a.createGroup(name: "Family", members: [b.peerID])
        mesh.run(for: 5)
        #expect(b.groups[group.id]?.key == group.key)

        // M is not a member. She learns group.id from any group packet header and sends B a forged invite.
        let evilKey = MeshCrypto.makeGroupKey()
        let forged = GroupInvite(groupID: group.id, name: "Family",
                                 members: [a.peerID, b.peerID, m.peerID].sorted(), key: evilKey)
        try m.sendDirect(.groupInvite(forged), to: b.peerID)
        mesh.run(for: 5)

        #expect(b.groups[group.id]?.key == group.key, "B's group key was replaced by a non-member")
        #expect(b.groups[group.id]?.members.contains(m.peerID) == false, "non-member added herself to the roster")
    }

    /// seenPackets (30 min) is much shorter than maxClockSkew (24 h), and control messages are
    /// applied before message-ID dedup, so a captured invite can be replayed to re-join a user
    /// to a group they left.
    @Test func replayedInviteDoesNotRejoinLeftGroup() throws {
        let clock = Clock()
        let a = Harness("A", clock: clock), b = Harness("B", clock: clock)
        let ab = LinkID("A->B"), ba = LinkID("B->A")
        a.node.linkDidConnect(ab)
        b.node.linkDidConnect(ba)
        // B learns A's keys and vice versa.
        for p in b.transport.packets() { a.node.receive(frame: Self.frame(p), from: ab) }
        for p in a.transport.packets() { b.node.receive(frame: Self.frame(p), from: ba) }

        a.transport.sent.removeAll()
        let group = try a.node.createGroup(name: "G", members: [b.node.peerID])
        let invitePackets = a.transport.packets().filter { $0.type == .message && $0.destination == b.node.peerID }
        #expect(!invitePackets.isEmpty)
        for p in invitePackets { b.node.receive(frame: Self.frame(p), from: ba) }
        #expect(b.node.groups[group.id] != nil)

        b.node.leaveGroup(group.id)
        #expect(b.node.groups[group.id] == nil)

        // Attacker replays the captured (still validly signed) invite 31 minutes later.
        clock.now += 31 * 60
        for p in invitePackets { b.node.receive(frame: Self.frame(p), from: ba) }
        #expect(b.node.groups[group.id] == nil, "replayed invite silently re-joined B to the group")
    }

    // MARK: - Sender binding

    /// The sealed box is not bound to the sender, so a relay can re-sign someone else's
    /// ciphertext as its own packet and the recipient attributes the plaintext to the relay.
    @Test func relayCannotReattributeSomeoneElsesDirectMessage() throws {
        let clock = Clock()
        let aID = MeshIdentity(), mID = MeshIdentity()
        let b = Harness("B", clock: clock)
        let link = LinkID("B->M")
        b.node.linkDidConnect(link)

        let envelope = MessageEnvelope(sentAt: clock.now, senderName: "A", content: .text("SOS at 12.34,56.78"))
        let sealed = try MeshCrypto.sealDirect(try envelope.encode(), to: b.node.identity.publicIdentity.agreementKey,
                                               from: aID.publicIdentity.signingKey)
        let original = try Packet.make(type: .message, flags: .directEncrypted, ttl: 7, destination: b.node.peerID,
                                       payload: sealed, identity: aID, now: clock.now)
        // M (a relay) drops A's packet and forwards the same ciphertext signed by herself.
        let rewrapped = try Packet.make(type: .message, flags: .directEncrypted, ttl: 7, destination: b.node.peerID,
                                        payload: original.payload, identity: mID, now: clock.now)
        b.node.receive(frame: Self.frame(rewrapped), from: link)

        #expect(b.recorder.received.allSatisfy { $0.sender != mID.peerID },
                "A's message was delivered as coming from M")
    }

    // MARK: - Store-and-forward

    /// Acks are not checked against the carried packet's destination, so any identity can
    /// make every carrier drop any carried packet (packet IDs are visible in clear).
    @Test func forgedAckFromThirdPartyDoesNotPurgeCarriedPacket() throws {
        let clock = Clock()
        let c = Harness("C", clock: clock)
        let inLink = LinkID("C->A")
        c.node.linkDidConnect(inLink)
        let aID = MeshIdentity(), dID = MeshIdentity(), mID = MeshIdentity()

        let dm = try Packet.make(type: .message, flags: .directEncrypted, ttl: 7, destination: dID.peerID,
                                 payload: Data(repeating: 7, count: 80), identity: aID, now: clock.now)
        c.node.receive(frame: Self.frame(dm), from: inLink)
        #expect(c.node.stats.carried == 1)

        let ack = AckPayload(kind: .delivered, messageID: UUID(), ackedPacketID: dm.packetID)
        let forged = try Packet.make(type: .ack, ttl: 7, destination: MeshIdentity().peerID,
                                     payload: ack.encode(), identity: mID, now: clock.now)
        c.node.receive(frame: Self.frame(forged), from: inLink)

        let newLink = LinkID("C->D")
        c.transport.sent.removeAll()
        c.node.linkDidConnect(newLink)
        let handed = c.transport.packets(on: newLink).contains { $0.packetID == dm.packetID }
        #expect(handed, "carried packet was dropped because of an ack from an unrelated identity")
    }

    // MARK: - Routing

    /// `hops` is unsigned and used as the routing metric, so one relay can rewrite it to 0 and
    /// attract the route (and "neighbor" status) for any peer in the mesh.
    @Test func relayCannotMakeDistantPeerLookLikeNeighbor() throws {
        let clock = Clock()
        let a = Harness("A", clock: clock)
        let honest = LinkID("A->B"), evil = LinkID("A->M")
        a.node.linkDidConnect(honest)
        a.node.linkDidConnect(evil)
        let dID = MeshIdentity()

        a.node.receive(frame: Self.frame(try Self.announce(dID, name: "D", hops: 3, now: clock.now)), from: honest)
        #expect(a.node.peer(dID.peerID)?.hops == 3)

        // Next announce from D: M relays it with hops rewritten to 0.
        clock.now += 20
        a.node.receive(frame: Self.frame(try Self.announce(dID, name: "D", hops: 0, now: clock.now)), from: evil)
        #expect(a.node.peer(dID.peerID)?.isNeighbor == false, "a relay made a 4-hop peer look like a direct neighbor")
    }

    // MARK: - Replay / rate limiting

    /// Packets older than seenLifetime but younger than maxClockSkew are accepted as new.
    /// Replaying a victim's old announces drains the victim's per-origin relay budget at
    /// every neighbor, so the victim's real messages stop being relayed.
    @Test func replayedOldPacketsCannotCensorTheirOrigin() throws {
        let clock = Clock()
        let r = Harness("R", clock: clock)
        let fromM = LinkID("R->M"), fromV = LinkID("R->V"), out = LinkID("R->X")
        for l in [fromM, fromV, out] { r.node.linkDidConnect(l) }
        let victim = MeshIdentity()

        // Attacker records 40 of the victim's announces over ~15 minutes (one every 20 s).
        var captured: [Packet] = []
        for i in 0..<40 {
            captured.append(try Self.announce(victim, name: "V",
                                              now: clock.now.addingTimeInterval(Double(i) * 20 - 3600)))
        }
        // An hour later they replay them all at once.
        for p in captured { r.node.receive(frame: Self.frame(p), from: fromM) }

        r.transport.sent.removeAll()
        let real = try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                                   payload: try MessageEnvelope(sentAt: clock.now, senderName: "V",
                                                                content: .text("help")).encode(),
                                   identity: victim, now: clock.now)
        r.node.receive(frame: Self.frame(real), from: fromV)
        let relayed = r.transport.packets(on: out).contains { $0.packetID == real.packetID }
        #expect(relayed, "victim's genuine message was rate-limited by replays of its own old packets")
    }

    // MARK: - Outbox

    /// Every link connect resets nextAttemptAt for all pending messages and burns an attempt,
    /// so ordinary BLE link churn exhausts maxDeliveryAttempts in seconds instead of minutes.
    @Test func linkChurnDoesNotExhaustRetryBudget() throws {
        let mesh = SimulatedMesh()
        for n in ["A", "B", "D"] { mesh.addNode(n) }
        mesh.chain(["A", "B", "D"])
        mesh.run(for: 5)
        let a = mesh.node("A"), d = mesh.node("D")
        mesh.disconnect("B", "D") // D goes away; A still has D's keys

        let id = try a.sendDirect(.text("are you ok?"), to: d.peerID)
        for _ in 0..<10 {
            mesh.disconnect("A", "B")
            mesh.connect("A", "B")
            mesh.run(for: 1)
        }
        // ~10 s elapsed; the configured backoff alone would allow ~8 minutes before failing.
        #expect(a.outgoingStatus(id) != .failed, "message failed after 10 s of link flapping")
    }

    // MARK: - Fragments

    /// The pending-reassembly cap is global, so one neighbor can evict every other link's
    /// in-progress fragmented packets.
    @Test func oneLinkCannotEvictAnotherLinksReassembly() throws {
        let reassembler = Reassembler()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let packet = Data(repeating: 1, count: 300)
        let frames = Framing.frames(for: packet, maxFrameSize: 182, groupID: 1)
        #expect(frames.count == 2)
        let good = LinkID("good"), evil = LinkID("evil")
        #expect(try reassembler.accept(frames[0], from: good, now: now) == nil)

        for g in 0..<128 {
            let junk = Framing.frames(for: Data(repeating: 0, count: 300), maxFrameSize: 182, groupID: UInt32(1000 + g))
            _ = try reassembler.accept(junk[0], from: evil, now: now.addingTimeInterval(1))
        }
        #expect(try reassembler.accept(frames[1], from: good, now: now.addingTimeInterval(2)) == packet,
                "legit partial packet was evicted by another link's junk fragments")
    }
}
