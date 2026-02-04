# Multi-Hop Messaging - Implementation Fixes

## Gap 1: Device Name Uniqueness ✅ EASY TO FIX

### Current Problem:
User can't distinguish between multiple "iPhone 3" devices.

### Solution: Add User-Editable Device Nicknames

**Step 1: Update Peer Model**

```swift
// BLEMesh/Models/Peer.swift

struct Peer: Identifiable, ObservableObject {
    let id: UUID
    @Published var name: String              // Device name from BLE
    @Published var nickname: String?         // NEW: User-assigned nickname
    @Published var rssi: Int = -99
    
    // Display name = nickname or device name
    var displayName: String {
        nickname ?? name
    }
    
    // Full identifier for debugging
    var fullIdentifier: String {
        let uuidShort = id.uuidString.prefix(8)
        if let nick = nickname {
            return "\(nick) (\(name) / \(uuidShort))"
        } else {
            return "\(name) / \(uuidShort)"
        }
    }
}
```

**Step 2: Update UI to Show Full Identifier**

```swift
// BLEMesh/Views/Chat/ChatView.swift - Destination Picker

// BEFORE:
Text("iPhone 3")

// AFTER:
VStack(alignment: .leading) {
    Text(peer.displayName)
        .font(.body)
    
    HStack {
        Text(peer.id.uuidString.prefix(8))
            .font(.caption)
            .foregroundColor(.gray)
        
        if let nick = peer.nickname {
            Text("(User: \(nick))")
                .font(.caption2)
                .foregroundColor(.blue)
        }
    }
}
```

**Step 3: Add Settings to Customize Device Name**

```swift
// BLEMesh/Views/Settings/SettingsView.swift

Section("Device Identification") {
    TextField("My Device Nickname", text: $deviceNickname)
        .textFieldStyle(.roundedBorder)
    
    Text("This nickname helps others identify you in the mesh")
        .font(.caption)
        .foregroundColor(.gray)
    
    // Show my device info
    VStack(alignment: .leading) {
        Text("My Device Info:")
            .font(.headline)
        
        Text("Device ID: \(myDeviceID.uuidString.prefix(8))")
            .font(.caption)
            .monospaced()
        
        Text("Public Key Hash: \(getPublicKeyFingerprint())")
            .font(.caption)
            .monospaced()
    }
}
```

**Estimated time: 30 minutes**

---

## Gap 2: Route Quality Metrics ✅ MEDIUM FIX

### Current Problem:
No indication of route quality, reliability, or estimated delivery time.

### Solution: Add Route Metadata to RoutingTable

**Step 1: Enhance RouteEntry**

```swift
// BLEMesh/Models/Routing/RoutingTable.swift

struct RouteEntry: Codable {
    let destinationID: UUID
    let nextHopID: UUID
    let hopCount: Int
    let timestamp: Date
    
    // NEW: Route quality metrics
    var successCount: Int = 0          // How many messages delivered
    var failureCount: Int = 0          // How many timed out
    var averageLatency: Double = 0     // milliseconds
    var lastSuccessTime: Date?
    var lastFailureTime: Date?
    
    // Computed properties
    var successRate: Double {
        let total = Double(successCount + failureCount)
        guard total > 0 else { return 0.0 }
        return Double(successCount) / total
    }
    
    var estimatedLatency: Double {
        // Each hop ~20-50ms
        let hopLatency = Double(hopCount) * 35.0
        // Add overhead: 10ms
        return hopLatency + 10.0
    }
    
    var qualityScore: String {
        switch successRate {
        case 0.9...1.0: return "Excellent"
        case 0.7..<0.9: return "Good"
        case 0.5..<0.7: return "Fair"
        case 0.0..<0.5: return "Poor"
        default: return "Unknown"
        }
    }
    
    var ttlSeconds: Int {
        let elapsedSeconds = Int(-timestamp.timeIntervalSinceNow)
        let maxTTL = 300  // 5 minutes
        let remaining = maxTTL - elapsedSeconds
        return max(0, remaining)
    }
    
    var isExpired: Bool {
        return ttlSeconds <= 0
    }
}
```

**Step 2: Track Delivery Success in MessageRelayService**

```swift
// BLEMesh/Services/MessageRelayService.swift

func recordMessageDelivery(
    to destinationID: UUID,
    success: Bool,
    latency: Double
) {
    lock.lock()
    defer { lock.unlock() }
    
    if var route = routingTable.getRoute(to: destinationID) {
        if success {
            route.successCount += 1
            route.lastSuccessTime = Date()
            route.averageLatency = (route.averageLatency * Double(route.successCount - 1) + latency) / Double(route.successCount)
        } else {
            route.failureCount += 1
            route.lastFailureTime = Date()
        }
        
        routingTable.updateRoute(route)
    }
}
```

