import Foundation

/// A message the local intelligence features can reason over (public channel, groups, DMs).
public struct LocalMessage: Equatable, Sendable {
    public enum Kind: String, Sendable { case chat, sos, checkIn, safetyCheck, sosUpdate, voice }

    public var id: UUID
    public var sender: PeerID
    public var senderName: String
    public var text: String
    public var date: Date
    public var kind: Kind
    public var triage: SOSTriage?
    /// The message is a question addressed to (or mentions) the local user.
    public var mentionsMe: Bool

    public init(id: UUID = UUID(), sender: PeerID, senderName: String, text: String, date: Date,
                kind: Kind = .chat, triage: SOSTriage? = nil, mentionsMe: Bool = false) {
        self.id = id
        self.sender = sender
        self.senderName = senderName
        self.text = text
        self.date = date
        self.kind = kind
        self.triage = triage
        self.mentionsMe = mentionsMe
    }
}

// MARK: - #6 Answers from what the mesh has heard

/// BM25 retrieval over recent local messages ("where is water being given out?").
public enum LocalRetriever {
    public struct Hit: Equatable, Sendable {
        public var message: LocalMessage
        public var score: Double
    }

    private static let stopwords: Set<String> = ["the", "a", "an", "is", "are", "was", "were", "be", "to", "of", "and", "or",
                                                 "in", "on", "at", "for", "with", "any", "anyone", "there", "where", "what",
                                                 "who", "how", "do", "does", "i", "me", "my", "we", "you", "it", "this", "that",
                                                 "can", "get", "some", "being", "near", "here", "now", "please", "know", "has", "have",
                                                 "out", "our", "up", "off", "from", "by", "been", "just", "given", "give", "go", "going", "still", "right", "they", "them", "us", "if", "so", "will", "should", "would", "could"]

    /// Words that signal a question about the local situation rather than general knowledge.
    private static let localCues = ["where", "anyone", "is there", "who has", "who is", "nearby", "near me", "open", "available",
                                    "being given", "distributing", "road", "route", "power", "shelter", "water", "food",
                                    "doctor", "medic", "hospital", "camp", "help desk", "charging", "blocked", "safe route"]

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }
            .map(stem)
    }

    /// Tiny stemmer so "distributing"/"distribution", "blankets"/"blanket" match.
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ion", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    public static func isLocalQuestion(_ question: String) -> Bool {
        let q = question.lowercased()
        return localCues.contains(where: q.contains)
    }

    public static func search(_ query: String, in messages: [LocalMessage], now: Date, limit: Int = 3,
                              maxAge: TimeInterval = 6 * 3600) -> [Hit] {
        let queryTerms = Set(tokens(query))
        guard !queryTerms.isEmpty else { return [] }
        let docs = messages.filter { now.timeIntervalSince($0.date) <= maxAge }.map { ($0, tokens($0.text)) }
        guard !docs.isEmpty else { return [] }
        let avgLength = Double(docs.map { $0.1.count }.reduce(0, +)) / Double(docs.count)
        var docFreq: [String: Int] = [:]
        for (_, terms) in docs { for term in Set(terms) where queryTerms.contains(term) { docFreq[term, default: 0] += 1 } }
        let n = Double(docs.count), k1 = 1.4, b = 0.75
        let hits: [Hit] = docs.compactMap { message, terms in
            var score = 0.0
            let counts = Dictionary(terms.map { ($0, 1) }, uniquingKeysWith: +)
            for term in queryTerms {
                guard let tf = counts[term].map(Double.init), let df = docFreq[term] else { continue }
                let idf = log(1 + (n - Double(df) + 0.5) / (Double(df) + 0.5))
                score += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * Double(terms.count) / max(avgLength, 1)))
            }
            guard score > 0 else { return nil }
            // Prefer recent messages: −10% per hour of age.
            let ageHours = now.timeIntervalSince(message.date) / 3600
            return Hit(message: message, score: score * max(0.4, 1 - 0.1 * ageHours))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Plain answer quoting the best local messages.
    public static func answer(_ query: String, hits: [Hit], now: Date) -> String? {
        guard !hits.isEmpty else { return nil }
        let formatter = RelativeDateTimeFormatter()
        let lines = hits.map { "• \($0.message.senderName) (\(formatter.localizedString(for: $0.message.date, relativeTo: now))): “\($0.message.text)”" }
        return "From messages nearby:\n" + lines.joined(separator: "\n") + "\n\nThese are reports from people nearby, not verified information."
    }
}

