import Foundation

/// An answer shown to the user, with its provenance and how much to trust it.
public struct SafeAnswer: Equatable, Sendable {
    public enum Confidence: String, Sendable, Comparable {
        /// Refused or replaced for safety.
        case refused
        /// Generated without any reference material.
        case low
        /// Generated, grounded in the offline library or local messages.
        case medium
        /// Taken directly from the offline library.
        case high

        private var rank: Int { ["refused": 0, "low": 1, "medium": 2, "high": 3][rawValue]! }
        public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }

        public var label: String {
            switch self {
            case .refused: return "Safety response"
            case .low: return "Low confidence — no reference found"
            case .medium: return "Based on references"
            case .high: return "From the offline guide"
            }
        }
    }

    public var text: String
    public var confidence: Confidence
    /// Titles of library entries / local messages the answer is based on.
    public var sources: [String]
    /// Why the safety layer intervened, if it did.
    public var safetyNote: String?
    /// True only when a generative model actually produced the text (not a fallback).
    public var generatedByModel: Bool = false

    public init(text: String, confidence: Confidence, sources: [String], safetyNote: String? = nil, generatedByModel: Bool = false) {
        self.text = text
        self.confidence = confidence
        self.sources = sources
        self.safetyNote = safetyNote
        self.generatedByModel = generatedByModel
    }

    /// Text with a compact provenance footer, for sending over the mesh.
    public var renderedText: String {
        var footer = "\n\n— " + confidence.label
        if !sources.isEmpty { footer += " · Sources: " + sources.joined(separator: "; ") }
        return text + footer
    }
}

/// Guardrails for medical/safety answers, applied to every answer (offline or generated).
///
/// 1. Questions asking for medication doses get a refusal that points to a pharmacist/doctor.
/// 2. Signs of self-harm get crisis guidance, never methods.
/// 3. Generated answers recommending known-dangerous practices are replaced with library guidance.
public enum AnswerSafety {
    public enum Concern: String, Equatable, Sendable {
        case dosing, selfHarm
    }

    private static let dosingPatterns = ["how much", "how many", "dose", "dosage", " mg", "milligram", "tablets should",
                                         "pills should", "how often can i take", "overdose on", "kitni goli"]
    private static let medicineWords = ["paracetamol", "ibuprofen", "aspirin", "insulin", "antibiotic", "medicine",
                                        "medication", "tablet", "pill", "painkiller", "syrup", "drug", "acetaminophen", "dawai"]
    private static let selfHarmPatterns = ["kill myself", "end my life", "suicide", "want to die", "hurt myself",
                                           "self harm", "self-harm", "no reason to live", "marna chahta", "marna chahti"]

    /// Practices that first-aid guidance warns against. Flagged only when recommended (not negated).
    static let dangerousPractices: [(phrase: String, why: String)] = [
        ("butter", "butter on burns traps heat and raises infection risk"),
        ("toothpaste", "toothpaste on burns can worsen them"),
        ("ice on the burn", "ice can damage burned skin"),
        ("ice to the burn", "ice can damage burned skin"),
        ("suck the venom", "sucking venom doesn't help and can cause harm"),
        ("suck out the venom", "sucking venom doesn't help and can cause harm"),
        ("cut the bite", "cutting a bite causes injury and infection"),
        ("induce vomiting", "making someone vomit after poisoning can cause more harm"),
        ("make them vomit", "making someone vomit after poisoning can cause more harm"),
        ("put something in their mouth", "objects in the mouth during a seizure can cause choking or injury"),
        ("hold them down", "restraining someone having a seizure can injure them"),
        ("drink bleach", "bleach is poisonous"),
        ("alcohol to warm", "alcohol makes hypothermia worse"),
        ("rub the frostbite", "rubbing frostbitten skin damages it"),
        ("tilt the head back", "tilting the head back in a nosebleed makes blood run down the throat"),
        ("walk through the floodwater", "moving floodwater can knock people over"),
        ("drive through the floodwater", "a car can be swept away in shallow moving water"),
    ]

    private static let negations = ["don't", "do not", "never", "avoid", "not ", "no ", "instead of", "rather than", "nahi", "mat "]

