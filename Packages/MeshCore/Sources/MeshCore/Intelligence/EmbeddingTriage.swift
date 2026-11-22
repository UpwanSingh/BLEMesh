import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Semantic triage: compares a message's on-device sentence embedding with labelled examples
/// (k-nearest-neighbours) so situations phrased in new ways are still recognised. English only
/// (no on-device Hindi sentence embedding); combined with the keyword rules in `HybridTriage`.
public final class EmbeddingTriage: @unchecked Sendable {
    #if canImport(NaturalLanguage)
    private let embedding: NLEmbedding
    #endif
    private let exemplars: [(vector: [Double], example: TriageBenchmark.Example)]
    public let k: Int

    public init?(examples: [TriageBenchmark.Example] = TriageBenchmark.training, k: Int = 5) {
        #if canImport(NaturalLanguage)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        self.embedding = embedding
        self.exemplars = examples.compactMap { example in
            embedding.vector(for: example.text.lowercased()).map { (Self.normalize($0), example) }
        }
        self.k = k
        guard !exemplars.isEmpty else { return nil }
        #else
        return nil
        #endif
    }

    public struct Prediction: Sendable {
        public var category: SOSTriage.Category
        public var priority: SOSTriage.Priority
        /// Share of the neighbour weight agreeing on the category (0–1).
        public var confidence: Double
    }

    public func predict(_ text: String) -> Prediction? {
        #if canImport(NaturalLanguage)
        guard let raw = embedding.vector(for: text.lowercased()) else { return nil }
        let v = Self.normalize(raw)
        let neighbours = exemplars
            .map { (similarity: zip(v, $0.vector).reduce(0) { $0 + $1.0 * $1.1 }, example: $0.example) }
            .sorted { $0.similarity > $1.similarity }
            .prefix(k)
        var votes: [SOSTriage.Category: Double] = [:]
        for n in neighbours { votes[n.example.category, default: 0] += max(0, n.similarity) }
        guard let (category, weight) = votes.max(by: { $0.value < $1.value }) else { return nil }
        let total = votes.values.reduce(0, +)
        // Priority: the most severe among the agreeing neighbours (err towards urgency).
        let priority = neighbours.filter { $0.example.category == category }.map(\.example.minPriority).max() ?? .medium
        return Prediction(category: category, priority: priority, confidence: total > 0 ? weight / total : 0)
        #else
        return nil
        #endif
    }

    private static func normalize(_ v: [Double]) -> [Double] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }
}

/// Keyword rules + semantic neighbours. Rules win when they're confident (an explicit keyword);
/// otherwise the embedding decides the category. Priority takes the more urgent of the two.
public enum HybridTriage {
    public static func triage(_ text: String, embedding: EmbeddingTriage?) -> SOSTriage {
        var rules = HeuristicTriage.triage(text)
        guard let prediction = embedding?.predict(text) else { return rules }
        if rules.category == .other && prediction.category != .other && prediction.confidence >= 0.5 {
            rules.category = prediction.category
            rules.summary = HeuristicTriage.summarize(text, category: prediction.category, people: rules.peopleAffected)
        }
        if prediction.category == rules.category && prediction.confidence >= 0.5 {
            rules.priority = max(rules.priority, prediction.priority)
        }
        rules.source = "heuristic+embedding"
        return rules
    }

    /// For messages deliberately sent as SOS: never below "high" unless clearly a supplies request.
    public static func triageSOS(_ text: String, embedding: EmbeddingTriage?) -> SOSTriage {
        var result = triage(text, embedding: embedding)
        if result.category != .supplies && result.priority < .high { result.priority = .high }
        return result
    }

    /// Shared instance (building the exemplar index embeds ~90 sentences once).
    public static let shared: EmbeddingTriage? = EmbeddingTriage()
}
