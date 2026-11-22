import Foundation
import Testing
import MeshCore
@testable import BLEMesh

/// Measures Apple's on-device model on the held-out triage set (only where the model is available,
/// e.g. Apple-silicon simulators with Apple Intelligence enabled, or iPhone 15 Pro and later).
@MainActor
@Suite("On-device model triage (held-out v2)")
struct LLMTriageBenchmarkTests {
    @Test func measureModelTriage() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), FoundationModelsEngine.isSupported else {
            print("LLMTRIAGE skipped: no on-device model here")
            return
        }
        let engine = FoundationModelsEngine()
        var raw: [String: SOSTriage] = [:], combined: [String: SOSTriage] = [:]
        for example in TriageBenchmark.heldOutV2 {
            raw[example.text] = await engine.modelTriage(example.text)
            combined[example.text] = await engine.triage(example.text)
        }
        let rawScore = TriageBenchmark.score(TriageBenchmark.heldOutV2) {
            raw[$0] ?? SOSTriage(priority: .low, category: .other, peopleAffected: nil, summary: "", locationHints: [], source: "none")
        }
        let combinedScore = TriageBenchmark.score(TriageBenchmark.heldOutV2) { combined[$0]! }
        print("LLMTRIAGE model only: category=\(rawScore.categoryAccuracy) priority=\(rawScore.priorityAccuracy) criticalRecall=\(rawScore.criticalRecall)")
        print("LLMTRIAGE model+floor: category=\(combinedScore.categoryAccuracy) priority=\(combinedScore.priorityAccuracy) criticalRecall=\(combinedScore.criticalRecall)")
        // What ships (model + offline floor) must be at least as good as the offline path alone.
        let offline = TriageBenchmark.score(TriageBenchmark.heldOutV2) { HybridTriage.triageSOS($0, embedding: HybridTriage.shared) }
        #expect(combinedScore.priorityAccuracy >= offline.priorityAccuracy)
        #expect(combinedScore.criticalRecall >= offline.criticalRecall)
        #endif
    }
}
