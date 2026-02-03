import Foundation

/// Entry in the routing table
struct RouteEntry: Identifiable {
    let id: UUID                    // Destination device ID
    var nextHopID: UUID             // Direct peer to forward through
    var hopCount: Int               // Number of hops to destination
    var hopPath: [UUID]             // Full path to destination
    var lastUsed: Date
    var expiresAt: Date
    var reliability: Float          // 0.0 - 1.0 based on success rate
    var successCount: Int
    var failureCount: Int
    
    var isExpired: Bool {
        Date() > expiresAt
    }
    
    var isValid: Bool {
        !isExpired && reliability > 0.3
    }
    
    init(
        destinationID: UUID,
        nextHopID: UUID,
        hopCount: Int,
        hopPath: [UUID],
        ttlSeconds: TimeInterval = 300 // 5 minutes default
    ) {
        self.id = destinationID
        self.nextHopID = nextHopID
        self.hopCount = hopCount
        self.hopPath = hopPath
        self.lastUsed = Date()
        self.expiresAt = Date().addingTimeInterval(ttlSeconds)
        self.reliability = 1.0
        self.successCount = 0
        self.failureCount = 0
    }
    
    mutating func markUsed() {
        lastUsed = Date()
        // Extend expiry on use
        expiresAt = Date().addingTimeInterval(300)
    }
    
    mutating func recordSuccess() {
        successCount += 1
        updateReliability()
    }
    
    mutating func recordFailure() {
        failureCount += 1
        updateReliability()
    }
    
    private mutating func updateReliability() {
        let total = successCount + failureCount
        if total > 0 {
            reliability = Float(successCount) / Float(total)
        }
    }
}

/// Thread-safe routing table
final class RoutingTable {
    private var routes: [UUID: RouteEntry] = [:]
    private var reverseRoutes: [UUID: UUID] = [:] // For RREP back-propagation
    private let lock = NSLock()
    
    /// Add or update a route
    func updateRoute(_ entry: RouteEntry) {
        lock.lock()
        defer { lock.unlock() }
        
        // Only update if new route is better (fewer hops or newer)
        if let existing = routes[entry.id] {
            if entry.hopCount < existing.hopCount || existing.isExpired {
                routes[entry.id] = entry
                MeshLogger.relay.info("Route updated: \(entry.id.uuidString.prefix(8)) via \(entry.nextHopID.uuidString.prefix(8)), hops: \(entry.hopCount)")
            }
        } else {
            routes[entry.id] = entry
            MeshLogger.relay.info("Route added: \(entry.id.uuidString.prefix(8)) via \(entry.nextHopID.uuidString.prefix(8)), hops: \(entry.hopCount)")
        }
    }
    
    /// Get route to destination
    func getRoute(to destinationID: UUID) -> RouteEntry? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let route = routes[destinationID], route.isValid else {
            return nil
        }
        return route
    }
    
    /// Get next hop for destination
    func getNextHop(for destinationID: UUID) -> UUID? {
        getRoute(to: destinationID)?.nextHopID
    }
    
    /// Mark route as used
    func markRouteUsed(_ destinationID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        routes[destinationID]?.markUsed()
    }
    
    /// Record delivery success
    func recordSuccess(for destinationID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        routes[destinationID]?.recordSuccess()
    }
    
    /// Record delivery failure
    func recordFailure(for destinationID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        routes[destinationID]?.recordFailure()
    }
    
    /// Remove route
    func removeRoute(to destinationID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        routes.removeValue(forKey: destinationID)
        MeshLogger.relay.info("Route removed: \(destinationID.uuidString.prefix(8))")
    }
    
    /// Remove all routes using a specific next hop (link break)
    func removeRoutesVia(nextHopID: UUID) -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        
        let affected = routes.filter { $0.value.nextHopID == nextHopID }.map { $0.key }
        for id in affected {
            routes.removeValue(forKey: id)
        }
        
        if !affected.isEmpty {
            MeshLogger.relay.warning("Removed \(affected.count) routes via disconnected peer: \(nextHopID.uuidString.prefix(8))")
        }
        
        return affected
    }
    
    /// Clear all routes
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        routes.removeAll()
        reverseRoutes.removeAll()
        MeshLogger.relay.info("Routing table cleared")
    }
    
    /// Store reverse route for RREP propagation
    func setReverseRoute(from originID: UUID, via peerID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        reverseRoutes[originID] = peerID
    }
    
    /// Get reverse route (where to send RREP)
    func getReverseRoute(to originID: UUID) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return reverseRoutes[originID]
    }
    
    /// Clean up expired routes
    func cleanupExpired() {
        lock.lock()
        defer { lock.unlock() }
        
        let expiredIDs = routes.filter { $0.value.isExpired }.map { $0.key }
        for id in expiredIDs {
            routes.removeValue(forKey: id)
        }
        
        if !expiredIDs.isEmpty {
            MeshLogger.relay.debug("Cleaned up \(expiredIDs.count) expired routes")
        }
    }
    
    /// Get all valid routes
    func getAllRoutes() -> [RouteEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(routes.values.filter { $0.isValid })
    }
    
    /// Check if we have a valid route
    func hasRoute(to destinationID: UUID) -> Bool {
        getRoute(to: destinationID) != nil
    }
    
    /// Get route count
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return routes.count
    }
}
