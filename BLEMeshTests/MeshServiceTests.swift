import Foundation
import SwiftData
import Testing
import MeshCore
@testable import BLEMesh

/// Deterministic stand-in for the on-device model.
@MainActor
final class MockAI: AIEngine {
    var hasGenerativeModel: Bool
    var statusDescription: String { "mock" }
    private(set) var questions: [String] = []

    init(generative: Bool) { hasGenerativeModel = generative }

    func answer(_ question: String, local: [LocalMessage]) async -> SafeAnswer {
        questions.append(question)
        guard hasGenerativeModel else { return OfflineKnowledgeEngine.offlineAnswer(question, local: local) }
        return AnswerSafety.compose(question: question, generated: "MOCK ANSWER: \(question)",
                                    references: EmergencyKnowledge.search(question))
    }

    func triage(_ text: String) async -> SOSTriage { HeuristicTriage.triage(text) }
    func overview(for digest: AreaDigest, recentTexts: [String]) async -> String { "MOCK OVERVIEW (\(digest.items.count))" }
    func translate(_ text: String, to language: String) async -> String? { hasGenerativeModel ? "[\(language)] \(text)" : nil }
    func summarize(_ transcript: String) async -> String { "MOCK SUMMARY" }
}

/// Integration tests of the app service against the simulated demo neighbourhood
/// (Me — Asha/Kabir — Ravi(AI) — Meera), with an in-memory store.
@MainActor
@Suite("MeshService (demo mesh)", .serialized)
struct MeshServiceTests {

    func makeService(generativeAI: Bool = false) -> (MeshService, MockAI) {
        let ai = MockAI(generative: generativeAI)
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let service = MeshService(mode: .demo, container: PersistenceController.makeContainer(inMemory: true),
                                  settings: AppSettings(defaults: defaults), ai: ai, persistSnapshot: false)
        return (service, ai)
    }