// MARK: - #10 Catch-up summaries

public struct CatchUpSummary: Equatable, Sendable {
    public var overview: String
    public var highlights: [LocalMessage]
    public var messageCount: Int
    public var peopleCount: Int
}

public enum CatchUpBuilder {
    /// Pick what matters from messages since `since`: SOS and "need help" first, then questions
    /// to you and safety checks, then the most-reported topics. Near-duplicates are merged.
    public static func build(_ messages: [LocalMessage], since: Date, limit: Int = 5) -> CatchUpSummary {
        let recent = messages.filter { $0.date >= since }.sorted { $0.date < $1.date }
        func importance(_ m: LocalMessage) -> Double {
            var score = 0.0
            switch m.kind {
            case .sos: score += 100 + Double((m.triage?.priority.rawValue ?? 1) * 10)
            case .checkIn: score += m.text.localizedCaseInsensitiveContains("need help") ? 80 : 10
            case .safetyCheck: score += 50
            case .sosUpdate: score += 15
            case .chat, .voice: score += 5
            }
            if m.mentionsMe { score += 60 }
            if m.text.contains("?") { score += 5 }
            let triage = m.triage ?? (m.kind == .chat || m.kind == .voice ? HeuristicTriage.triage(m.text) : nil)
            if let triage, triage.category != .other { score += Double(triage.priority.rawValue * 8) }
            return score
        }
        var picked: [LocalMessage] = []
        for message in recent.sorted(by: { importance($0) > importance($1) }) where picked.count < limit {
            let words = Set(LocalRetriever.tokens(message.text))
            let duplicate = picked.contains { other in
                let otherWords = Set(LocalRetriever.tokens(other.text))
                let overlap = Double(words.intersection(otherWords).count) / Double(max(1, min(words.count, otherWords.count)))
                return overlap >= 0.6
            }
            if !duplicate { picked.append(message) }
        }
        picked.sort { importance($0) > importance($1) }

        let people = Set(recent.map(\.sender)).count
        var parts: [String] = []
        let sosCount = recent.filter { $0.kind == .sos }.count
        let helpCount = recent.filter { $0.kind == .checkIn && $0.text.localizedCaseInsensitiveContains("need help") }.count
        let mentions = recent.filter(\.mentionsMe).count
        if sosCount > 0 { parts.append("\(sosCount) SOS") }
        if helpCount > 0 { parts.append("\(helpCount) need help") }
        if mentions > 0 { parts.append("\(mentions) for you") }
        let overview = recent.isEmpty
            ? "Nothing new."
            : "\(recent.count) message\(recent.count == 1 ? "" : "s") from \(people) \(people == 1 ? "person" : "people")"
              + (parts.isEmpty ? "." : ": " + parts.joined(separator: ", ") + ".")
        return CatchUpSummary(overview: overview, highlights: picked, messageCount: recent.count, peopleCount: people)
    }
}

// MARK: - #11 Rumour / credibility

public enum Credibility: String, Equatable, Sendable {
    /// Several independent people (or a verified contact) report it.
    case corroborated
    /// Only one person has reported it.
    case unverified
    /// Someone nearby says it's false or already over.
    case disputed

    public var label: String {
        switch self {
        case .corroborated: return "Confirmed by several people"
        case .unverified: return "Unverified — single report"
        case .disputed: return "Disputed"
        }
    }
}

public enum RumourAnalyzer {
    static let disputeCues = ["false alarm", "not true", "fake", "rumour", "rumor", "hoax", "no fire", "no flood",
                              "it's over", "its over", "under control", "already resolved", "all clear", "jhooth", "afwah"]

