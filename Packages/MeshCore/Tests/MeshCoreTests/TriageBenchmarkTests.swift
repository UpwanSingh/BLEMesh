import Foundation
import Testing
@testable import MeshCore

/// #8: a labelled benchmark for offline SOS triage. Hand-written examples (English, Hindi,
/// Hinglish), each with the category and minimum priority a rescuer would expect. The accuracy
/// targets are enforced so regressions fail the build. This is a starting dataset — it should be
/// extended with real (anonymised) field messages.
@Suite("Triage benchmark")
struct TriageBenchmarkTests {
    typealias C = SOSTriage.Category
    typealias P = SOSTriage.Priority

    /// (message, expected category, minimum priority, life-threatening?)
    
    @Test func categoryAccuracyAndCriticalRecallMeetTargets() {
        var correctCategory = 0, criticalTotal = 0, criticalCaught = 0
        var priorityOK = 0
        var misses: [String] = []
        for (text, category, minPriority, lifeThreatening) in TriageBenchmark.tuning {
            let t = HeuristicTriage.triage(text)
            if t.category == category { correctCategory += 1 } else { misses.append("CAT \(text) → \(t.category) (want \(category))") }
            if t.priority >= minPriority { priorityOK += 1 } else { misses.append("PRI \(text) → \(t.priority) (want ≥ \(minPriority))") }
            if lifeThreatening {
                criticalTotal += 1
                if t.priority == .critical { criticalCaught += 1 } else { misses.append("CRIT \(text) → \(t.priority)") }
            }
        }
        let n = Double(TriageBenchmark.tuning.count)
        let categoryAccuracy = Double(correctCategory) / n
        let priorityAccuracy = Double(priorityOK) / n
        let criticalRecall = Double(criticalCaught) / Double(criticalTotal)
        print("TRIAGE n=\(TriageBenchmark.tuning.count) category=\(categoryAccuracy) priority=\(priorityAccuracy) criticalRecall=\(criticalRecall)")
        for miss in misses { print("TRIAGE miss: \(miss)") }
        #expect(categoryAccuracy >= 0.85)
        #expect(priorityAccuracy >= 0.85)
        #expect(criticalRecall >= 0.95, "life-threatening messages must almost never be under-ranked")
    }

    /// Held-out set: written separately and never used to tune the rules. Its accuracy is the
    /// honest estimate; the targets are lower than for the tuning set above.
    
    @Test func heldOutAccuracy() {
        var category = 0, priority = 0, crit = 0, critTotal = 0
        for (text, wantCategory, minPriority, lifeThreatening) in TriageBenchmark.heldOutV1 {
            let t = HeuristicTriage.triage(text)
            if t.category == wantCategory { category += 1 } else { print("HELDOUT miss CAT \(text) → \(t.category)") }
            if t.priority >= minPriority { priority += 1 } else { print("HELDOUT miss PRI \(text) → \(t.priority)") }
            if lifeThreatening { critTotal += 1; if t.priority == .critical { crit += 1 } }
        }
        let n = Double(TriageBenchmark.heldOutV1.count)
        print("HELDOUT n=\(TriageBenchmark.heldOutV1.count) category=\(Double(category) / n) priority=\(Double(priority) / n) criticalRecall=\(Double(crit) / Double(critTotal))")
        #expect(Double(category) / n >= 0.75)
        #expect(Double(crit) / Double(critTotal) >= 0.85)
    }

    /// Second held-out set, written after the vocabulary expansion and never used for tuning.
    /// This is the number to quote.
    
    @Test func heldOutV2RulesOnlyBaseline() {
        var category = 0, priority = 0, crit = 0, critTotal = 0
        for (text, wantCategory, minPriority, lifeThreatening) in TriageBenchmark.heldOutV2 {
            let t = HeuristicTriage.triage(text)
            if t.category == wantCategory { category += 1 } else { print("HELDOUT2 miss CAT \(text) → \(t.category)") }
            if t.priority >= minPriority { priority += 1 } else { print("HELDOUT2 miss PRI \(text) → \(t.priority)") }
            if lifeThreatening { critTotal += 1; if t.priority == .critical { crit += 1 } }
        }
        let n = Double(TriageBenchmark.heldOutV2.count)
        print("HELDOUT2 n=\(TriageBenchmark.heldOutV2.count) category=\(Double(category) / n) priority=\(Double(priority) / n) criticalRecall=\(Double(crit) / Double(critTotal))")
    }

    @Test func nonEmergenciesAreNeverCritical() {
        for (text, category, _, _) in TriageBenchmark.tuning where category == .other {
            #expect(HeuristicTriage.triage(text).priority < .high, "\(text)")
        }
    }
}

@Suite("Triage approaches compared (honest, held-out v2)")
struct TriageComparisonTests {
    @Test func compareRulesEmbeddingAndHybrid() throws {
        let embedding = try #require(EmbeddingTriage())
        let rules = TriageBenchmark.score(TriageBenchmark.heldOutV2, with: HeuristicTriage.triage)
        let sos = TriageBenchmark.score(TriageBenchmark.heldOutV2, with: HeuristicTriage.triageSOS)
        let knn = TriageBenchmark.score(TriageBenchmark.heldOutV2) { text in
            let p = embedding.predict(text)!
            return SOSTriage(priority: p.priority, category: p.category, peopleAffected: nil, summary: text, locationHints: [], source: "embedding")
        }
        let hybrid = TriageBenchmark.score(TriageBenchmark.heldOutV2) { HybridTriage.triage($0, embedding: embedding) }
        for (name, s) in [("rules", rules), ("rules+SOS floor", sos), ("embedding kNN", knn), ("hybrid", hybrid)] {
            print("COMPARE \(name): category=\(s.categoryAccuracy) priority=\(s.priorityAccuracy) criticalRecall=\(s.criticalRecall)")
        }
        // Regression guards at the measured level (held-out v2 is never used for tuning).
        #expect(hybrid.categoryAccuracy >= 0.75)
        #expect(hybrid.priorityAccuracy >= 0.7)
        #expect(hybrid.criticalRecall >= 0.5)
        #expect(hybrid.categoryAccuracy > rules.categoryAccuracy)
        let sosHybrid = TriageBenchmark.score(TriageBenchmark.heldOutV2) { HybridTriage.triageSOS($0, embedding: embedding) }
        #expect(sosHybrid.priorityAccuracy >= hybrid.priorityAccuracy)
    }
}
