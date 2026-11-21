import Foundation

/// Structured assessment of an emergency message.
///
/// Produced on the sender's device (on-device LLM when available, otherwise the deterministic
/// `HeuristicTriage`), and re-derived by receivers when absent so the SOS board can rank requests.
public struct SOSTriage: Codable, Equatable, Sendable {
    public enum Priority: Int, Codable, Sendable, Comparable, CaseIterable {
        case low = 0, medium = 1, high = 2, critical = 3

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .critical: return "Critical"
            }
        }
    }

    public enum Category: String, Codable, Sendable, CaseIterable {
        case medical, fire, flood, trapped, violence, missingPerson, supplies, other

        public var label: String {
            switch self {
            case .medical: return "Medical"
            case .fire: return "Fire"
            case .flood: return "Flood"
            case .trapped: return "Trapped"
            case .violence: return "Violence"
            case .missingPerson: return "Missing person"
            case .supplies: return "Supplies"
            case .other: return "Other"
            }
        }
    }

    public var priority: Priority
    public var category: Category
    public var peopleAffected: Int?
    /// Short one-line summary for rescuers.
    public var summary: String
    /// Place names / landmarks mentioned in the text.
    public var locationHints: [String]
    /// "llm" or "heuristic" — shown in the UI so users know how it was produced.
    public var source: String

    public init(priority: Priority, category: Category, peopleAffected: Int?, summary: String,
                locationHints: [String], source: String) {
        self.priority = priority
        self.category = category
        self.peopleAffected = peopleAffected
        self.summary = summary
        self.locationHints = locationHints
        self.source = source
    }
}

/// Deterministic, offline, language-light triage. Always available, also on devices without
/// an on-device model, and used as a fallback / sanity floor for LLM output.
public enum HeuristicTriage {
    private static let categoryKeywords: [(SOSTriage.Category, [String])] = [
        (.fire, ["fire", "smoke", "burning", "flames", "aag", "आग"]),
        (.flood, ["flood", "water rising", "drowning", "submerged", "baadh", "बाढ़"]),
        (.trapped, ["trapped", "stuck", "collapsed", "rubble", "can't get out", "cannot get out", "buried", "fasa", "फंसा"]),
        (.violence, ["attack", "shooting", "gun", "knife", "assault", "violence", "hamla"]),
        (.missingPerson, ["missing", "lost child", "can't find", "cannot find", "lapata", "लापता"]),
        (.medical, ["bleeding", "unconscious", "not breathing", "heart attack", "injured", "injury", "broken",
                    "fell", "fracture", "pain", "faint", "seizure", "pregnant", "labor", "diabetic", "chot", "चोट",
                    "doctor", "ambulance", "medicine", "hurt", "can't move", "cannot move", "allergic"]),
        (.supplies, ["water", "food", "shelter", "blanket", "charger", "battery", "pani", "khana"]),
    ]

    private static let criticalKeywords = ["not breathing", "unconscious", "heavy bleeding", "bleeding heavily",
                                           "heart attack", "drowning", "trapped", "buried", "fire", "shooting",
                                           "gun", "collapsed", "seizure", "dying", "can't breathe", "cannot breathe"]
    private static let highKeywords = ["bleeding", "broken", "fracture", "can't move", "cannot move", "injured",
                                       "fell", "child", "baby", "pregnant", "elderly", "old man", "old woman",
                                       "flood", "missing", "urgent", "emergency", "help"]

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "a dozen": 12, "dozen": 12, "several": 3, "many": 5,
    ]

    private static let locationMarkers = ["near ", "at ", "behind ", "beside ", "opposite ", "in front of ",
                                          "next to ", "inside ", "on "]

    public static func triage(_ text: String) -> SOSTriage {
        let lower = text.lowercased()

        var bestCategory = SOSTriage.Category.other
        var bestScore = 0
        for (category, words) in categoryKeywords {
            let score = words.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            if score > bestScore {
                bestScore = score
                bestCategory = category
            }
        }

        var priority: SOSTriage.Priority = .medium
        if criticalKeywords.contains(where: lower.contains) {
            priority = .critical
        } else if highKeywords.contains(where: lower.contains) {
            priority = .high
        } else if bestCategory == .supplies || bestCategory == .other {
            priority = bestCategory == .other ? .medium : .low
        }

        let people = peopleCount(in: lower)
        if let people, people >= 5, priority < .critical { priority = SOSTriage.Priority(rawValue: priority.rawValue + 1)! }

        return SOSTriage(
            priority: priority,
            category: bestCategory,
            peopleAffected: people,
            summary: summarize(text, category: bestCategory, people: people),
            locationHints: locationHints(in: text),
            source: "heuristic"
        )
    }

    static func peopleCount(in lower: String) -> Int? {
        let nouns = ["people", "persons", "person", "children", "kids", "injured", "men", "women", "families", "of us"]
        let tokens = lower.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        for (i, token) in tokens.enumerated() where i + 1 < tokens.count {
            let next = tokens[i + 1]
            guard nouns.contains(where: { next.hasPrefix($0) || (i + 2 < tokens.count && "\(next) \(tokens[i + 2])".hasPrefix($0)) }) else { continue }
            if let n = Int(token), n > 0, n < 10_000 { return n }
            if let n = numberWords[token] { return n }
        }
        for (word, n) in numberWords where word.contains(" ") && lower.contains(word) { return n }
        return nil
    }

    static func locationHints(in text: String) -> [String] {
        let lower = text.lowercased()
        var hints: [String] = []
        for marker in locationMarkers {
            var searchRange = lower.startIndex..<lower.endIndex
            while let range = lower.range(of: marker, range: searchRange) {
                // Must start a word.
                if range.lowerBound == lower.startIndex || lower[lower.index(before: range.lowerBound)] == " " {
                    let tail = text[range.upperBound...]
                    let phrase = tail.split(whereSeparator: { ".,;!?\n".contains($0) }).first.map(String.init) ?? ""
                    let words = phrase.split(separator: " ").prefix(4).joined(separator: " ")
                    if words.count >= 3, !hints.contains(words) { hints.append(words) }
                }
                searchRange = range.upperBound..<lower.endIndex
            }
        }
        return Array(hints.prefix(3))
    }

    static func summarize(_ text: String, category: SOSTriage.Category, people: Int?) -> String {
        let firstSentence = text.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? text
        let trimmed = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = trimmed.count > 90 ? String(trimmed.prefix(87)) + "…" : trimmed
        var prefix = category == .other ? "" : "\(category.label): "
        if let people { prefix += "\(people) affected · " }
        return prefix + clipped
    }
}