    public static func concern(in question: String) -> Concern? {
        let q = " " + question.lowercased() + " "
        if selfHarmPatterns.contains(where: q.contains) { return .selfHarm }
        if dosingPatterns.contains(where: q.contains) && medicineWords.contains(where: q.contains) { return .dosing }
        return nil
    }

    public static let crisisText = """
    I'm really sorry you're feeling this way. You don't have to handle this alone.
    1. If you're in immediate danger, contact emergency services now.
    2. Reach out to someone you trust and tell them how you feel — you can message them from this app.
    3. Stay with other people if you can, and move away from anything you could use to hurt yourself.
    Talking to a crisis counsellor or doctor can really help.
    """

    public static let dosingText = """
    I can't give medicine doses — the right amount depends on age, weight, other conditions and the exact product, and a wrong dose can be dangerous.
    Ask a pharmacist, doctor or health worker, and follow the instructions on the package. If someone has taken too much of a medicine, treat it as poisoning and get help.
    """

    /// Dangerous recommendations present in `answer` (ignoring ones that are clearly negated).
    public static func unsafeRecommendations(in answer: String) -> [String] {
        let lower = answer.lowercased()
        var found: [String] = []
        for (phrase, why) in dangerousPractices {
            var searchStart = lower.startIndex
            while let range = lower.range(of: phrase, range: searchStart..<lower.endIndex) {
                // Look back within the same sentence for a negation.
                let sentenceStart = lower[..<range.lowerBound].lastIndex(where: { ".!?\n".contains($0) }).map { lower.index(after: $0) } ?? lower.startIndex
                let context = lower[sentenceStart..<range.lowerBound]
                if !negations.contains(where: context.contains) {
                    found.append(why)
                    break
                }
                searchStart = range.upperBound
            }
        }
        return found
    }

    /// Compose the final answer from an optional generated answer plus library references.
    ///
    /// - question: what the user asked.
    /// - generated: the on-device model's answer (nil when no model).
    /// - references: library entries retrieved for the question.
    /// - localSources: labels of local mesh messages the answer drew on.
    public static func compose(question: String, generated: String?, references: [EmergencyKnowledge.Entry],
                               localSources: [String] = []) -> SafeAnswer {
        switch concern(in: question) {
        case .selfHarm?:
            return SafeAnswer(text: crisisText, confidence: .refused, sources: [], safetyNote: "Self-harm signals: crisis guidance only")
        case .dosing?:
            let extra = references.first.map { "\n\nRelated guidance —\n" + $0.text } ?? ""
            return SafeAnswer(text: dosingText + extra, confidence: .refused, sources: references.prefix(1).map(\.title),
                              safetyNote: "Medicine doses are never given")
        case nil:
            break
        }

        let referenceTitles = references.map(\.title)
        if let generated = generated?.trimmingCharacters(in: .whitespacesAndNewlines), !generated.isEmpty {
            let problems = unsafeRecommendations(in: generated)
            if !problems.isEmpty {
                // Never show a generated answer that recommends something dangerous.
                if let best = references.first {
                    return SafeAnswer(text: best.text + "\n\n" + EmergencyKnowledge.disclaimer, confidence: .high,
                                      sources: [best.title], safetyNote: "Generated answer replaced: " + problems.joined(separator: "; "))
                }
                return SafeAnswer(text: "I can't give a reliable answer to that. Please ask a health worker or emergency services.",
                                  confidence: .refused, sources: [], safetyNote: "Generated answer withheld: " + problems.joined(separator: "; "))
            }
            let grounded = !references.isEmpty || !localSources.isEmpty
            let isMedical = references.contains { $0.category == "first-aid" }
            return SafeAnswer(text: generated + (isMedical ? "\n\n" + EmergencyKnowledge.disclaimer : ""),
                              confidence: grounded ? .medium : .low, sources: referenceTitles + localSources,
                              generatedByModel: true)
        }

        if let best = references.first {
            return SafeAnswer(text: best.text + "\n\n" + EmergencyKnowledge.disclaimer, confidence: .high, sources: [best.title])
        }
        return SafeAnswer(text: "I don't have offline guidance for that. Try asking someone nearby with an AI-capable phone, or describe the emergency (bleeding, burn, fracture, fire, flood…).",
                          confidence: .low, sources: [])
    }
}
