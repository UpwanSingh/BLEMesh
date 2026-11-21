import Foundation
import MeshCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The intelligence features the app needs. Implemented by Apple's on-device model when the
/// device supports it, with a deterministic offline fallback otherwise. Nothing leaves the device.
@MainActor
protocol AIEngine: AnyObject {
    /// True when a generative on-device model is ready (the device can help others).
    var hasGenerativeModel: Bool { get }
    /// Human-readable engine status for Settings / diagnostics.
    var statusDescription: String { get }
    func answer(_ question: String) async -> String
    func triage(_ text: String) async -> SOSTriage
    func overview(for digest: AreaDigest, recentTexts: [String]) async -> String
}

/// Picks the best available engine at runtime.
@MainActor
enum AIEngineFactory {
    static func make() -> AIEngine {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsEngine.isSupported {
            return FoundationModelsEngine()
        }
        #endif
        return OfflineKnowledgeEngine()
    }
}

/// Always-available engine: vetted knowledge library + heuristic triage/digest.
@MainActor
final class OfflineKnowledgeEngine: AIEngine {
    var hasGenerativeModel: Bool { false }
    var statusDescription: String { "Offline guidance library (no on-device model on this phone)" }

    func answer(_ question: String) async -> String {
        EmergencyKnowledge.answer(question)
            ?? "I don't have offline guidance for that. Try asking someone nearby with an AI-capable phone, or describe the emergency (bleeding, burn, fracture, fire, flood…)."
    }

    func triage(_ text: String) async -> SOSTriage { HeuristicTriage.triage(text) }

    func overview(for digest: AreaDigest, recentTexts: [String]) async -> String { digest.overview }
}

#if canImport(FoundationModels)
/// Apple Intelligence on-device foundation model (iOS 26+). Grounded with the offline library
/// for medical/safety questions and constrained to structured output for triage.
@available(iOS 26.0, *)
@MainActor
final class FoundationModelsEngine: AIEngine {
    static var isSupported: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private let fallback = OfflineKnowledgeEngine()

    var hasGenerativeModel: Bool { Self.isSupported }

    var statusDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Apple on-device model (private, offline)"
        case .unavailable(let reason): return "On-device model unavailable: \(String(describing: reason))"
        }
    }

    private static let answerInstructions = """
    You are an offline emergency and general helper inside a mesh messaging app used when there \
    is no internet. Answer in at most 6 short sentences or numbered steps. Be practical and calm. \
    For medical or safety topics, follow the provided reference guidance exactly, never invent \
    dosages or procedures, and end by recommending professional help. If unsure, say so.
    """

    func answer(_ question: String) async -> String {
        guard Self.isSupported else { return await fallback.answer(question) }
        let references = EmergencyKnowledge.search(question).map(\.text).joined(separator: "\n\n")
        let prompt = references.isEmpty
            ? question
            : "Reference guidance:\n\(references)\n\nQuestion: \(question)"
        do {
            let session = LanguageModelSession(instructions: Self.answerInstructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return await fallback.answer(question) }
            return references.isEmpty ? text : text + "\n\n" + EmergencyKnowledge.disclaimer
        } catch {
            MeshLogger.app.error("On-device answer failed: \(error.localizedDescription, privacy: .public)")
            return await fallback.answer(question)
        }
    }

    @Generable
    struct TriageOutput {
        @Guide(description: "How urgent the situation is", .anyOf(["low", "medium", "high", "critical"]))
        var priority: String
        @Guide(description: "Type of emergency", .anyOf(["medical", "fire", "flood", "trapped", "violence", "missingPerson", "supplies", "other"]))
        var category: String
        @Guide(description: "Number of people affected if stated, otherwise 0")
        var peopleAffected: Int
        @Guide(description: "One-line summary for rescuers, at most 12 words")
        var summary: String
        @Guide(description: "Place names or landmarks mentioned, empty if none")
        var locations: [String]
    }

    func triage(_ text: String) async -> SOSTriage {
        let heuristic = HeuristicTriage.triage(text)
        guard Self.isSupported else { return heuristic }
        do {
            let session = LanguageModelSession(instructions: """
            Classify emergency messages for rescuers. Life-threatening situations (not breathing, \
            unconscious, heavy bleeding, fire, drowning, trapped, weapons) are critical.
            """)
            let result = try await session.respond(to: text, generating: TriageOutput.self).content
            let priority = SOSTriage.Priority.allCases.first { $0.label.lowercased() == result.priority } ?? heuristic.priority
            let category = SOSTriage.Category(rawValue: result.category) ?? heuristic.category
            // Safety floor: never rank lower than the keyword heuristic.
            return SOSTriage(
                priority: max(priority, heuristic.priority),
                category: category,
                peopleAffected: result.peopleAffected > 0 ? result.peopleAffected : heuristic.peopleAffected,
                summary: result.summary.isEmpty ? heuristic.summary : result.summary,
                locationHints: result.locations.isEmpty ? heuristic.locationHints : Array(result.locations.prefix(3)),
                source: "llm"
            )
        } catch {
            MeshLogger.app.error("On-device triage failed: \(error.localizedDescription, privacy: .public)")
            return heuristic
        }
    }

    func overview(for digest: AreaDigest, recentTexts: [String]) async -> String {
        guard Self.isSupported, !digest.items.isEmpty else { return digest.overview }
        let facts = digest.items.prefix(6).map { item in
            "- \(item.priority.label) \(item.category.label): \(item.headline) (\(item.reporters) reporter(s))"
                + (item.locations.isEmpty ? "" : " at \(item.locations.joined(separator: ", "))")
        }.joined(separator: "\n")
        do {
            let session = LanguageModelSession(instructions: """
            Write a 2–3 sentence situational summary for people in the area, most urgent first. \
            Use only the facts given. Mention places. Note when something has a single unverified report.
            """)
            let response = try await session.respond(to: "Reports:\n\(facts)")
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? digest.overview : text
        } catch {
            return digest.overview
        }
    }
}
#endif
