import Foundation
import Testing
import MeshCore // public API only: no @testable, no simulator

/// What an app embedding MeshCore writes: a transport that moves frames between phones, and a
/// delegate that receives messages. Here the "radio" is an in-memory loopback with a manual clock.
final class LoopbackRadio: MeshTransport {
    struct Frame { let to: MeshNode; let link: LinkID; let data: Data }
    private var queue: [Frame] = []
    private var ends: [LinkID: (node: MeshNode, remote: LinkID)] = [:]
    private var nextLink = 1

    /// Connect two nodes with a new bidirectional link.
    func connect(_ a: MeshNode, _ b: MeshNode) {
        let la = LinkID("link-\(nextLink)"), lb = LinkID("link-\(nextLink + 1)")
        nextLink += 2
        ends[la] = (b, lb)
        ends[lb] = (a, la)
        a.transport = self
        b.transport = self
        a.linkDidConnect(la)
        b.linkDidConnect(lb)
    }

    func send(frames: [Data], over link: LinkID, priority: TrafficPriority) -> Bool {
        guard let end = ends[link] else { return false }
        queue += frames.map { Frame(to: end.node, link: end.remote, data: $0) }
        return true
    }

    func maximumFrameSize(for link: LinkID) -> Int { 182 }

    /// Deliver everything in flight (nodes may send more while receiving).
    func pump() {
        while !queue.isEmpty {
            let frame = queue.removeFirst()
            frame.to.receive(frame: frame.data, from: frame.link)
        }
    }
}

final class Inbox: MeshNodeDelegate {
    var messages: [ReceivedMessage] = []
    var statuses: [UUID: DeliveryStatus] = [:]
    func meshNode(_ node: MeshNode, didReceive message: ReceivedMessage) { messages.append(message) }
    func meshNode(_ node: MeshNode, didUpdateDelivery messageID: UUID, status: DeliveryStatus) { statuses[messageID] = status }
    var texts: [String] { messages.compactMap { if case .text(let t) = $0.envelope.content { return t }; return nil } }
}

@Suite("SDK: public API")
struct SDKUsageTests {
    /// Three phones in a line: alice — bob — carol (alice and carol are out of range of each other).
    func makeLine() -> (LoopbackRadio, [MeshNode], [Inbox], () -> Void) {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = { now }
        let radio = LoopbackRadio()
        let nodes = ["alice", "bob", "carol"].map { MeshNode(identity: MeshIdentity(), nickname: $0, clock: clock) }
        let inboxes = nodes.map { _ in Inbox() }
        for (node, inbox) in zip(nodes, inboxes) { node.delegate = inbox }
        radio.connect(nodes[0], nodes[1])
        radio.connect(nodes[1], nodes[2])
        let advance = {
            for _ in 0..<10 {
                now += 1
                nodes.forEach { $0.tick() }
                radio.pump()
            }
        }
        radio.pump()
        advance()
        return (radio, nodes, inboxes, advance)
    }

    @Test func discoverRouteAndDeliverAnEncryptedDirectMessage() throws {
        let (_, nodes, inboxes, advance) = makeLine()
        let (alice, carol) = (nodes[0], nodes[2])
        #expect(alice.peer(carol.peerID)?.hops == 1) // via bob
        let id = try alice.sendDirect(.text("hi carol"), to: carol.peerID)
        advance()
        #expect(inboxes[2].texts == ["hi carol"])
        #expect(inboxes[2].messages.first?.scope == .direct)
        #expect(inboxes[2].messages.first?.sender == alice.peerID)
        #expect(inboxes[1].texts.isEmpty) // bob relayed it but can't read it
        #expect(inboxes[0].statuses[id] == .delivered)
    }

    @Test func publicChannelAndGroups() throws {
        let (_, nodes, inboxes, advance) = makeLine()
        let (alice, bob, carol) = (nodes[0], nodes[1], nodes[2])
        try alice.sendBroadcast(.text("hello everyone"))
        advance()
        #expect(inboxes[1].texts.contains("hello everyone") && inboxes[2].texts.contains("hello everyone"))

        let group = try alice.createGroup(name: "Team", members: [carol.peerID])
        advance()
        #expect(carol.groups[group.id] != nil)
        try carol.sendGroup(.text("team only"), groupID: group.id)
        advance()
        #expect(inboxes[0].texts.contains("team only"))
        #expect(!inboxes[1].texts.contains("team only")) // bob isn't in the group
        #expect(bob.groups[group.id] == nil)
    }

    @Test func snapshotRestoresKeysAndGroupsAcrossRestarts() throws {
        let (_, nodes, _, advance) = makeLine()
        let group = try nodes[0].createGroup(name: "Team", members: [nodes[2].peerID])
        advance()
        let snapshot = nodes[0].snapshot()
        let data = try JSONEncoder().encode(snapshot)
        let restored = MeshNode(identity: nodes[0].identity, nickname: "alice")
        restored.restore(try JSONDecoder().decode(MeshNodeSnapshot.self, from: data))
        #expect(restored.groups[group.id]?.key == nodes[0].groups[group.id]?.key)
        #expect(restored.peer(nodes[2].peerID) != nil)
    }

    @Test func onDeviceIntelligenceIsUsableWithoutAModel() {
        let triage = HeuristicTriage.triage("Two people trapped under a collapsed wall near the school, one bleeding")
        #expect(triage.category == .trapped)
        #expect(triage.priority >= .high)
        let answer = AnswerSafety.compose(question: "how to stop bleeding", generated: nil,
                                          references: EmergencyKnowledge.search("bleeding"))
        #expect(answer.confidence == .high && !answer.sources.isEmpty)
    }
}
