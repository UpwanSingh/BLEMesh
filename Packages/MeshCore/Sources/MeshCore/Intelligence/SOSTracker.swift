import Foundation

/// Derives the live state of an SOS from the updates people have broadcast about it.
///
/// Rules (anyone can respond, but only the person in trouble can close their own SOS):
/// - Responders move it to acknowledged / help on the way; the highest responder status wins.
/// - "Resolved" or "cancelled" from the SOS sender closes it. From anyone else, "resolved" is
///   recorded as a claim (shown, but the SOS stays open until the sender confirms or 2 others agree).
/// - Updates older than the SOS, or for another SOS, are ignored.
public struct SOSState: Equatable, Sendable {
    public struct Responder: Equatable, Sendable {
        public var peer: PeerID
        public var status: SOSStatus
        public var note: String?
        public var at: Date
    }

    public var status: SOSStatus
    public var responders: [Responder]
    public var resolvedClaims: Int
    public var closedBySender: Bool
}

public enum SOSTracker {
    public struct Update: Sendable {
        public var from: PeerID
        public var update: SOSUpdate
        public var at: Date

        public init(from: PeerID, update: SOSUpdate, at: Date) {
            self.from = from
            self.update = update
            self.at = at
        }
    }

    public static func state(sosID: UUID, sender: PeerID, sentAt: Date, updates: [Update]) -> SOSState {
        var latestByPeer: [PeerID: Update] = [:]
        for update in updates where update.update.sosID == sosID && update.at >= sentAt {
            if let existing = latestByPeer[update.from], existing.at > update.at { continue }
            latestByPeer[update.from] = update
        }
        if let own = latestByPeer[sender], own.update.status >= .resolved {
            return SOSState(status: own.update.status, responders: responders(latestByPeer, excluding: sender),
                            resolvedClaims: 0, closedBySender: true)
        }
        let others = responders(latestByPeer, excluding: sender)
        let claims = others.filter { $0.status == .resolved }.count
        let active = others.filter { $0.status < .resolved }.map(\.status).max()
        let status: SOSStatus = claims >= 2 ? .resolved : (active ?? (claims > 0 ? .acknowledged : .open))
        return SOSState(status: status, responders: others, resolvedClaims: claims, closedBySender: false)
    }

    private static func responders(_ latest: [PeerID: Update], excluding sender: PeerID) -> [SOSState.Responder] {
        latest.values.filter { $0.from != sender && $0.update.status != .cancelled }
            .map { SOSState.Responder(peer: $0.from, status: $0.update.status, note: $0.update.note, at: $0.at) }
            .sorted { $0.at < $1.at }
    }
}

/// Latest check-in per family/group member, for the family locator.
public enum FamilyLocator {
    public struct Entry: Equatable, Sendable {
        public var member: PeerID
        public var checkIn: CheckIn?
        public var at: Date?
        /// No check-in yet, or the last one is older than `staleAfter`.
        public var isStale: Bool
    }

    public static func entries(members: Set<PeerID>, checkIns: [(PeerID, CheckIn, Date)], now: Date,
                               staleAfter: TimeInterval = 6 * 3600) -> [Entry] {
        var latest: [PeerID: (CheckIn, Date)] = [:]
        for (peer, checkIn, at) in checkIns where members.contains(peer) {
            if let existing = latest[peer], existing.1 > at { continue }
            latest[peer] = (checkIn, at)
        }
        return members.map { member in
            let found = latest[member]
            return Entry(member: member, checkIn: found?.0, at: found?.1,
                         isStale: found.map { now.timeIntervalSince($0.1) > staleAfter } ?? true)
        }
        .sorted { lhs, rhs in
            // Needs-help first, then unknown/stale, then safe; newest first within a bucket.
            func rank(_ e: Entry) -> Int { e.checkIn?.status == .needHelp ? 0 : (e.isStale ? 1 : 2) }
            return (rank(lhs), -(lhs.at?.timeIntervalSince1970 ?? 0)) < (rank(rhs), -(rhs.at?.timeIntervalSince1970 ?? 0))
        }
    }
}
