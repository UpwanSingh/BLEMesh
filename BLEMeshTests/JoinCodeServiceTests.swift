import Foundation
import SwiftData
import Testing
import MeshCore
@testable import BLEMesh

/// QR invite codes against the demo mesh: both the admin side and the joining side.
@MainActor
@Suite("Group invite codes (demo mesh)", .serialized)
struct JoinCodeServiceTests {
    func makeService() -> MeshService {
        let suite = "tests.\(UUID().uuidString)"
        return MeshService(mode: .demo, container: PersistenceController.makeContainer(inMemory: true),
                           settings: AppSettings(defaults: UserDefaults(suiteName: suite)!),
                           trust: TrustStore(defaults: UserDefaults(suiteName: suite)!, medicalAccount: suite),
                           ai: MockAI(generative: false), persistSnapshot: false)
    }

    func eventually(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    func texts(_ service: MeshService, _ key: String) -> [String] {
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationKey == key }, sortBy: [SortDescriptor(\.sentAt)])
        return ((try? service.context.fetch(descriptor)) ?? []).map(\.previewText)
    }

    func peer(_ service: MeshService, _ name: String) -> PeerInfo? {
        service.peers.first { $0.nickname == name && $0.isReachable }
    }

    @Test func someoneScanningMyCodeJoinsMyGroup() async throws {
        let service = makeService()
        #expect(await eventually { peer(service, "Asha") != nil && peer(service, "Meera") != nil })
        let key = try #require(service.createGroup(name: "Family", members: [peer(service, "Asha")!.peerID]))
        let code = try #require(service.makeJoinCode(groupKey: key))
        #expect(code.string.hasPrefix("blemesh:join:v1:"))
        let oldKey = service.node.groups[code.groupID]?.key
        service.demoScan(code, by: "Meera") // Meera is 3 hops away
        let meera = try #require(peer(service, "Meera")).peerID
        #expect(await eventually(20) { service.node.groups[code.groupID]?.members.contains(meera) == true })
        #expect(service.node.groups[code.groupID]?.key != oldKey)
        #expect(await eventually { texts(service, key).contains("Meera joined with the invite code") })
    }

    @Test func iJoinABotsGroupWithItsCode() async throws {
        let service = makeService()
        #expect(await eventually { peer(service, "Kabir") != nil && peer(service, "Asha") != nil })
        let code = try #require(service.demoBotGroupCode(admin: "Kabir", members: ["Asha"], name: "Kabir's family"))
        #expect(service.joinGroup(code: code.string) == .requested(adminName: "Kabir"))
        let key = ConversationKey.group(code.groupID)
        #expect(await eventually(20) { service.node.groups[code.groupID]?.members.contains(service.myPeerID) == true })
        #expect(await eventually { texts(service, key).contains("Kabir added you to “Kabir's family”") })
        // And I can post to the group with the new key.
        #expect(service.send(.text("thanks for adding me"), to: key) != nil)
        #expect(service.node.groups[code.groupID]?.key.count == 32)
        // Asking again: already a member.
        #expect(service.joinGroup(code: code.string) == .alreadyMember)
    }

    @Test func badCodesAreRejectedLocally() {
        let service = makeService()
        #expect(service.joinGroup(code: "hello") == .invalid)
        #expect(service.joinGroup(code: "blemesh:v1:abc") == .invalid)
        let expired = GroupJoinCode(groupID: UUID(), groupName: "Old", admin: MeshIdentity().peerID,
                                    secret: Data(count: 16), expires: Date().addingTimeInterval(-60))
        #expect(service.joinGroup(code: expired.string) == .expired)
        #expect(service.makeJoinCode(groupKey: "nearby") == nil)
    }
}
