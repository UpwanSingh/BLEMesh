import Foundation
import SwiftData
import Testing
import MeshCore
@testable import BLEMesh

/// Phase 2 (local AI) features against the demo mesh: answers from what the mesh heard,
/// truthful provenance, shared AI tasks via Ravi, catch-up, credibility, spam, auto-reply, roles.
@MainActor
@Suite("Phase 2 features (demo mesh)", .serialized)
struct Phase2ServiceTests {
    func makeService(generativeAI: Bool = false) -> (MeshService, MockAI) {
        let suite = "tests.\(UUID().uuidString)"
        let ai = MockAI(generative: generativeAI)
        let trust = TrustStore(defaults: UserDefaults(suiteName: suite)!, medicalAccount: suite)
        let service = MeshService(mode: .demo, container: PersistenceController.makeContainer(inMemory: true),
                                  settings: AppSettings(defaults: UserDefaults(suiteName: suite)!), trust: trust,
                                  ai: ai, persistSnapshot: false)
        return (service, ai)
    }

    func eventually(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    func messages(_ service: MeshService, _ key: String) -> [StoredMessage] {
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationKey == key }, sortBy: [SortDescriptor(\.sentAt)])
        return (try? service.context.fetch(descriptor)) ?? []
    }

    func peer(_ service: MeshService, _ name: String) -> PeerInfo? {
        service.peers.first { $0.nickname == name && $0.isReachable }
    }

    func responses(_ service: MeshService) -> [AIResponse] {
        messages(service, ConversationKey.askMesh).compactMap { if case .aiResponse(let r)? = $0.content { return r }; return nil }
    }

    func heard(_ service: MeshService, _ fragment: String) -> Bool {
        messages(service, ConversationKey.nearby).contains { $0.previewText.contains(fragment) }
    }

    // MARK: #6 Answers from what the mesh has heard, labelled truthfully

    @Test func localQuestionIsAnsweredFromMessagesThisPhoneHeard() async throws {
        let (service, ai) = makeService()
        // Ravi's "drinking water … community hall" broadcast is scripted at ~40 s.
        #expect(await eventually(60) { heard(service, "community hall") })
        await service.ask("Where is water being given out?")
        let answer = try #require(responses(service).last)
        #expect(answer.answeredBy == "Messages nearby")
        #expect(answer.text.contains("community hall"))
        #expect(answer.text.contains("not verified"))
        #expect(ai.questions.count == 1) // answered here; not sent to Ravi, who can't see our messages
    }

    @Test func answersAreLabelledByWhatActuallyProducedThem() async throws {
        let (service, _) = makeService(generativeAI: true)
        await service.ask("How do I treat a burn?")
        let model = try #require(responses(service).last)
        #expect(model.answeredBy == "This phone (on-device AI)")
        #expect(model.text.contains("MOCK ANSWER"))
        #expect(model.text.contains("Sources: Burns"))
        // Dosing questions are refused even when a model is available, and not labelled as the model.
        await service.ask("How much paracetamol can I give my 4 year old?")
        let refused = try #require(responses(service).last)
        #expect(!refused.text.contains("MOCK ANSWER"))
        #expect(refused.text.contains("pharmacist"))
        #expect(refused.answeredBy == "Offline guide")
    }

    // MARK: #15 Shared AI tasks

    @Test func ravisPhoneTranslatesSummarisesAndTriagesForUs() async throws {
        let (service, _) = makeService()
        #expect(await eventually { peer(service, "Ravi") != nil })
        let translated = try #require(await service.requestRemote(.translate, prompt: "water", targetLanguage: "hi"))
        #expect(translated.text == "पानी")
        #expect(translated.answeredBy.contains("Ravi"))
        let triage = try #require(await service.requestRemote(.triage, prompt: "two kids trapped under the collapsed wall, one bleeding"))
        #expect(triage.triage?.category == .trapped)
        #expect((triage.triage?.priority ?? .low) >= .high)
        let summary = try #require(await service.requestRemote(.summarize, prompt: "Asha: road blocked\nKabir: power out\nRavi: water at hall\nMeera: help"))
        #expect(summary.text.hasPrefix("• Asha: road blocked"))
    }

    @Test func remoteTasksTimeOutCleanlyWhenNobodyCanHelp() async {
        let (service, _) = makeService()
        #expect(await service.requestRemote(.translate, prompt: "water", targetLanguage: "hi", timeout: 1) == nil) // no peers yet
        #expect(await eventually { peer(service, "Ravi") != nil })
        service.setDemoLinks(enabled: false)
        #expect(await eventually { peer(service, "Ravi") == nil })
        #expect(await service.requestRemote(.summarize, prompt: "x", timeout: 1) == nil)
    }

    // MARK: #10 Catch-up

    @Test func catchUpLeadsWithTheSOSAndIsSummarisedByRavi() async throws {
        let (service, _) = makeService()
        // Meera's SOS at ~14 s, Asha's fire report at ~22 s.
        #expect(await eventually(45) { heard(service, "Fire near the market") })
        let (summary, abstract) = await service.catchUp(key: ConversationKey.nearby)
        #expect(summary.highlights.first?.kind == .sos)
        #expect(summary.highlights.first?.text.contains("trapped under rubble") == true)
        #expect(summary.overview.contains("1 SOS"))
        #expect(summary.messageCount >= 4)
        #expect(abstract?.contains("summarised by Ravi") == true)
        // Opening the conversation marks it read, but catch-up from inside it still covers what came
        // before this visit…
        service.openConversationKey = ConversationKey.nearby
        service.markRead(key: ConversationKey.nearby)
        #expect(await service.catchUp(key: ConversationKey.nearby).summary.messageCount >= 4)
        // …and after leaving and coming back, only what's new since then.
        service.openConversationKey = nil
        service.openConversationKey = ConversationKey.nearby
        service.markRead(key: ConversationKey.nearby)
        #expect(await service.catchUp(key: ConversationKey.nearby).summary.highlights.allSatisfy { !$0.text.contains("trapped under rubble") })
    }

    // MARK: #11 Credibility

    @Test func digestLabelsCorroboratedAndSingleReports() async throws {
        let (service, _) = makeService()
        // Fire: Asha (~22 s) and Kabir (~30 s) both report it.
        #expect(await eventually(50) { heard(service, "Confirming fire") })
        await service.refreshDigest()
        let fire = try #require(service.digest?.items.first { $0.category == .fire })
        #expect(fire.reporters == 2)
        #expect(service.digestCredibility[fire.id] == .corroborated)
        let trapped = try #require(service.digest?.items.first { $0.category == .trapped })
        #expect(service.digestCredibility[trapped.id] == .unverified)
        // Someone nearby calls it a false alarm.
        service.demoBroadcast(.text("False alarm at the market, the fire is out, it was only a bonfire"), from: "Asha")
        #expect(await eventually { heard(service, "False alarm") })
        await service.refreshDigest()
        let disputed = try #require(service.digest?.items.first { $0.category == .fire })
        #expect(service.digestCredibility[disputed.id] == .disputed)
    }

    // MARK: #12 Spam

    @Test func scamsAndFloodsAreHiddenButPleasForHelpAreNot() async throws {
        let (service, _) = makeService()
        #expect(await eventually { peer(service, "Kabir") != nil })
        service.demoBroadcast(.text("FREE MONEY for flood victims!! click here bit.ly/relief-cash"), from: "Kabir")
        for _ in 0..<4 { service.demoBroadcast(.text("Help! I'm trapped in the basement"), from: "Asha") }
        #expect(await eventually { service.spamHiddenCount == 1 })
        let scam = try #require(messages(service, ConversationKey.nearby).first { $0.previewText.contains("FREE MONEY") })
        #expect(scam.isSpam)
        let pleas = messages(service, ConversationKey.nearby).filter { $0.previewText.contains("trapped in the basement") }
        #expect(pleas.count == 4)
        #expect(pleas.allSatisfy { !$0.isSpam })
        #expect(!service.localMessages().contains { $0.text.contains("FREE MONEY") })
        // Reporting a device also blocks it: nothing it sends next is shown at all.
        let kabir = try #require(peer(service, "Kabir"))
        service.trust.report(kabir.peerID)
        service.demoBroadcast(.text("anyone at the hall?"), from: "Kabir")
        service.demoBroadcast(.text("is the east route open?"), from: "Asha")
        #expect(await eventually { heard(service, "east route open") })
        #expect(!heard(service, "anyone at the hall"))
    }

    // MARK: #13 Auto-reply

    @Test func unansweredSafetyCheckGetsAFactsOnlyAutoReply() async throws {
        let (service, _) = makeService()
        service.autoReplyDelay = 2
        #expect(await eventually { peer(service, "Kabir") != nil && peer(service, "Asha") != nil })
        let key = try #require(service.createGroup(name: "Family", members: [peer(service, "Kabir")!.peerID]))
        // Kabir asks "are you safe?" ~3 s after joining; we don't answer.
        #expect(await eventually(20) { messages(service, key).contains { if case .safetyCheck = $0.content { return !$0.isOutgoing }; return false } })
        #expect(await eventually(10) { messages(service, key).contains { $0.isOutgoing && $0.previewText.hasPrefix("Auto-reply:") } })
        let reply = try #require(messages(service, key).first { $0.previewText.hasPrefix("Auto-reply:") })
        #expect(reply.previewText.contains("hasn't answered yet"))
        #expect(!reply.previewText.lowercased().contains("i'm safe")) // never claims safety on the user's behalf
    }

    @Test func answeringInTimeOrTurningItOffPreventsTheAutoReply() async throws {
        let (service, _) = makeService()
        service.autoReplyDelay = 3
        #expect(await eventually { peer(service, "Kabir") != nil })
        let key = try #require(service.createGroup(name: "Family", members: [peer(service, "Kabir")!.peerID]))
        #expect(await eventually(20) { messages(service, key).contains { if case .safetyCheck = $0.content { return !$0.isOutgoing }; return false } })
        let checks = messages(service, key).compactMap { m -> SafetyCheck? in
            if case .safetyCheck(let c)? = m.content, !m.isOutgoing { return c }
            return nil
        }
        let check = try #require(checks.first)
        _ = service.sendCheckIn(.safe, inReplyTo: check.requestID)
        try await Task.sleep(nanoseconds: 5_000_000_000)
        #expect(!messages(service, key).contains { $0.previewText.hasPrefix("Auto-reply:") })

        let (off, _) = makeService()
        off.settings.autoReplySafetyChecks = false
        off.autoReplyDelay = 1
        #expect(await eventually { peer(off, "Kabir") != nil })
        let offKey = try #require(off.createGroup(name: "Family", members: [peer(off, "Kabir")!.peerID]))
        #expect(await eventually(20) { messages(off, offKey).contains { if case .safetyCheck = $0.content { return !$0.isOutgoing }; return false } })
        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(!messages(off, offKey).contains { $0.previewText.hasPrefix("Auto-reply:") })
    }

    // MARK: Roles

    @Test func responderRolesAreAdvertisedAndMatched() async throws {
        let (service, _) = makeService()
        #expect(!service.node.capabilities.contains(.medic))
        service.settings.isMedic = true
        service.applySettingsChange()
        #expect(service.node.capabilities.contains(.medic))
        #expect(!service.node.capabilities.contains(.rescuer))
        service.settings.isRescuer = true
        service.applySettingsChange()
        #expect(service.node.capabilities.isSuperset(of: [.medic, .rescuer]))
        let me = PeerInfo.selfStub(service.node)
        #expect(ResponderMatcher.suggest(for: HeuristicTriage.triage("he collapsed and isn't breathing"), among: [me]).count == 1)
        service.settings.isMedic = false
        service.settings.isRescuer = false
        service.applySettingsChange()
        #expect(service.node.capabilities.isDisjoint(with: [.medic, .rescuer]))
    }
}
