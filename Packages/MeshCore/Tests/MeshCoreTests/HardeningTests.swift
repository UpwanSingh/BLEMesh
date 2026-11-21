import Foundation
import Testing
@testable import MeshCore
import MeshSimulator

@Suite("Hardening")
struct HardeningTests {
    typealias H = SecurityReviewTests

    @Test func controlAndAIContentCannotBeSpoofedOverBroadcast() throws {
        let clock = H.Clock()
        let b = H.Harness("B", clock: clock)
        let link = LinkID("B->M")
        b.node.linkDidConnect(link)
        let m = MeshIdentity()
        for content: MeshContent in [
            .groupInvite(GroupInvite(groupID: UUID(), name: "Fake", members: [b.node.peerID, m.peerID], key: MeshCrypto.makeGroupKey())),
            .groupLeave(groupID: UUID()),
            .aiResponse(AIResponse(queryID: UUID(), text: "drink bleach", answeredBy: "Doctor")),
        ] {
            let envelope = MessageEnvelope(sentAt: clock.now, senderName: "M", content: content)
            let packet = try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                                         payload: try envelope.encode(), identity: m, now: clock.now)
            b.node.receive(frame: H.frame(packet), from: link)
        }
        #expect(b.recorder.received.isEmpty)
        #expect(b.node.groups.isEmpty)
    }

    @Test func groupMessagesFromNonMembersAreIgnored() throws {
        let mesh = SimulatedMesh()
        for n in ["A", "B", "X"] { mesh.addNode(n) }
        mesh.chain(["A", "B", "X"])
        mesh.run(for: 5)
        let a = mesh.node("A"), b = mesh.node("B"), x = mesh.node("X")
        let group = try a.createGroup(name: "G", members: [b.peerID, x.peerID])
        mesh.run(for: 5)
        // X leaves; A and B drop X from the roster.
        x.leaveGroup(group.id)
        #expect(mesh.run(until: { a.groups[group.id]?.members.contains(x.peerID) == false &&
                                  b.groups[group.id]?.members.contains(x.peerID) == false }, timeout: 10))
        // X kept the key and tries to post anyway (forging its own still-valid packet).
        let envelope = MessageEnvelope(sentAt: mesh.now, senderName: "X", groupID: group.id, content: .text("I'm still here"))
        let sealed = try MeshCrypto.sealGroup(try envelope.encode(), groupID: group.id, key: group.key,
                                              from: x.identity.publicIdentity.signingKey)
        let packet = try Packet.make(type: .message, flags: .groupEncrypted, ttl: 7, destination: .broadcast,
                                     payload: sealed, identity: x.identity, now: mesh.now)
        b.receive(frame: H.frame(packet), from: LinkID("B->X"))
        mesh.run(for: 2)
        #expect(!mesh.recorder("B").texts().contains("I'm still here"))
        #expect(!mesh.recorder("A").texts().contains("I'm still here"))
    }

    @Test func inflatedTTLIsCappedOnReceipt() throws {
        let clock = H.Clock()
        let r = H.Harness("R", clock: clock)
        let inLink = LinkID("R->M"), outLink = LinkID("R->X")
        r.node.linkDidConnect(inLink)
        r.node.linkDidConnect(outLink)
        r.transport.sent.removeAll()
        var packet = try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                                     payload: try MessageEnvelope(sentAt: clock.now, senderName: "M", content: .text("x")).encode(),
                                     identity: MeshIdentity(), now: clock.now)
        packet.ttl = 255 // unsigned field rewritten by a malicious relay
        r.node.receive(frame: H.frame(packet), from: inLink)
        let relayed = try #require(r.transport.packets(on: outLink).first { $0.packetID == packet.packetID })
        #expect(relayed.ttl == r.node.config.messageTTL - 1)
    }

    @Test func futureAndStalePacketsAreRejected() throws {
        let clock = H.Clock()
        let b = H.Harness("B", clock: clock)
        let link = LinkID("B->M")
        b.node.linkDidConnect(link)
        let m = MeshIdentity()
        let future = try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                                     payload: try MessageEnvelope(sentAt: clock.now, senderName: "M", content: .text("future")).encode(),
                                     identity: m, now: clock.now.addingTimeInterval(3600))
        let staleAnnounce = try H.announce(m, name: "M", now: clock.now.addingTimeInterval(-600))
        b.node.receive(frame: H.frame(future), from: link)
        b.node.receive(frame: H.frame(staleAnnounce), from: link)
        #expect(b.recorder.received.isEmpty)
        #expect(b.node.peer(m.peerID) == nil)
        #expect(b.node.stats.staleDropped == 2)
    }

    @Test func finishedOutboxEntriesArePruned() throws {
        let mesh = SimulatedMesh()
        mesh.addNode("A"); mesh.addNode("B")
        mesh.connect("A", "B")
        mesh.run(for: 3)
        let a = mesh.node("A")
        let id = try a.sendDirect(.text("hi"), to: mesh.node("B").peerID)
        #expect(mesh.run(until: { a.outgoingStatus(id) == .delivered }, timeout: 5))
        mesh.run(for: 25 * 3600)
        #expect(a.outgoingStatus(id) == nil)
    }

    @Test func neighboursAreProvenWithHelloAndRelayedPeersAreNot() {
        let mesh = SimulatedMesh()
        for n in ["A", "B", "C"] { mesh.addNode(n) }
        mesh.chain(["A", "B", "C"])
        mesh.run(for: 3)
        let a = mesh.node("A")
        #expect(a.peer(mesh.node("B").peerID)?.hops == 0)
        #expect(a.peer(mesh.node("C").peerID)?.hops == 1)
    }

    @Test func carriedPacketsAreForwardedWhenARouteAppearsOnAnExistingLink() throws {
        // A carries a packet for D; later D becomes reachable through an already-connected link.
        let mesh = SimulatedMesh()
        for n in ["S", "A", "B", "D"] { mesh.addNode(n) }
        mesh.chain(["S", "A", "B", "D"])
        mesh.run(for: 5)
        let d = mesh.node("D").peerID
        mesh.disconnect("B", "D")
        mesh.run(for: 100)
        let id = try mesh.node("S").sendDirect(.text("hold this"), to: d)
        mesh.run(for: 3)
        #expect(mesh.node("A").stats.carried + mesh.node("B").stats.carried > 0)
        mesh.connect("B", "D") // A's link to B already exists; the route to D appears through it
        #expect(mesh.run(until: { mesh.recorder("D").texts().contains("hold this") }, timeout: 15))
        #expect(mesh.run(until: { mesh.node("S").outgoingStatus(id) == .delivered }, timeout: 15))
    }
}