    /// Credibility of a digest item given who reported it and what else was said nearby.
    public static func assess(item: AreaDigest.Item, verified: Set<PeerID>,
                              nearbyTexts: [(text: String, date: Date)]) -> Credibility {
        let reporters = item.reporterIDs
        let categoryWord = item.category.rawValue.lowercased()
        let location = item.locations.first?.lowercased()
        let disputed = nearbyTexts.contains { text, date in
            guard date >= item.latest.addingTimeInterval(-600) else { return false }
            let lower = text.lowercased()
            guard disputeCues.contains(where: lower.contains) else { return false }
            // The dispute must be about the same thing: same category word or same place.
            return lower.contains(categoryWord) || location.map(lower.contains) == true
                || item.headline.lowercased().split(separator: " ").contains { $0.count > 4 && lower.contains($0) }
        }
        if disputed { return .disputed }
        if reporters.count >= 2 || !reporters.isDisjoint(with: verified) { return .corroborated }
        return .unverified
    }
}

// MARK: - #12 Spam filter

/// Per-sender spam scoring for public channels. Deterministic and explainable.
public struct SpamFilter {
    public struct Verdict: Equatable, Sendable {
        public var isSpam: Bool
        public var score: Double
        public var reasons: [String]
    }

    private var history: [PeerID: [(text: String, date: Date)]] = [:]
    public var reported: Set<PeerID> = []
    public var threshold: Double = 1.0

    public init() {}

    public mutating func evaluate(sender: PeerID, text: String, date: Date) -> Verdict {
        var recent = (history[sender] ?? []).filter { date.timeIntervalSince($0.date) < 600 }
        var score = 0.0
        var reasons: [String] = []
        let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber }
        // Someone repeating a plea for help is not spamming: urgent texts skip the repeat/flood rules.
        let urgent = HeuristicTriage.triage(text).priority >= .high
        let repeats = urgent ? 0 : recent.filter { $0.text == normalized }.count
        if repeats >= 2 { score += 0.6 * Double(repeats - 1); reasons.append("repeated \(repeats + 1)×") }
        let lastMinute = recent.filter { date.timeIntervalSince($0.date) < 60 }.count
        if !urgent && lastMinute >= 6 { score += 0.15 * Double(lastMinute - 5); reasons.append("\(lastMinute + 1) messages in a minute") }
        let lower = text.lowercased()
        if ["http://", "https://", "www.", ".com/", "bit.ly", "t.me/"].contains(where: lower.contains) { score += 0.5; reasons.append("link") }
        if ["free money", "click here", "earn ₹", "earn rs", "lottery", "crypto giveaway", "whatsapp me", "send money", "upi id"].contains(where: lower.contains) {
            score += 0.7; reasons.append("scam phrase")
        }
        let digits = text.filter(\.isNumber).count
        if digits >= 10 && lower.contains("call") { score += 0.3; reasons.append("phone number promo") }
        let letters = text.filter(\.isLetter)
        if letters.count >= 20 && letters.allSatisfy(\.isUppercase) { score += 0.3; reasons.append("all caps") }
        if reported.contains(sender) { score += 1.0; reasons.append("you reported this device") }
        recent.append((normalized, date))
        history[sender] = Array(recent.suffix(50))
        if history.count > 2000 { history = history.filter { date.timeIntervalSince($0.value.last?.date ?? .distantPast) < 600 } }
        return Verdict(isSpam: score >= threshold, score: score, reasons: reasons)
    }
}

// MARK: - #13 Responder matching

extension PeerCapabilities {
    /// The user is a medic (doctor, nurse, paramedic, first-aider).
    public static let medic = PeerCapabilities(rawValue: 1 << 3)
    /// The user is a rescuer / firefighter / disaster volunteer.
    public static let rescuer = PeerCapabilities(rawValue: 1 << 4)
}

public enum ResponderMatcher {
    /// Nearest reachable peers whose declared role fits the emergency.
    public static func suggest(for triage: SOSTriage?, among peers: [PeerInfo], limit: Int = 3) -> [PeerInfo] {
        let category = triage?.category ?? .other
        let wanted: PeerCapabilities
        switch category {
        case .medical: wanted = .medic
        case .fire, .flood, .trapped, .violence, .missingPerson: wanted = .rescuer
        case .supplies, .other: wanted = [.medic, .rescuer]
        }
        return Array(peers.filter { $0.isReachable && !$0.capabilities.isDisjoint(with: wanted) }
            .sorted { ($0.hops ?? .max) < ($1.hops ?? .max) }
            .prefix(limit))
    }
}
