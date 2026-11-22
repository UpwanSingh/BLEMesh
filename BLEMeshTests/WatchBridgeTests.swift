import Foundation
import SwiftData
import Testing
import MeshCore
@testable import BLEMesh

/// The iPhone side of Apple Watch SOS, driven directly (no WatchConnectivity session in tests).
@MainActor
@Suite("Apple Watch bridge (demo mesh)", .serialized)
struct WatchBridgeTests {
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

    @Test func watchSOSGoesOutOverTheMeshWithThePhonesLocation() async throws {
        let service = makeService()
        let bridge = WatchBridge(mesh: service, session: nil)
        #expect(await eventually { service.peers.contains { $0.nickname == "Asha" && $0.isReachable } })
        let reply = await bridge.handle(WatchMessage.request(.sos))
        #expect(reply[WatchMessage.Key.result] as? String == "sent")
        #expect((reply[WatchMessage.Key.peers] as? Int ?? 0) >= 2)
        let (sos, _) = try #require(service.latestOwnSOS())
        guard case .sos(let report)? = sos.content else { Issue.record("not an SOS"); return }
        #expect(report.text.contains("Apple Watch"))
        #expect(report.location == MeshService.demoLocation)
        #expect(report.triage != nil)
        // Asha answers "on my way"; the watch's status follows.
        #expect(await eventually { (bridge.status(service, result: .sent)[WatchMessage.Key.sosResponders] as? Int ?? 0) >= 1 })
        #expect(bridge.status(service, result: .sent)[WatchMessage.Key.sosStatus] as? String == "Help on the way")
    }

    @Test func staleQueuedRequestsAreNotSent() async {
        let service = makeService()
        let bridge = WatchBridge(mesh: service, session: nil)
        let old = WatchMessage.request(.sos, at: Date().addingTimeInterval(-2 * 3600))
        let reply = await bridge.handle(old)
        #expect(reply[WatchMessage.Key.result] as? String == "failed")
        #expect(service.latestOwnSOS() == nil)
        #expect(await bridge.handle(["action": "selfDestruct"])[WatchMessage.Key.result] as? String == "failed")
    }

    @Test func imSafeFromTheWatchGoesToGroups() async throws {
        let service = makeService()
        let bridge = WatchBridge(mesh: service, session: nil)
        #expect(await bridge.handle(WatchMessage.request(.safe))[WatchMessage.Key.result] as? String == "noGroups")
        #expect(await eventually { service.peers.contains { $0.nickname == "Kabir" && $0.isReachable } })
        let kabir = try #require(service.peers.first { $0.nickname == "Kabir" })
        let key = try #require(service.createGroup(name: "Family", members: [kabir.peerID]))
        #expect(await bridge.handle(WatchMessage.request(.safe))[WatchMessage.Key.result] as? String == "sent")
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationKey == key && $0.isOutgoing == true })
        #expect(((try? service.context.fetch(descriptor)) ?? []).contains { if case .checkIn? = $0.content { return true }; return false })
    }
}
