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
    /// Weighted phrases per category (English, Hindi, Hinglish). Matching is on lowercased text.
    private static let categoryPhrases: [(SOSTriage.Category, [(String, Double)])] = [
        (.fire, [("fire", 3), ("smoke", 2), ("burning", 2), ("flames", 3), ("on fire", 3), ("aag", 3), ("आग", 3), ("blaze", 3)]),
        (.flood, [("flood", 3), ("water rising", 3), ("rising water", 3), ("drowning", 3), ("submerged", 3), ("baadh", 3),
                  ("knee", 1), ("knees", 2), ("waist deep", 3), ("chest deep", 3), ("water is up to", 3), ("water inside", 3),
                  ("fell into the canal", 4), ("fell into the river", 4), ("swept away", 4), ("went under", 4), ("canal", 2),
                  ("doob", 4), ("dooba", 4),
                  ("बाढ़", 3), ("pani bhar", 3), ("river", 1), ("flood water", 3), ("on the roof", 1), ("need boats", 2)]),
        (.trapped, [("trapped", 4), ("stuck", 3), ("rubble", 4), ("debris", 3), ("buried", 4), ("can't get out", 4),
                    ("pinned", 5), ("crushed", 4), ("wall fell", 4), ("roof fell", 4), ("fell on", 2), ("under the", 1), ("band ho gayi", 2),
                    ("cannot get out", 4), ("jammed", 2), ("malbe", 4), ("fase", 3), ("फंसे", 4), ("फंसा", 4),
                    ("building collapsed", 4), ("roof collapsed", 4), ("wall collapsed", 4), ("stairs collapsed", 4), ("lift", 2)]),
        (.violence, [("attack", 3), ("shooting", 4), ("gun", 4), ("knife", 4), ("knives", 4), ("stabbed", 5), ("stab", 4),
                     ("harassed", 4), ("harassment", 4), ("molest", 4), ("hit me", 3), ("being hit", 3), ("mob", 3), ("riot", 4),
                     ("fight", 2), ("kidnap", 5), ("abduct", 5), ("chhed", 4),
                     ("assault", 4), ("beating", 3), ("violence", 3), ("threatening", 3), ("following me", 2), ("hamla", 3),
                     ("maar rahe", 3), ("robbed", 2)]),
        (.missingPerson, [("missing", 4), ("lost child", 4), ("can't find", 3), ("cannot find", 3), ("lapata", 4),
                          ("wandered off", 4), ("last seen", 4), ("haven't heard from", 3), ("separated from", 3), ("nahi mil raha", 4),
                          ("लापता", 4), ("kho gaya", 4), ("kho gayi", 4)]),
        (.medical, [("not breathing", 5), ("can't breathe", 5), ("cannot breathe", 5), ("saans", 4), ("unconscious", 5),
                    // consciousness
                    ("passed out", 5), ("not responding", 5), ("isn't responding", 5), ("unresponsive", 5), ("won't wake", 5),
                    ("not waking", 5), ("blacked out", 4), ("hosh nahi", 5),
                    // airway / breathing / circulation
                    ("choking", 5), ("barely breathe", 5), ("struggling to breathe", 5), ("breathless", 3), ("lips blue", 5),
                    ("lips going blue", 5), ("turning blue", 5), ("blood everywhere", 4), ("lot of blood", 4),
                    // mechanisms of injury
                    ("accident", 2), ("hit by", 3), ("head wound", 4), ("wound", 2), ("bleed", 2), ("sprain", 2),
                    ("blister", 2), ("chakkar", 3), ("ulti", 3), ("bukhar", 3), ("dard", 2), ("khoon", 3), ("bimaar", 3), ("sick", 2),
                    ("behosh", 5), ("collapsed", 2), ("heart attack", 5), ("chest pain", 4), ("seizure", 4), ("bleeding", 3),
                    ("injured", 3), ("injury", 3), ("broken", 3), ("fracture", 3), ("fell", 2), ("faint", 3), ("fainted", 3),
                    ("pregnant", 3), ("labour", 3), ("labor", 3), ("diabetic", 3), ("asthma", 4), ("inhaler", 3),
                    ("allergic", 4), ("swelling", 2), ("fever", 3), ("vomiting", 3), ("burn", 3), ("doctor", 2),
                    ("ambulance", 3), ("hurt", 2), ("pain", 2), ("chot", 3), ("चोट", 3), ("toot", 2), ("twisted", 2),
                    ("ankle", 2), ("can't walk", 3), ("cannot walk", 3), ("can't move", 3), ("cannot move", 3), ("weak", 1),
                    ("medicine", 2), ("insulin", 2), ("dizzy", 2), ("cut", 1), ("baby", 1)]),
        (.supplies, [("water", 1), ("food", 2), ("shelter", 2), ("blanket", 2), ("charger", 2), ("power bank", 2),
                     ("tarpaulin", 3), ("dry clothes", 3), ("clothes", 1), ("diapers", 3), ("sanitary", 3), ("no food", 3),
                     ("torch", 2), ("medicines", 1),
                     ("baby food", 3), ("pani", 1), ("khana", 2), ("need supplies", 2), ("tent", 2)]),
    ]

    /// Life-threatening signals → critical whatever the category.
    private static let criticalSignals = ["not breathing", "can't breathe", "cannot breathe", "saans nahi", "unconscious",
                                          "passed out", "not responding", "isn't responding", "unresponsive", "won't wake",
                                          "choking", "barely breathe", "struggling to breathe", "lips blue", "lips going blue",
                                          "turning blue", "blood everywhere", "pinned", "crushed", "went under", "swept away",
                                          "fell into the canal", "fell into the river", "kidnap", "abduct", "hosh nahi",
                                          "behosh", "heart attack", "chest pain", "seizure", "heavy bleeding", "bleeding heavily",
                                          "bleeding a lot", "stabbed", "shooting", "gun", "knives", "knife", "drowning",
                                          "face swelling", "throat swelling", "collapsed", "trapped", "buried", "rubble",
                                          "malbe", "can't get out", "cannot get out", "dying", "not moving"]
    /// Serious-but-not-immediately-fatal signals → at least high.
    private static let highSignals = ["broken", "fracture", "can't move", "cannot move", "can't walk", "cannot walk", "fell",
                                      "deep cut", "bleeding", "faint", "asthma", "allergic", "diabetic", "missing", "lost child",
                                      "can't find", "cannot find", "lapata", "लापता", "water rising", "rising water", "submerged",
                                      "on the roof", "attack", "beating", "assault", "threatening", "following", "need a doctor",
                                      "very weak", "injured", "chot", "toot", "twisted", "baadh", "बाढ़", "elderly", "old woman",
                                      "old man", "pregnant", "child", "kids", "baby", "urgent", "emergency",
                                      "head wound", "accident", "hit by", "harassed", "mob", "wandered off", "last seen",
                                      "knees", "waist deep", "water is up to", "khoon", "year old"]
    private static let mediumSignals = ["fever", "vomiting", "burn", "pain", "running out", "medicine", "insulin", "dizzy", "hurt",
                                        "blister", "chakkar", "ulti", "bukhar", "no food"]

    /// Minimum priority implied by the category itself.
    private static func floor(for category: SOSTriage.Category) -> SOSTriage.Priority {
        switch category {
        case .fire, .trapped: return .critical
        case .flood, .violence, .missingPerson: return .high
        case .medical: return .medium
        case .supplies, .other: return .low
        }
    }

    private static let collapseStructures = ["building", "house", "roof", "wall", "stairs", "bridge", "ceiling", "school"]

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "a dozen": 12, "dozen": 12, "several": 3, "many": 5,
    ]

    private static let locationMarkers = ["near ", "at ", "behind ", "beside ", "opposite ", "in front of ",
                                          "next to ", "inside ", "on "]

    /// Triage something the user deliberately sent as an SOS. Even if the rules don't recognise
    /// the situation, an SOS is never ranked below "high" (unless it's clearly a supplies request).
    public static func triageSOS(_ text: String) -> SOSTriage {
        var result = triage(text)
        if result.category != .supplies && result.priority < .high { result.priority = .high }
        return result
    }

    public static func triage(_ text: String) -> SOSTriage {
        let lower = text.lowercased()
        func has(_ phrase: String) -> Bool { lower.contains(phrase) }

        // 1. Score categories.
        var scores: [SOSTriage.Category: Double] = [:]
        for (category, phrases) in categoryPhrases {
            scores[category] = phrases.reduce(0) { $0 + (has($1.0) ? $1.1 : 0) }
        }
        // 2. Context rules for ambiguous words.
        let structureCollapse = has("collapse") && collapseStructures.contains(where: has)
        if structureCollapse { scores[.trapped, default: 0] += 4; scores[.medical, default: 0] -= 2 }
        if has("smoke") && (has("can't get out") || has("cannot get out") || has("jammed") || has("trapped")) {
            scores[.trapped, default: 0] += 3
        }
        if ["stabbed", "shooting", "gun", "knife", "knives", "assault"].contains(where: has) {
            scores[.violence, default: 0] += 4 // the cause matters more than the injury
        }
        if has("drowning") { scores[.flood, default: 0] += 3 }
        if has("insulin") || has("medicine") { scores[.medical, default: 0] += 2 }

        let best = scores.filter { $0.value > 0 }.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }
        let category = best?.key ?? .other

        // 3. Priority: category floor, raised by signals.
        var priority = floor(for: category)
        let critical = criticalSignals.contains { signal in
            // "collapsed" is only life-threatening for a person, or a structure with people under it.
            if signal == "collapsed" { return has("collapsed") }
            return has(signal)
        }
        if critical && category != .supplies { priority = .critical }
        else if highSignals.contains(where: has) && category != .other && category != .supplies { priority = max(priority, .high) }
        else if mediumSignals.contains(where: has) && category != .other { priority = max(priority, .medium) }
        if category == .violence && ["gun", "knife", "knives", "shooting", "stabbed"].contains(where: has) { priority = .critical }
        if category == .medical && has("pregnant") || has("labour") || has("labor") {
            if has("bleeding") { priority = .critical }
        }

        let people = peopleCount(in: lower)
        if let people, people >= 5, priority < .critical, category != .other {
            priority = SOSTriage.Priority(rawValue: priority.rawValue + 1)!
        }

        return SOSTriage(
            priority: priority,
            category: category,
            peopleAffected: people,
            summary: summarize(text, category: category, people: people),
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

    static let landmarkStopWords: Set<String> = [
        "and", "but", "or", "with", "who", "which", "where", "when", "while", "because", "so", "then",
        "is", "are", "was", "were", "has", "have", "had", "can't", "cannot", "can", "cant", "won't", "will",
        "please", "help", "we", "i", "he", "she", "they", "it", "my", "our", "his", "her", "their",
        "aur", "hai", "hain",
    ]

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
                    // A landmark is a short noun phrase: stop at the first joining word or verb
                    // ("near the bus stand and can't move" → "the bus stand").
                    let words = phrase.split(separator: " ").prefix(4)
                        .prefix { !landmarkStopWords.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
                        .joined(separator: " ")
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
