import Foundation
import Testing
@testable import MeshCore

@Suite("SOS triage (heuristic)")
struct TriageTests {
    @Test func criticalMedical() {
        let t = HeuristicTriage.triage("Help! My father fell and is unconscious near the old temple gate")
        #expect(t.priority == .critical)
        #expect(t.category == .medical)
        #expect(t.locationHints.first == "the old temple gate")
        #expect(t.source == "heuristic")
    }

    @Test func fireIsCritical() {
        let t = HeuristicTriage.triage("Fire in building 4, smoke everywhere, 3 people on the roof")
        #expect(t.category == .fire)
        #expect(t.priority == .critical)
        #expect(t.peopleAffected == 3)
    }

    @Test func trappedPeopleCountWords() {
        let t = HeuristicTriage.triage("two children trapped under rubble behind the school")
        #expect(t.category == .trapped)
        #expect(t.priority == .critical)
        #expect(t.peopleAffected == 2)
        #expect(t.locationHints.contains("the school"))
    }

    @Test func suppliesAreLowPriority() {
        let t = HeuristicTriage.triage("we need drinking water and food at the shelter")
        #expect(t.category == .supplies)
        #expect(t.priority == .low)
    }

    @Test func manyPeopleRaisePriority() {
        let t = HeuristicTriage.triage("40 people need food and blankets at the stadium")
        #expect(t.peopleAffected == 40)
        #expect(t.priority == .medium) // low bumped one level by headcount
    }

    @Test func hindiKeywords() {
        let t = HeuristicTriage.triage("बाढ़ आ गई है, मदद चाहिए")
        #expect(t.category == .flood)
    }

    @Test func summaryIsShortAndPrefixed() {
        let long = "Bleeding heavily from the leg after the accident on the highway near exit 12, please send an ambulance as fast as possible because it is getting worse"
        let t = HeuristicTriage.triage(long)
        #expect(t.summary.hasPrefix("Medical: "))
        #expect(t.summary.count <= 110)
    }

    @Test func chatterIsUnclassified() {
        let t = HeuristicTriage.triage("anyone up for chai later?")
        #expect(t.category == .other)
        #expect(t.priority == .low)
    }
}

@Suite("Area digest")
struct DigestTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let p1 = MeshIdentity().peerID, p2 = MeshIdentity().peerID, p3 = MeshIdentity().peerID

    @Test func clustersCorroboratedReportsAndRanksByPriority() {
        let inputs = [
            DigestInput(sender: p1, text: "Fire near the market, smoke everywhere", date: now.addingTimeInterval(-600)),
            DigestInput(sender: p2, text: "big fire near the market!!", date: now.addingTimeInterval(-300)),
            DigestInput(sender: p3, text: "need water at the shelter", date: now.addingTimeInterval(-200)),
            DigestInput(sender: p3, text: "anyone up for chai?", date: now.addingTimeInterval(-100)),
            DigestInput(sender: p1, text: "flood near river road", date: now.addingTimeInterval(-7200)), // outside window
        ]
        let digest = DigestBuilder.build(from: inputs, now: now)
        #expect(digest.messageCount == 4)
        #expect(digest.items.count == 2)
        #expect(digest.items[0].category == .fire)
        #expect(digest.items[0].reporters == 2)
        #expect(digest.items[0].priority == .critical)
        #expect(digest.items[1].category == .supplies)
        #expect(digest.overview.contains("critical"))
        #expect(digest.overview.contains("Fire near the market (2 reports)"))
    }

    @Test func emptyAndQuietDigests() {
        #expect(DigestBuilder.build(from: [], now: now).overview == "No recent activity nearby.")
        let quiet = DigestBuilder.build(from: [DigestInput(sender: p1, text: "hello", date: now)], now: now)
        #expect(quiet.items.isEmpty)
        #expect(quiet.overview.contains("no emergencies"))
    }

    @Test func usesProvidedTriage() {
        let llm = SOSTriage(priority: .critical, category: .violence, peopleAffected: nil,
                            summary: "Violence: crowd crush at gate 3", locationHints: ["gate 3"], source: "llm")
        let digest = DigestBuilder.build(from: [DigestInput(sender: p1, text: "something", date: now, triage: llm)], now: now)
        #expect(digest.items.first?.headline == "Violence: crowd crush at gate 3")
    }
}

@Suite("Emergency knowledge")
struct KnowledgeTests {
    @Test func findsRelevantGuidance() {
        #expect(EmergencyKnowledge.search("my friend has a bad burn on his arm").first?.id == "burns")
        #expect(EmergencyKnowledge.search("he is not breathing what do i do").first?.id == "cpr")
        #expect(EmergencyKnowledge.search("water is rising in our street").first?.id == "flood")
        #expect(EmergencyKnowledge.search("bitten by a snake").first?.id == "snake")
    }

    @Test func answersIncludeStepsAndDisclaimer() throws {
        let answer = try #require(EmergencyKnowledge.answer("how to stop bleeding"))
        #expect(answer.contains("Press firmly"))
        #expect(answer.contains(EmergencyKnowledge.disclaimer))
    }

    @Test func unknownTopicsReturnNothing() {
        #expect(EmergencyKnowledge.answer("what's the cricket score") == nil)
    }

    @Test func everyEntryIsWellFormed() {
        #expect(Set(EmergencyKnowledge.entries.map(\.id)).count == EmergencyKnowledge.entries.count)
        for entry in EmergencyKnowledge.entries {
            #expect(!entry.keywords.isEmpty && entry.steps.count >= 3, "\(entry.id)")
        }
    }
}