**Step 3: Update UI to Show Quality**

```swift
// BLEMesh/Views/Chat/ChatView.swift

Section("Routable Peers") {
    ForEach(routablePeers) { peer in
        VStack(alignment: .leading) {
            HStack {
                Circle()
                    .fill(qualityColor(peer.route.successRate))
                    .frame(width: 8, height: 8)
                
                VStack(alignment: .leading) {
                    Text(peer.displayName)
                        .font(.body)
                    
                    HStack {
                        Text("\(peer.route.hopCount) hops")
                            .font(.caption)
                        
                        Text("•")
                            .font(.caption)
                        
                        Text(peer.route.qualityScore)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("•")
                            .font(.caption)
                        
                        Text("~\(Int(peer.route.estimatedLatency))ms")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(peer.route.successRate * 100))%")
                        .font(.caption2)
                        .fontWeight(.semibold)
                    
                    Text("delivered")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectPeer(peer)
        }
    }
}

private func qualityColor(_ successRate: Double) -> Color {
    switch successRate {
    case 0.9...1.0: return .green
    case 0.7..<0.9: return .yellow
    case 0.5..<0.7: return .orange
    default: return .red
    }
}
```

**Estimated time: 2-3 hours**

---

## Gap 3: Hop-by-Hop Delivery Status ✅ HIGH PRIORITY

### Current Problem:
User doesn't know if message reached Device B or got lost there.

### Solution: Track Each Hop with Acknowledgments

**Step 1: Add Delivery Status to Message Model**

```swift
// BLEMesh/Models/Message.swift

struct MeshMessage: Identifiable, Codable {
    let id: UUID
    let content: String
    let senderID: UUID
    let senderName: String
    let destinationID: UUID?
    let conversationID: UUID?
    let timestamp: Date
    let isEncrypted: Bool
    let isGroupMessage: Bool
    
    // NEW: Delivery tracking
    @Published var deliveryStatus: DeliveryStatus = .pending
    @Published var deliveryPath: [DeliveryHop] = []
    
    enum DeliveryStatus: String, Codable {
        case pending      // Not yet sent
        case sentToA      // Sent from Device A
        case sentToB      // Relayed through Device B
        case sentToC      // Reached Device C
        case delivered    // C confirmed receipt
        case failed       // Failed at some hop
        case timedOut     // No response
    }
}

struct DeliveryHop: Codable {
    let deviceID: UUID
    let deviceName: String
    let status: HopStatus
    let timestamp: Date
    let latency: Double?  // milliseconds
    
    enum HopStatus: String, Codable {
        case pending      // Waiting for this hop
        case sent         // Sent to this device
        case received     // Device received
        case relayed      // Device relayed forward
        case failed       // Failed at this device
    }
}
```

**Step 2: Track Hops in MessageRelayService**

```swift
// BLEMesh/Services/MessageRelayService.swift

// When sending message from A to C via B:

// Hop 1: A → B
let hopA = DeliveryHop(
    deviceID: myID,
    deviceName: "Device A",
    status: .sent,
    timestamp: Date(),
    latency: 0
)
message.deliveryPath.append(hopA)

// When B receives and forwards:
// Hop 2: B received
let hopBReceived = DeliveryHop(
    deviceID: relayPeer.id,
    deviceName: relayPeer.name,
    status: .received,
    timestamp: Date(),
    latency: Date().timeIntervalSince(hopA.timestamp) * 1000
)
message.deliveryPath.append(hopBReceived)

// Hop 2b: B relayed
let hopBRelayed = DeliveryHop(
    deviceID: relayPeer.id,
    deviceName: relayPeer.name,
    status: .relayed,
    timestamp: Date(),
    latency: nil
)
message.deliveryPath.append(hopBRelayed)

// When C receives:
// Hop 3: C received
let hopC = DeliveryHop(
    deviceID: destinationPeer.id,
    deviceName: destinationPeer.name,
    status: .received,
    timestamp: Date(),
    latency: Date().timeIntervalSince(message.timestamp) * 1000
)
message.deliveryPath.append(hopC)
message.deliveryStatus = .delivered
```

**Step 3: Update UI to Show Delivery Path**

