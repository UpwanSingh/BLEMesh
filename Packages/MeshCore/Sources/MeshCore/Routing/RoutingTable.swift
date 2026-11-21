import Foundation

/// What the mesh knows about another device.
public struct PeerInfo: Equatable, Sendable, Identifiable {
    public var id: PeerID { peerID }
    public let peerID: PeerID
    public var identity: PublicIdentity
    public var nickname: String
    public var capabilities: PeerCapabilities
    public var lastSeen: Date
    /// Hops to reach the peer (0 = direct neighbor). nil = currently unreachable.
    public var hops: Int?

    public var isReachable: Bool { hops != nil }
    public var isNeighbor: Bool { hops == 0 }
}

/// Distance-vector routing keyed purely by PeerID, learned from signed announces.
///
/// For each destination we keep the best (fewest hops, then freshest) next-hop link.
/// Routes expire when announces stop arriving and are dropped immediately when their link goes down.
public struct RoutingTable {
    public struct Route: Equatable, Sendable {
        public var link: LinkID
        public var hops: Int
        public var updatedAt: Date
    }

    private(set) var routes: [PeerID: Route] = [:]
    public let expiry: TimeInterval

    public init(expiry: TimeInterval) {
        self.expiry = expiry
    }

    /// Offer a route learned from an announce. Returns true if the table changed.
    @discardableResult
    public mutating func offer(_ destination: PeerID, link: LinkID, hops: Int, now: Date) -> Bool {
        if let existing = routes[destination], now.timeIntervalSince(existing.updatedAt) < expiry {
            // Accept same-or-better paths (ties prefer the freshest), and any update from the
            // current next hop (its path may have grown). Reject strictly worse alternatives.
            guard hops <= existing.hops || link == existing.link else { return false }
            routes[destination] = Route(link: link, hops: hops, updatedAt: now)
            return existing.link != link || existing.hops != hops
        }
        routes[destination] = Route(link: link, hops: hops, updatedAt: now)
        return true
    }

    public func route(to destination: PeerID, now: Date) -> Route? {
        guard let route = routes[destination], now.timeIntervalSince(route.updatedAt) < expiry else { return nil }
        return route
    }

    /// Remove all routes through `link`. Returns affected destinations.
    @discardableResult
    public mutating func removeRoutes(via link: LinkID) -> [PeerID] {
        let affected = routes.filter { $0.value.link == link }.map(\.key)
        for id in affected { routes[id] = nil }
        return affected
    }

    /// Drop expired routes. Returns affected destinations.
    @discardableResult
    public mutating func purge(now: Date) -> [PeerID] {
        let expired = routes.filter { now.timeIntervalSince($0.value.updatedAt) >= expiry }.map(\.key)
        for id in expired { routes[id] = nil }
        return expired
    }

    public var count: Int { routes.count }
}

/// Bounded set of recently seen IDs with time-based expiry (duplicate suppression).
struct SeenCache<Key: Hashable> {
    private var entries: [Key: Date] = [:]
    private var order: [Key] = []
    let capacity: Int
    let lifetime: TimeInterval

    init(capacity: Int, lifetime: TimeInterval) {
        self.capacity = capacity
        self.lifetime = lifetime
    }

    func contains(_ key: Key, now: Date) -> Bool {
        guard let at = entries[key] else { return false }
        return now.timeIntervalSince(at) < lifetime
    }

    /// Returns true if newly inserted (i.e. not seen before).
    @discardableResult
    mutating func insert(_ key: Key, now: Date) -> Bool {
        if contains(key, now: now) { return false }
        if entries[key] == nil { order.append(key) }
        entries[key] = now
        if order.count > capacity {
            let overflow = order.count - capacity
            for k in order.prefix(overflow) { entries[k] = nil }
            order.removeFirst(overflow)
        }
        return true
    }

    var count: Int { entries.count }
}

/// Per-origin token bucket limiting how much traffic we relay for any single sender.
struct RateLimiter {
    private struct Bucket { var tokens: Double; var updatedAt: Date }
    private var buckets: [PeerID: Bucket] = [:]
    let burst: Double
    let refillPerSecond: Double

    init(burst: Double, refillPerSecond: Double) {
        self.burst = burst
        self.refillPerSecond = refillPerSecond
    }

    mutating func allow(_ origin: PeerID, now: Date) -> Bool {
        var bucket = buckets[origin] ?? Bucket(tokens: burst, updatedAt: now)
        let elapsed = max(0, now.timeIntervalSince(bucket.updatedAt))
        bucket.tokens = min(burst, bucket.tokens + elapsed * refillPerSecond)
        bucket.updatedAt = now
        guard bucket.tokens >= 1 else {
            buckets[origin] = bucket
            return false
        }
        bucket.tokens -= 1
        buckets[origin] = bucket
        if buckets.count > 2048 { buckets = buckets.filter { now.timeIntervalSince($0.value.updatedAt) < 60 } }
        return true
    }
}
