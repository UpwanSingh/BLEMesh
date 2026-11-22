import Foundation
import Testing
@testable import MeshCore
import MeshSimulator

@Suite("Group invite codes")
struct JoinCodeTests {
    /// A administers "Family" with B; E is in range but not a member; X is another phone.
    func setUp() throws -> (SimulatedMesh, GroupInfo) {
        let mesh = SimulatedMesh()
        for n in ["A", "B", "E", "X", "H"] { mesh.addNode(n) }
        for n in ["A", "B", "E", "X"] { mesh.connect(n, "H") }
        mesh.run(for: 6)
        let group = try mesh.node("A").createGroup(name: "Family", members: [mesh.node("B").peerID])
        #expect(mesh.run(until: { mesh.node("B").groups[group.id] != nil }, timeout: 10))
        return (mesh, group)
    }

    @Test func codeRoundTripsAndRejectsGarbage() throws {
        let code = GroupJoinCode(groupID: UUID(), groupName: "Rescue team: ward 7 / नगर", admin: MeshIdentity().peerID,
                                 secret: Data((0..<16).map { UInt8($0) }), expires: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(GroupJoinCode(string: code.string) == code)
        #expect(GroupJoinCode(string: "  \(code.string)\n") == code)
        for bad in ["", "blemesh:v1:abc", code.string.replacingOccurrences(of: "join:v1", with: "join:v9"),
                    code.string + ":extra",
                    code.string.replacingOccurrences(of: "000102030405060708090a0b0c0d0e0f", with: "0001020304"),
                    code.string.replacingOccurrences(of: "000102030405060708090a0b0c0d0e0f", with: "zz0102030405060708090a0b0c0d0e0f")] {
            #expect(GroupJoinCode(string: bad) == nil, "\(bad)")
        }
    }

    @Test func scanningTheCodeJoinsTheGroupAndRekeys() throws {
        let (mesh, group) = try setUp()
        let a = mesh.node("A"), e = mesh.node("E")
        let oldKey = try #require(a.groups[group.id]?.key)
        let code = try a.makeJoinCode(for: group.id)
        let parsed = try #require(GroupJoinCode(string: code.string))
        try e.requestToJoin(parsed)
        #expect(mesh.run(until: { e.groups[group.id] != nil }, timeout: 15))
        #expect(a.groups[group.id]?.members.contains(e.peerID) == true)
        #expect(a.groups[group.id]?.key != oldKey, "joining re-keys the group")
        #expect(mesh.run(until: { mesh.node("B").groups[group.id]?.members.contains(e.peerID) == true }, timeout: 10))
        // The newcomer can talk to the group.
        let id = try e.sendGroup(.text("hi, it's E"), groupID: group.id)
        #expect(mesh.run(until: { mesh.recorder("B").hasReceived(id) }, timeout: 10))
    }

    @Test func wrongExpiredOrRevokedCodesAreIgnored() throws {
        let (mesh, group) = try setUp()
        let a = mesh.node("A"), e = mesh.node("E"), x = mesh.node("X")
        let real = try a.makeJoinCode(for: group.id)
        // A guessed secret.
        var forged = real
        forged.secret = Data(repeating: 7, count: 16)
        try x.requestToJoin(forged)
        mesh.run(for: 5)
        #expect(a.groups[group.id]?.members.contains(x.peerID) == false)
        #expect(x.groups[group.id] == nil)
        // A revoked code.
        a.revokeJoinCode(for: group.id)
        try e.requestToJoin(real)
        mesh.run(for: 5)
        #expect(a.groups[group.id]?.members.contains(e.peerID) == false)
        // An expired code is refused before anything is sent, and by the admin if it arrives late.
        let short = try a.makeJoinCode(for: group.id, validFor: 1)
        mesh.run(for: 3)
        #expect(throws: MeshNodeError.codeExpired) { try e.requestToJoin(short) }
    }

    @Test func onlyTheAdminCanMakeCodes() throws {
        let (mesh, group) = try setUp()
        #expect(throws: MeshNodeError.notGroupAdmin) { try mesh.node("B").makeJoinCode(for: group.id) }
        #expect(throws: MeshNodeError.unknownGroup) { try mesh.node("E").makeJoinCode(for: group.id) }
        // A join request sent to a non-admin member is ignored.
        let code = try mesh.node("A").makeJoinCode(for: group.id)
        var misdirected = code
        misdirected.admin = mesh.node("B").peerID
        try mesh.node("E").requestToJoin(misdirected)
        mesh.run(for: 5)
        #expect(mesh.node("E").groups[group.id] == nil)
    }
}