    /// Poll while the main run loop keeps the simulated mesh running.
    func eventually(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    func messages(_ service: MeshService, _ key: String) -> [StoredMessage] {
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationKey == key },
                                                        sortBy: [SortDescriptor(\.sentAt)])
        return (try? service.context.fetch(descriptor)) ?? []
    }

    func peer(_ service: MeshService, _ name: String) -> PeerInfo? {
        service.peers.first { $0.nickname == name && $0.isReachable }
    }

    @Test func discoversTheWholeDemoMeshByMeshIdentity() async {
        let (service, _) = makeService()
        #expect(await eventually { service.peers.filter(\.isReachable).count == 4 })
        #expect(peer(service, "Asha")?.hops == 0)
        #expect(peer(service, "Ravi")?.hops == 1)
        #expect(peer(service, "Meera")?.hops == 2)
        #expect(peer(service, "Ravi")?.capabilities.contains(.onDeviceAI) == true)
        #expect(service.linkCount == 2)
    }

    @Test func directMessageIsDeliveredReadAndAnswered() async throws {
        let (service, _) = makeService()
        #expect(await eventually { peer(service, "Asha") != nil })
        let asha = try #require(peer(service, "Asha"))
        let key = service.startDirectConversation(with: asha)
        let id = try #require(service.send(.text("hello Asha"), to: key))

        #expect(await eventually { service.fetchMessage(id)?.status == .read })
        #expect(await eventually { messages(service, key).contains { !$0.isOutgoing } })
        let reply = try #require(messages(service, key).first { !$0.isOutgoing })
        #expect(reply.senderName == "Asha")
        #expect(reply.previewText.contains("Asha"))
        #expect(service.fetchConversation(key)?.title == "Asha")
    }

    @Test func multiHopMessageReachesMeera() async throws {
        let (service, _) = makeService()
        #expect(await eventually { peer(service, "Meera") != nil })
        let meera = try #require(peer(service, "Meera"))
        let key = service.startDirectConversation(with: meera)
        let id = try #require(service.send(.text("are you ok?"), to: key))
        #expect(await eventually { (service.fetchMessage(id)?.status ?? .queued) >= .delivered })
        #expect(await eventually { messages(service, key).contains { !$0.isOutgoing && $0.hops == 2 } })
    }

    @Test func voiceNotesTravelAsTranscripts() async throws {
        let (service, _) = makeService()
        #expect(await eventually { peer(service, "Kabir") != nil })
        let key = service.startDirectConversation(with: try #require(peer(service, "Kabir")))
        let id = try #require(service.send(.voice(VoiceNote(transcript: "meet at the hall", languageCode: "en-US", durationSeconds: 2)), to: key))
        #expect(await eventually { service.fetchMessage(id)?.status == .read })
        #expect(await eventually { messages(service, key).contains { $0.previewText.contains("meet at the hall") && !$0.isOutgoing } })
    }

    @Test func groupInvitesMembersAndCarriesGroupTraffic() async throws {
        let (service, _) = makeService()
        #expect(await eventually { peer(service, "Asha") != nil && peer(service, "Meera") != nil })
        let members: Set<PeerID> = [try #require(peer(service, "Asha")).peerID, try #require(peer(service, "Meera")).peerID]
        let key = try #require(service.createGroup(name: "Rescue", members: members))
        #expect(service.group(for: key)?.members.count == 3)
        // Both bots greet the group once they receive the encrypted invite.
        #expect(await eventually(20) {
            Set(messages(service, key).filter { !$0.isOutgoing }.map(\.senderName)) == ["Asha", "Meera"]
        })
        service.send(.text("north side clear"), to: key)
        service.leaveGroup(key: key)
        #expect(service.group(for: key) == nil)
        #expect(service.fetchConversation(key) == nil)
    }

    @Test func sosIsTriagedBroadcastAndStored() async throws {
        let (service, _) = makeService()
        let triage = await service.sendSOS(text: "My father is unconscious near the temple gate", location: GeoPoint(latitude: 1, longitude: 2))
        #expect(triage.priority == .critical)
        #expect(triage.category == .medical)
        let stored = try #require(messages(service, ConversationKey.nearby).last)
        guard case .sos(let report)? = stored.content else {
            Issue.record("expected SOS content")
            return
        }
        #expect(report.location?.latitude == 1)
        #expect(report.triage == triage)
    }

    @Test func askTheMeshUsesTheNearestAIPhoneWhenThisPhoneHasNoModel() async throws {
        let (service, ai) = makeService(generativeAI: false)
        #expect(await eventually { service.node.bestAIHelper()?.nickname == "Ravi" })
        await service.ask("How do I stop bleeding?")
        #expect(service.pendingQuestions.count == 1)
        #expect(await eventually {
            messages(service, ConversationKey.askMesh).contains { $0.senderName.contains("Ravi") }
        })
        let answer = try #require(messages(service, ConversationKey.askMesh).last)
        #expect(answer.previewText.contains("Press firmly"))
        #expect(service.pendingQuestions.isEmpty)
        #expect(ai.questions.isEmpty) // not answered locally
    }

    @Test func askTheMeshAnswersLocallyWithOnDeviceModel() async {
        let (service, ai) = makeService(generativeAI: true)
        await service.ask("What is the capital of France?")
        #expect(ai.questions == ["What is the capital of France?"])
        #expect(messages(service, ConversationKey.askMesh).contains { $0.previewText.contains("MOCK ANSWER") })
    }

    @Test func helpsOthersOnlyWhenItHasAModelAndUserAllows() {
        let (withModel, _) = makeService(generativeAI: true)
        #expect(withModel.node.capabilities.contains(.onDeviceAI))
        withModel.settings.helpOthersWithAI = false
        withModel.applySettingsChange()
        #expect(!withModel.node.capabilities.contains(.onDeviceAI))

        let (withoutModel, _) = makeService(generativeAI: false)
        #expect(!withoutModel.node.capabilities.contains(.onDeviceAI))
    }

    @Test func digestSummarisesNearbyEmergencies() async {
        let (service, _) = makeService()
        _ = await service.sendSOS(text: "Fire near the market, smoke everywhere", location: nil)
        service.sendText("need water at the shelter", to: ConversationKey.nearby)
        await service.refreshDigest()
        let digest = service.digest
        #expect(digest?.items.first?.category == .fire)
        #expect(digest?.items.contains { $0.category == .supplies } == true)
        #expect(service.digestOverview == "MOCK OVERVIEW (2)")
    }

    @Test func messagesWaitWhileOutOfRangeAndDeliverOnReturn() async throws {
        let (service, _) = makeService()
        #expect(await eventually { peer(service, "Asha") != nil })
        let asha = try #require(peer(service, "Asha"))
        service.setDemoLinks(enabled: false)
        #expect(service.peers.allSatisfy { !$0.isReachable })
        let key = service.startDirectConversation(with: asha)
        let id = try #require(service.send(.text("see you soon"), to: key))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        #expect((service.fetchMessage(id)?.status ?? .failed) < .delivered)
        service.setDemoLinks(enabled: true)
        #expect(await eventually(20) { (service.fetchMessage(id)?.status ?? .queued) >= .delivered })
    }

    @Test func openingAConversationSendsReadReceiptsOnce() async throws {
        let (service, _) = makeService()
        #expect(await eventually { peer(service, "Kabir") != nil })
        let key = service.startDirectConversation(with: try #require(peer(service, "Kabir")))
        service.send(.text("ping"), to: key)
        #expect(await eventually { messages(service, key).contains { !$0.isOutgoing } })
        #expect(service.fetchConversation(key)?.unreadCount == 1)
        service.markRead(key: key)
        #expect(service.fetchConversation(key)?.unreadCount == 0)
        let incoming = messages(service, key).filter { !$0.isOutgoing }
        #expect(incoming.allSatisfy { $0.readReceiptSent })
    }

    @Test func panicWipeErasesEverythingAndRotatesIdentity() async throws {
        let (service, _) = makeService()
        let oldID = service.myPeerID
        service.sendText("secret", to: ConversationKey.nearby)
        #expect(!messages(service, ConversationKey.nearby).isEmpty)
        service.panicWipe()
        #expect(service.myPeerID != oldID)
        #expect(messages(service, ConversationKey.nearby).isEmpty)
        #expect(service.fetchConversation(ConversationKey.nearby) != nil) // default channels recreated
        #expect(await eventually { peer(service, "Asha") != nil }) // and the mesh works again
    }

    @Test func publicMessagesAreNotFakedAsSentWhenNobodyIsInRange() {
        let (service, _) = makeService()
        service.setDemoLinks(enabled: false)
        #expect(service.sendText("anyone?", to: ConversationKey.nearby) == false)
        #expect(service.lastError?.contains("Nobody is in range") == true)
        #expect(messages(service, ConversationKey.nearby).isEmpty)
    }

    @Test func panicWipeClearsDerivedState() async {
        let (service, _) = makeService()
        _ = await service.sendSOS(text: "Fire near the market", location: nil)
        await service.refreshDigest()
        #expect(service.digest != nil)
        service.panicWipe()
        #expect(service.digest == nil)
        #expect(service.digestOverview.isEmpty)
        #expect(service.pendingQuestions.isEmpty)
    }

    @Test func retentionPurgesOldMessages() {
        let (service, _) = makeService()
        let old = StoredMessage(id: UUID(), conversationKey: ConversationKey.nearby, senderHex: service.myPeerID.hex,
                                senderName: "x", isOutgoing: true, content: .text("old"),
                                sentAt: .distantPast, receivedAt: Date().addingTimeInterval(-40 * 86_400))
        service.context.insert(old)
        service.settings.retentionDays = 30
        service.purgeExpiredMessages()
        #expect(service.fetchMessage(old.id) == nil)
    }

    @Test func rejectsEmptyAndOversizedText() {
        let (service, _) = makeService()
        service.sendText("   ", to: ConversationKey.nearby)
        #expect(messages(service, ConversationKey.nearby).isEmpty)
        service.sendText(String(repeating: "x", count: 9_000), to: ConversationKey.nearby)
        #expect(service.lastError == "Message too long")
    }
}

@Suite("Conversation keys")
struct ConversationKeyTests {
    @Test func roundTrips() {
        let peer = MeshIdentity().peerID
        #expect(ConversationKey.peer(from: ConversationKey.direct(peer)) == peer)
        let group = UUID()
        #expect(ConversationKey.groupID(from: ConversationKey.group(group)) == group)
        #expect(ConversationKey.peer(from: ConversationKey.nearby) == nil)
        #expect(ConversationKey.groupID(from: "dm:abc") == nil)
    }
}
