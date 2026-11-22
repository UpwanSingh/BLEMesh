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
    /// Answer with provenance. `local` are recent mesh messages for "what's happening here" questions.
    func answer(_ question: String, local: [LocalMessage]) async -> SafeAnswer
    func triage(_ text: String) async -> SOSTriage
    func overview(for digest: AreaDigest, recentTexts: [String]) async -> String
    /// Translate with the generative model (nil when this phone can't).
    func translate(_ text: String, to language: String) async -> String?
    /// Summarise a transcript (generative when possible, extractive otherwise).
    func summarize(_ transcript: String) async -> String
}

extension AIEngine {
    /// Extractive fallback: the most informative lines, by the catch-up scorer.
    static func extractiveSummary(_ transcript: String) -> String {
        let lines = transcript.split(separator: "\n").map(String.init)
        let messages = lines.map { line -> LocalMessage in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            return LocalMessage(sender: .broadcast, senderName: parts.first ?? "", text: parts.count > 1 ? parts[1] : line, date: Date())
        }
        let picked = CatchUpBuilder.build(messages, since: .distantPast, limit: 3).highlights
        return picked.map { "• \($0.senderName): \($0.text.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
    }
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

    func answer(_ question: String, local: [LocalMessage]) async -> SafeAnswer {
        Self.offlineAnswer(question, local: local)
    }

    /// Safety checks first, then local messages (for local questions), then the offline library.
    static func offlineAnswer(_ question: String, local: [LocalMessage]) -> SafeAnswer {
        if AnswerSafety.concern(in: question) != nil {
            return AnswerSafety.compose(question: question, generated: nil, references: EmergencyKnowledge.search(question))
        }
        if LocalRetriever.isLocalQuestion(question) {
            let hits = LocalRetriever.search(question, in: local, now: Date())
            if let text = LocalRetriever.answer(question, hits: hits, now: Date()) {
                return SafeAnswer(text: text, confidence: .medium,
                                  sources: hits.map { "\($0.message.senderName)'s message" })
            }
        }
        return AnswerSafety.compose(question: question, generated: nil, references: EmergencyKnowledge.search(question))
    }

    /// Keyword rules + on-device sentence-embedding neighbours, with the SOS "never below high" floor.
    func triage(_ text: String) async -> SOSTriage { HybridTriage.triageSOS(text, embedding: HybridTriage.shared) }

    func overview(for digest: AreaDigest, recentTexts: [String]) async -> String { digest.overview }

    func translate(_ text: String, to language: String) async -> String? { nil }

    func summarize(_ transcript: String) async -> String { Self.extractiveSummary(transcript) }
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
    /// After a generation failure (e.g. model assets missing) we stop claiming the capability for a
    /// while, so this phone doesn't advertise itself as an AI helper it can't be.
    private var unavailableUntil: Date?

    var hasGenerativeModel: Bool { Self.isSupported && (unavailableUntil.map { Date() >= $0 } ?? true) }

    private func noteFailure(_ error: Error) {
        unavailableUntil = Date().addingTimeInterval(600)
        MeshLogger.app.error("On-device model failed, using offline fallback for 10 min: \(error.localizedDescription, privacy: .public)")
    }

    var statusDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return hasGenerativeModel ? "Apple on-device model (private, offline)"
                                      : "On-device model failed to run — using the offline guide for now"
        case .unavailable(let reason): return "On-device model unavailable: \(String(describing: reason))"
        }
    }

    private static let answerInstructions = """
    You are an offline emergency and general helper inside a mesh messaging app used when there \
    is no internet. Answer in at most 6 short sentences or numbered steps. Be practical and calm. \
    For medical or safety topics, follow the provided reference guidance exactly, never invent \
    dosages or procedures, and end by recommending professional help. If unsure, say so.
    """

    func answer(_ question: String, local: [LocalMessage]) async -> SafeAnswer {
        // Safety-sensitive questions are answered by fixed, vetted text — never generated.
        guard hasGenerativeModel, AnswerSafety.concern(in: question) == nil else {
            return OfflineKnowledgeEngine.offlineAnswer(question, local: local)
        }
        let references = EmergencyKnowledge.search(question)
        let hits = LocalRetriever.isLocalQuestion(question) ? LocalRetriever.search(question, in: local, now: Date()) : []
        var prompt = ""
        if !references.isEmpty { prompt += "Reference guidance:\n" + references.map(\.text).joined(separator: "\n\n") + "\n\n" }
        if !hits.isEmpty {
            prompt += "Recent messages from people nearby (unverified):\n"
                + hits.map { "- \($0.message.senderName): \($0.message.text)" }.joined(separator: "\n") + "\n\n"
        }
        prompt += "Question: \(question)"
        do {
            let session = LanguageModelSession(instructions: Self.answerInstructions)
            let response = try await session.respond(to: prompt)
            return AnswerSafety.compose(question: question, generated: response.content, references: references,
                                        localSources: hits.map { "\($0.message.senderName)'s message" })
        } catch {
            noteFailure(error)
            return OfflineKnowledgeEngine.offlineAnswer(question, local: local)
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

    /// The model's own assessment, without the offline floor (used for benchmarking).
    func modelTriage(_ text: String) async -> SOSTriage? {
        guard Self.isSupported else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.triageInstructions)
            let result = try await session.respond(to: text, generating: TriageOutput.self).content
            guard let priority = SOSTriage.Priority.allCases.first(where: { $0.label.lowercased() == result.priority }),
                  let category = SOSTriage.Category(rawValue: result.category) else { return nil }
            return SOSTriage(priority: priority, category: category,
                             peopleAffected: result.peopleAffected > 0 ? result.peopleAffected : nil,
                             summary: result.summary, locationHints: Array(result.locations.prefix(3)), source: "llm")
        } catch {
            noteFailure(error)
            return nil
        }
    }

    static let triageInstructions = """
    Classify emergency messages for rescuers. Life-threatening situations (not breathing, \
    unconscious, heavy bleeding, fire, drowning, trapped, weapons, overdose, falls from height) are critical.
    """

    func triage(_ text: String) async -> SOSTriage {
        let heuristic = HybridTriage.triageSOS(text, embedding: HybridTriage.shared)
        guard hasGenerativeModel else { return heuristic }
        do {
            let session = LanguageModelSession(instructions: Self.triageInstructions)
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
            noteFailure(error)
            return heuristic
        }
    }

    func translate(_ text: String, to language: String) async -> String? {
        guard hasGenerativeModel else { return nil }
        let name = Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language
        do {
            let session = LanguageModelSession(instructions: "Translate the user's text into \(name). Reply with the translation only.")
            let text = try await session.respond(to: text).content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            noteFailure(error)
            return nil
        }
    }

    func summarize(_ transcript: String) async -> String {
        guard hasGenerativeModel else { return Self.extractiveSummary(transcript) }
        do {
            let session = LanguageModelSession(instructions: """
            Summarise these chat messages in at most 3 short bullet points: urgent needs first, then \
            questions addressed to the reader, then other news. Use only what's in the messages.
            """)
            let text = try await session.respond(to: transcript).content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? Self.extractiveSummary(transcript) : text
        } catch {
            noteFailure(error)
            return Self.extractiveSummary(transcript)
        }
    }

    func overview(for digest: AreaDigest, recentTexts: [String]) async -> String {
        guard hasGenerativeModel, !digest.items.isEmpty else { return digest.overview }
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
