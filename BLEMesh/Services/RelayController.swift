import Foundation

/// Relay decision controller based on bitchat's relay logic
/// Determines whether and how to relay messages based on TTL, type, and network conditions
struct RelayController {
    
    /// Decision result from relay evaluation
    struct RelayDecision {
        let shouldRelay: Bool
        let delayMs: Int
        let newTTL: Int  // Changed from UInt8 to match MessageEnvelope.ttl
    }
    
    /// Decide whether and how to relay a packet
    /// - Parameters:
    ///   - ttl: Time-to-live of the packet
    ///   - senderIsSelf: Whether we sent this packet originally
    ///   - isEncrypted: Whether packet is encrypted
    ///   - isDirectedEncrypted: Whether it's a directed encrypted message
    ///   - isFragment: Whether packet is a fragment
    ///   - isDirectedFragment: Whether it's a directed fragment
    ///   - isHandshake: Whether it's a handshake packet
    ///   - isAnnounce: Whether it's an announcement
    ///   - degree: Current network degree (number of connected peers)
    ///   - highDegreeThreshold: Threshold for high-degree network
    /// - Returns: RelayDecision with shouldRelay, delay, and new TTL
    static func decide(
        ttl: Int,
        senderIsSelf: Bool,
        isEncrypted: Bool,
        isDirectedEncrypted: Bool,
        isFragment: Bool,
        isDirectedFragment: Bool,
        isHandshake: Bool,
        isAnnounce: Bool,
        degree: Int,
        highDegreeThreshold: Int
    ) -> RelayDecision {
        
        // Never relay our own packets
        if senderIsSelf {
            return RelayDecision(shouldRelay: false, delayMs: 0, newTTL: 0)
        }
        
        // Never relay if TTL is exhausted
        guard ttl > 1 else {
            return RelayDecision(shouldRelay: false, delayMs: 0, newTTL: 0)
        }
        
        // Don't relay handshakes (they establish direct sessions)
        if isHandshake {
            return RelayDecision(shouldRelay: false, delayMs: 0, newTTL: 0)
        }
        
        // Don't relay directed encrypted messages unless we're routing them
        // (This is handled separately in routing logic)
        if isDirectedEncrypted {
            return RelayDecision(shouldRelay: false, delayMs: 0, newTTL: 0)
        }
        
        // Calculate new TTL (decrement by 1)
        let newTTL = ttl - 1
        
        // Calculate relay jitter based on network density
        let delayMs = calculateJitter(degree: degree, highDegreeThreshold: highDegreeThreshold)
        
        // Relay broadcasts, announces, and directed fragments
        let shouldRelay = isAnnounce || isFragment || !isEncrypted
        
        return RelayDecision(
            shouldRelay: shouldRelay,
            delayMs: delayMs,
            newTTL: newTTL
        )
    }
    
    /// Calculate jitter delay based on network density
    /// - Parameters:
    ///   - degree: Number of connected peers
    ///   - highDegreeThreshold: Threshold for high-degree network
    /// - Returns: Delay in milliseconds
    private static func calculateJitter(degree: Int, highDegreeThreshold: Int) -> Int {
        // Base jitter range
        let minJitter = 10
        let maxJitter = 50
        
        // Increase jitter in denser networks to reduce collisions
        if degree >= highDegreeThreshold {
            // High density: 30-80ms
            return Int.random(in: 30...80)
        } else if degree >= 3 {
            // Medium density: 20-60ms
            return Int.random(in: 20...60)
        } else {
            // Low density: 10-50ms
            return Int.random(in: minJitter...maxJitter)
        }
    }
}