```swift
// BLEMesh/Views/Chat/ChatView.swift

VStack(alignment: .leading, spacing: 8) {
    Text(message.content)
        .padding(8)
        .background(isFromMe ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
        .cornerRadius(8)
    
    // NEW: Delivery status
    HStack(spacing: 4) {
        Image(systemName: deliveryIcon(message.deliveryStatus))
            .font(.caption)
        
        Text(message.deliveryStatus.rawValue)
            .font(.caption)
            .foregroundColor(.secondary)
        
        if let latency = message.deliveryPath.last?.latency {
            Text("~\(Int(latency))ms")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    // Show delivery path if multi-hop
    if message.deliveryPath.count > 2 {
        DisclosureGroup("Delivery Path") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.deliveryPath.enumerated()), id: \.offset) { index, hop in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(hopStatusColor(hop.status))
                            .frame(width: 8, height: 8)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hop.deviceName)
                                .font(.caption)
                                .fontWeight(.semibold)
                            
                            HStack {
                                Text(hop.status.rawValue)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                
                                if let latency = hop.latency {
                                    Text("~\(Int(latency))ms")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        
                        Spacer()
                        
                        Text(hop.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    
                    if index < message.deliveryPath.count - 1 {
                        HStack {
                            VStack(spacing: 0) {
                                Divider()
                                    .frame(height: 1)
                                    .padding(.vertical, 2)
                            }
                            .frame(width: 4, height: 16)
                            .padding(.leading, 3)
                            
                            Spacer()
                        }
                    }
                }
            }
        }
        .font(.caption)
    }
}

private func deliveryIcon(_ status: MeshMessage.DeliveryStatus) -> String {
    switch status {
    case .pending: return "clock"
    case .sentToA, .sentToB, .sentToC: return "paperplane"
    case .delivered: return "checkmark.circle.fill"
    case .failed, .timedOut: return "xmark.circle.fill"
    }
}

private func hopStatusColor(_ status: DeliveryHop.HopStatus) -> Color {
    switch status {
    case .pending: return .gray
    case .sent, .received, .relayed: return .green
    case .failed: return .red
    }
}
```

**Estimated time: 3-4 hours**

---

## Gap 4: Route Invalidation on Failure ✅ HIGH PRIORITY

### Current Problem:
Cached route stays valid even if intermediate device goes offline.

### Solution: Implement Route TTL and Failure Tracking

**Step 1: Update RoutingService to Invalidate Routes**

```swift
// BLEMesh/Services/RoutingService.swift

func handleMessageDeliveryFailure(
    destinationID: UUID,
    failedAtHop: UUID,
    error: RoutingError
) {
    lock.lock()
    defer { lock.unlock() }
    
    // Mark route as failed
    if var route = routingTable.getRoute(to: destinationID) {
        route.failureCount += 1
        route.lastFailureTime = Date()
        
        // If too many failures, remove route
        if route.failureCount > 3 || route.successRate < 0.3 {
            routingTable.removeRoute(to: destinationID)
            
            // Trigger new route discovery
            Task {
                _ = try? await discoverRoute(to: destinationID)
            }
        } else {
            routingTable.updateRoute(route)
        }
    }
    
    // Mark neighbor as potentially offline
    if failedAtHop == routingTable.getRoute(to: destinationID)?.nextHopID {
        // Try alternative route if exists
        // Or trigger RREQ to find new route
    }
}
```

**Step 2: Auto-refresh Routes Periodically**

```swift
// BLEMesh/Services/RoutingService.swift

private func startRouteMaintenanceTimer() {
    routeMaintenanceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
        self.maintainRoutes()
    }
}

private func maintainRoutes() {
    lock.lock()
    let expiredRoutes = routingTable.routes.filter { $0.value.isExpired }
    lock.unlock()
    
    for (destinationID, _) in expiredRoutes {
        // Remove expired routes
        routingTable.removeRoute(to: destinationID)
        
        // Rediscover important routes
        if isFrequentlyUsed(destinationID) {
            Task {
                _ = try? await discoverRoute(to: destinationID)
            }
        }
    }
}
```

**Step 3: Update UI to Reflect Route Validity**

```swift
// BLEMesh/Views/Chat/ChatView.swift

if let route = peer.route {
    HStack {
        Image(systemName: route.ttlSeconds > 60 ? "checkmark.circle" : "exclamationmark.circle")
            .foregroundColor(route.ttlSeconds > 60 ? .green : .yellow)
        
        Text("\(route.hopCount) hops")
            .font(.caption)
        
        Text("•")
        
        if route.ttlSeconds < 30 {
            Text("Route expiring soon")
                .font(.caption2)
                .foregroundColor(.orange)
        } else {
            Text("~\(Int(route.estimatedLatency))ms")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
```

**Estimated time: 2-3 hours**

---

## Summary: Implementation Priority

| Gap | Severity | Time | Prerequisite |
|-----|----------|------|--------------|
| Device nicknames | Medium | 30 min | None |
| Route quality metrics | Medium | 2-3 hr | None |
| Hop-by-hop delivery | **HIGH** | 3-4 hr | Route quality |
| Route invalidation | **HIGH** | 2-3 hr | None |

**Total: 8-12 hours to implement all fixes**

**Recommended Order:**
1. Device nicknames (quick win, 30 min)
2. Route invalidation (prevents messaging to offline devices)
3. Hop-by-hop delivery (critical UX)
4. Route quality metrics (nice to have)

Would you like me to implement these fixes?

