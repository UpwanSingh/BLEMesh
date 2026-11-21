import Foundation

/// A situational summary of recent traffic on the public channel ("what's happening around me").
public struct AreaDigest: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String { "\(category.rawValue)-\(headline)" }
        public var category: SOSTriage.Category
        public var priority: SOSTriage.Priority
        /// Distinct senders reporting this.
        public var reporters: Int
        public var headline: String
        public var locations: [String]
        public var latest: Date
    }

    public var items: [Item]
    public var messageCount: Int
    public var windowStart: Date?
    /// Free-text overview (LLM-written when available).
    public var overview: String
    public var source: String
}

/// Input to the digest: one public message or SOS.
public struct DigestInput: Sendable {
    public var sender: PeerID
    public var text: String
    public var date: Date
    public var triage: SOSTriage?

    public init(sender: PeerID, text: String, date: Date, triage: SOSTriage? = nil) {
        self.sender = sender
        self.text = text
        self.date = date
        self.triage = triage
    }
}

/// Deterministic digest builder: triages each message, clusters by category (and shared
/// location hint), counts distinct reporters, and ranks by priority then corroboration.
public enum DigestBuilder {
    public static func build(from inputs: [DigestInput], now: Date, window: TimeInterval = 3600) -> AreaDigest {
        let recent = inputs.filter { now.timeIntervalSince($0.date) <= window }
        struct Cluster {
            var category: SOSTriage.Category
            var priority: SOSTriage.Priority
            var reporters: Set<PeerID>
            var headline: String
            var locations: [String]
            var latest: Date
        }
        var clusters: [Cluster] = []

        for input in recent.sorted(by: { $0.date < $1.date }) {
            let triage = input.triage ?? HeuristicTriage.triage(input.text)
            // Pure chatter with no signal doesn't belong in a situational digest.
            if triage.category == .other && triage.priority <= .medium { continue }
            let location = triage.locationHints.first?.lowercased()
            if let index = clusters.firstIndex(where: {
                $0.category == triage.category &&
                (location == nil || $0.locations.isEmpty || $0.locations.contains { $0.lowercased() == location })
            }) {
                clusters[index].reporters.insert(input.sender)
                clusters[index].priority = max(clusters[index].priority, triage.priority)
                clusters[index].latest = max(clusters[index].latest, input.date)
                for hint in triage.locationHints where !clusters[index].locations.contains(hint) {
                    clusters[index].locations.append(hint)
                }
                if triage.priority > .medium { clusters[index].headline = triage.summary }
            } else {
                clusters.append(Cluster(category: triage.category, priority: triage.priority,
                                        reporters: [input.sender], headline: triage.summary,
                                        locations: triage.locationHints, latest: input.date))
            }
        }

        let items = clusters
            .map { AreaDigest.Item(category: $0.category, priority: $0.priority, reporters: $0.reporters.count,
                                   headline: $0.headline, locations: Array($0.locations.prefix(3)), latest: $0.latest) }
            .sorted { ($0.priority, $0.reporters, $0.latest) > ($1.priority, $1.reporters, $1.latest) }

        return AreaDigest(items: items, messageCount: recent.count,
                          windowStart: recent.map(\.date).min(), overview: overview(for: items, total: recent.count),
                          source: "heuristic")
    }

    static func overview(for items: [AreaDigest.Item], total: Int) -> String {
        guard !items.isEmpty else {
            return total == 0 ? "No recent activity nearby." : "\(total) recent messages, no emergencies reported."
        }
        let critical = items.filter { $0.priority == .critical }.count
        let parts = items.prefix(3).map { item -> String in
            let place = item.locations.first.map { " near \($0)" } ?? ""
            let who = item.reporters > 1 ? " (\(item.reporters) reports)" : ""
            return "\(item.category.label)\(place)\(who)"
        }
        let lead = critical > 0 ? "\(critical) critical situation\(critical == 1 ? "" : "s"). " : ""
        return lead + parts.joined(separator: "; ") + "."
    }
}
