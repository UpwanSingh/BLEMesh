import Foundation
import Testing
@testable import MeshCore
import MeshSimulator

@Suite("Group re-keying")
struct GroupRekeyTests {
    /// A, B, C, D all in range of each other (via a hub), group created by A with B, C, D.
    func makeGroup() throws -> (SimulatedMesh, GroupInfo) {
        let mesh = SimulatedMesh()
        for n in ["A", "B", "C", "D", "H"] { mesh.addNode(n) }
        for n in ["A", "B", "C", "D"] { mesh.connect(n, "H") }
        mesh.run(for: 6)
        let ids = ["B", "C", "D"].map { mesh.node($0).peerID }
        let group = try mesh.node("A").createGroup(name: "Team", members: Set(ids))
        _ = mesh.run(until: { ["B", "C", "D"].allSatisfy { mesh.node($0).groups[group.id] != nil } }, timeout: 10)
        return (mesh, group)
    }

    func groupTexts(_ mesh: SimulatedMesh, _ name: String, _ groupID: UUID) -> [String] {
        mesh.recorder(name).received.compactMap {
            guard $0.scope == .group(groupID), case .text(let t) = $0.envelope.content else { return nil }
            return t
        }
    }

    @Test func leavingMemberIsLockedOutOfNewMessages() throws {
        let (mesh, group) = try makeGroup()
        let oldKey = group.key
        let leaverOldCopy = try #require(mesh.node("D").groups[group.id])
        mesh.node("D").leaveGroup(group.id)

        // Everyone remaining gets the new key from the admin (A).
        #expect(mesh.run(until: {
            ["A", "B", "C"].allSatisfy { mesh.node($0).groups[group.id].map { $0.key != oldKey && !$0.members.contains(mesh.node("D").peerID) } ?? false }
        }, timeout: 15))
        let newKey = try #require(mesh.node("A").groups[group.id]?.key)
        #expect(mesh.node("B").groups[group.id]?.key == newKey)

        // New traffic is readable by members, but not with the key the leaver walked away with.
        let id = try mesh.node("B").sendGroup(.text("after D left"), groupID: group.id)
        mesh.run(for: 3)
        #expect(groupTexts(mesh, "C", group.id).contains("after D left"))
        // Simulate D still listening with its old key: re-install it and see that nothing new opens.
        let d = mesh.node("D")
        d.restore(MeshNodeSnapshot(outgoing: [], groups: [leaverOldCopy], peers: [], leftGroups: nil))
        let afterCount = groupTexts(mesh, "D", group.id).count
        _ = try mesh.node("C").sendGroup(.text("second after D left"), groupID: group.id)
        mesh.run(for: 3)
        #expect(groupTexts(mesh, "D", group.id).count == afterCount)
        #expect(!mesh.recorder("D").hasReceived(id))
    }

    @Test func adminCanRemoveAMemberWhoIsThenLockedOut() throws {
        let (mesh, group) = try makeGroup()
        let a = mesh.node("A"), c = mesh.node("C")
        try a.removeMember(c.peerID, from: group.id)
        #expect(a.groups[group.id]?.members.contains(c.peerID) == false)
        #expect(mesh.run(until: { mesh.node("B").groups[group.id]?.key == a.groups[group.id]?.key }, timeout: 10))
        #expect(c.groups[group.id]?.key != a.groups[group.id]?.key) // C never got the new key
        _ = try a.sendGroup(.text("C removed"), groupID: group.id)
        mesh.run(for: 3)
        #expect(groupTexts(mesh, "B", group.id).contains("C removed"))
        #expect(!groupTexts(mesh, "C", group.id).contains("C removed"))
        // And C's own posts are no longer accepted (not a member).
        _ = try? c.sendGroup(.text("I'm still here"), groupID: group.id)
        mesh.run(for: 3)
        #expect(!groupTexts(mesh, "B", group.id).contains("I'm still here"))
    }

    @Test func onlyTheAdminCanRemoveOrRekey() throws {
        let (mesh, group) = try makeGroup()
        let b = mesh.node("B")
        #expect(throws: MeshNodeError.notGroupAdmin) { try b.removeMember(mesh.node("C").peerID, from: group.id) }
        let before = b.groups[group.id]?.key
        b.rekeyGroup(group.id)
        #expect(b.groups[group.id]?.key == before)
        // A forged re-key invite from a non-admin member is rejected by the others.
        let forged = GroupInvite(groupID: group.id, name: "Team", members: Array(group.members).sorted(), key: MeshCrypto.makeGroupKey())
        try b.sendDirect(.groupInvite(forged), to: mesh.node("C").peerID)
        mesh.run(for: 3)
        #expect(mesh.node("C").groups[group.id]?.key == group.key)
    }

    @Test func whenTheCreatorLeavesTheNextAdminRekeys() throws {
        let (mesh, group) = try makeGroup()
        let remaining = ["B", "C", "D"]
        let expectedAdmin = remaining.map { mesh.node($0).peerID }.min()!
        mesh.node("A").leaveGroup(group.id)
        #expect(mesh.run(until: {
            let keys = Set(remaining.compactMap { mesh.node($0).groups[group.id]?.key })
            return keys.count == 1 && !keys.contains(group.key)
        }, timeout: 15))
        for name in remaining {
            #expect(mesh.node(name).groups[group.id]?.admin == expectedAdmin)
        }
        _ = try mesh.node("B").sendGroup(.text("without A"), groupID: group.id)
        mesh.run(for: 3)
        #expect(groupTexts(mesh, "D", group.id).contains("without A"))
        #expect(!groupTexts(mesh, "A", group.id).contains("without A"))
    }

    @Test func messagesInFlightDuringARekeyStillOpen() throws {
        let (mesh, group) = try makeGroup()
        let b = mesh.node("B")
        // B sends with the old key at the same moment A re-keys.
        mesh.node("A").rekeyGroup(group.id)
        _ = try b.sendGroup(.text("sent with the old key"), groupID: group.id)
        mesh.run(for: 5)
        #expect(groupTexts(mesh, "A", group.id).contains("sent with the old key"))
        #expect(groupTexts(mesh, "C", group.id).contains("sent with the old key"))
        // After the grace period the old key no longer opens anything.
        let a = mesh.node("A")
        #expect(a.groups[group.id]?.previousKey == group.key)
        mesh.run(for: 700)
        var stale = try #require(b.groups[group.id])
        stale.key = group.key
        stale.previousKey = nil
        b.restore(MeshNodeSnapshot(outgoing: [], groups: [stale], peers: [], leftGroups: nil))
        _ = try b.sendGroup(.text("too late with the old key"), groupID: group.id)
        mesh.run(for: 3)
        #expect(!groupTexts(mesh, "A", group.id).contains("too late with the old key"))
    }
}
