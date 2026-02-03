# BLE Mesh Messaging System - Architecture Plan

## Overview

This document outlines the architecture for a production-grade BLE mesh messaging system supporting:
- One-to-one private messaging
- Group chats
- Multi-hop message routing
- End-to-end encryption
- Offline message queuing

---

## 1. NETWORK TOPOLOGY

### Current State (Flood-based)
```
[A] ──→ [B] ──→ [C]
         ↓
        [D]

Message from A reaches ALL devices (broadcast)
No routing intelligence
```

### Target State (Routed Mesh)
```
┌─────────────────────────────────────────────────────┐
│                    MESH NETWORK                      │
│                                                      │
│   [A]────[B]────[C]────[D]                          │
│    │      │      │      │                           │
│    └──────┼──────┘      │                           │
│           │             │                           │
│          [E]───────────[F]                          │
│                                                      │
│   A wants to message F:                             │
│   A → B → C → D → F  (shortest path)               │
│   OR                                                │
│   A → B → E → F      (alternate path)              │
└─────────────────────────────────────────────────────┘
```

---

## 2. MESSAGE TYPES

### 2.1 Control Messages (Network Layer)
```
┌─────────────────────────────────────────────────────┐
│ DISCOVERY_BEACON     │ Periodic broadcast of presence│
│ ROUTE_REQUEST (RREQ) │ Find path to destination     │
│ ROUTE_REPLY (RREP)   │ Path found response          │
│ ROUTE_ERROR (RERR)   │ Path broken notification     │
│ PEER_LIST_EXCHANGE   │ Share known peers            │
│ HEARTBEAT            │ Keep-alive signal            │
│ ACK                  │ Delivery confirmation        │
└─────────────────────────────────────────────────────┘
```

### 2.2 Data Messages (Application Layer)
```
┌─────────────────────────────────────────────────────┐
│ DIRECT_MESSAGE       │ One-to-one encrypted chat   │
│ GROUP_MESSAGE        │ Group chat (multicast)      │
│ BROADCAST_MESSAGE    │ Network-wide announcement   │
│ KEY_EXCHANGE         │ Diffie-Hellman key setup    │
│ GROUP_KEY_UPDATE     │ Rotate group encryption key │
└─────────────────────────────────────────────────────┘
```

---

## 3. DATA MODELS

### 3.1 Device Identity
```swift
struct DeviceIdentity {
    let deviceID: UUID                    // Permanent device identifier
    let publicKey: Data                   // ECDH public key (P-256)
    var displayName: String               // User-set name
    let createdAt: Date
    
    // Derived
    var shortID: String { deviceID.uuidString.prefix(8) }
}
```

### 3.2 Peer (Network Node)
```swift
struct Peer {
    let deviceID: UUID
    var displayName: String
    var publicKey: Data?
    
    // Connection state
    var connectionState: ConnectionState
    var lastSeen: Date
    var rssi: Int
    var hopCount: Int                     // 0 = direct, 1+ = via relay
    
    // Routing info
    var nextHop: UUID?                    // Who to send through
    var routeExpiry: Date?
    var alternateRoutes: [UUID]           // Backup next-hops
}
```

### 3.3 Message Envelope
```swift
struct MessageEnvelope: Codable {
    // Header (unencrypted - needed for routing)
    let messageID: UUID
    let originID: UUID                    // Original sender
    let destinationID: UUID?              // nil = broadcast
    let groupID: UUID?                    // nil = not a group message
    let messageType: MessageType
    let timestamp: Date
    var ttl: Int
    var hopPath: [UUID]                   // Track route taken
    
    // Encrypted payload
    let encryptedPayload: Data            // AES-GCM encrypted content
    let nonce: Data                       // 12 bytes for AES-GCM
    let authTag: Data                     // 16 bytes authentication tag
    
    // Signature
    let signature: Data                   // ECDSA signature of header
}
```

### 3.4 Message Content (Decrypted)
```swift
struct MessageContent: Codable {
    let text: String?
    let mediaType: MediaType?             // Future: image, voice, file
    let mediaData: Data?
    let replyToMessageID: UUID?
    let metadata: [String: String]?
}
```

### 3.5 Conversation
```swift
struct Conversation {
    let id: UUID
    let type: ConversationType            // .direct or .group
    let participantIDs: Set<UUID>
    var name: String?                     // For groups
    var groupKey: Data?                   // Symmetric key for group
    var lastMessage: Message?
    var unreadCount: Int
    var createdAt: Date
    var updatedAt: Date
}

enum ConversationType {
    case direct                           // 1:1 chat
    case group                            // Multi-party
}
```

### 3.6 Routing Table Entry
```swift
struct RouteEntry {
    let destinationID: UUID
    var nextHopID: UUID
    var hopCount: Int
    var lastUsed: Date
    var expiresAt: Date
    var reliability: Float                // 0.0 - 1.0 based on success rate
}
```

---

## 4. ROUTING PROTOCOL (AODV-inspired)

### 4.1 Route Discovery Process
```
STEP 1: A wants to send to F (not directly connected)
┌─────────────────────────────────────────────────────┐
│ A broadcasts RREQ:                                  │
│ {                                                   │
│   type: ROUTE_REQUEST,                              │
│   originID: A,                                      │
│   destinationID: F,                                 │
│   requestID: UUID,                                  │
│   hopCount: 0                                       │
│ }                                                   │
└─────────────────────────────────────────────────────┘

STEP 2: Intermediate nodes (B, C, D, E) receive RREQ
┌─────────────────────────────────────────────────────┐
│ Each node:                                          │
│ 1. Records reverse route to A                       │
│ 2. Increments hopCount                              │
│ 3. Rebroadcasts RREQ (if not seen before)          │
│ 4. If node IS destination, sends RREP              │
└─────────────────────────────────────────────────────┘

STEP 3: F receives RREQ, sends RREP back
┌─────────────────────────────────────────────────────┐
│ F sends RREP (unicast back via reverse route):     │
│ {                                                   │
│   type: ROUTE_REPLY,                                │
│   originID: F,                                      │
│   destinationID: A,                                 │
│   requestID: UUID,                                  │
│   hopCount: 0,                                      │
│   routePath: [F]                                    │
│ }                                                   │
└─────────────────────────────────────────────────────┘

STEP 4: RREP propagates back to A
┌─────────────────────────────────────────────────────┐
│ Each intermediate node:                             │
│ 1. Records forward route to F                       │
│ 2. Adds itself to routePath                        │
│ 3. Forwards RREP toward A                          │
│                                                     │
│ Final routePath at A: [F, D, C, B]                 │
│ A knows: to reach F, send via B                    │
└─────────────────────────────────────────────────────┘
```

### 4.2 Route Maintenance
```
┌─────────────────────────────────────────────────────┐
│ ROUTE TIMEOUT                                       │
│ - Routes expire after 5 minutes of inactivity      │
│ - Usage refreshes expiry                           │
│                                                     │
│ ROUTE ERROR (Link Break)                           │
│ - If B can't reach C, B sends RERR to A           │
│ - A removes route, initiates new RREQ             │
│                                                     │
│ PROACTIVE REFRESH                                   │
│ - Before expiry, re-discover routes to active      │
│   conversations                                     │
└─────────────────────────────────────────────────────┘
```

---

## 5. ENCRYPTION ARCHITECTURE

### 5.1 Key Hierarchy
```
┌─────────────────────────────────────────────────────┐
│                  IDENTITY KEY                        │
│            (ECDH P-256, permanent)                  │
│                      │                              │
│         ┌───────────┴───────────┐                  │
│         ▼                       ▼                   │
│   SESSION KEYS              GROUP KEYS              │
│  (per conversation)        (per group)              │
│         │                       │                   │
│         ▼                       ▼                   │
│   MESSAGE KEYS              MESSAGE KEYS            │
│  (derived per msg)         (derived per msg)        │
└─────────────────────────────────────────────────────┘
```

### 5.2 Direct Message Encryption (X3DH + Double Ratchet simplified)
```
INITIAL KEY EXCHANGE:
┌─────────────────────────────────────────────────────┐
│ 1. A and B exchange public keys (during discovery) │
│ 2. A computes: sharedSecret = ECDH(A.private, B.public)
│ 3. B computes: sharedSecret = ECDH(B.private, A.public)
│ 4. Both derive: sessionKey = HKDF(sharedSecret, salt)
└─────────────────────────────────────────────────────┘

MESSAGE ENCRYPTION:
┌─────────────────────────────────────────────────────┐
│ 1. Generate random nonce (12 bytes)                │
│ 2. Derive messageKey = HKDF(sessionKey, nonce)     │
│ 3. Encrypt: AES-256-GCM(messageKey, nonce, plaintext)
│ 4. Output: nonce || ciphertext || authTag          │
└─────────────────────────────────────────────────────┘
```

### 5.3 Group Message Encryption
```
GROUP KEY SETUP:
┌─────────────────────────────────────────────────────┐
│ 1. Group creator generates random groupKey (32 bytes)
│ 2. For each member:                                 │
│    - Encrypt groupKey with pairwise sessionKey     │
│    - Send encrypted groupKey via direct message    │
│ 3. All members now have groupKey                   │
└─────────────────────────────────────────────────────┘

GROUP MESSAGE:
┌─────────────────────────────────────────────────────┐
│ 1. Sender encrypts message with groupKey           │
│ 2. Message sent to ALL group members (multicast)   │
│ 3. Each member decrypts with groupKey              │
│                                                     │
│ KEY ROTATION:                                       │
│ - When member leaves: generate new groupKey        │
│ - Distribute to remaining members                  │
└─────────────────────────────────────────────────────┘
```

---

## 6. SYSTEM ARCHITECTURE

### 6.1 Layer Diagram
```
┌─────────────────────────────────────────────────────┐
│                   UI LAYER                          │
│  ┌──────────┐ ┌──────────┐ ┌──────────────────┐    │
│  │ ChatView │ │ PeersView│ │ ConversationList │    │
│  └──────────┘ └──────────┘ └──────────────────┘    │
├─────────────────────────────────────────────────────┤
│                VIEWMODEL LAYER                      │
│  ┌──────────────────────────────────────────────┐  │
│  │            ChatViewModel                      │  │
│  │  - conversations, messages, peers            │  │
│  └──────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────┤
│                 SERVICE LAYER                       │
│  ┌────────────┐ ┌────────────┐ ┌────────────────┐  │
│  │ Messaging  │ │  Routing   │ │   Encryption   │  │
│  │  Service   │ │  Service   │ │    Service     │  │
│  └────────────┘ └────────────┘ └────────────────┘  │
│  ┌────────────┐ ┌────────────┐ ┌────────────────┐  │
│  │   Group    │ │   Peer     │ │   Storage      │  │
│  │  Service   │ │  Service   │ │   Service      │  │
│  └────────────┘ └────────────┘ └────────────────┘  │
├─────────────────────────────────────────────────────┤
│                TRANSPORT LAYER                      │
│  ┌──────────────────────────────────────────────┐  │
│  │           BluetoothManager                    │  │
│  │  - Central + Peripheral roles                │  │
│  │  - Connection management                     │  │
│  │  - Chunking/reassembly                       │  │
│  └──────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────┤
│                  DATA LAYER                         │
│  ┌────────────┐ ┌────────────┐ ┌────────────────┐  │
│  │  Messages  │ │   Peers    │ │    Routes      │  │
│  │   Store    │ │   Store    │ │    Store       │  │
│  └────────────┘ └────────────┘ └────────────────┘  │
│  ┌────────────┐ ┌────────────┐                     │
│  │   Keys     │ │   Groups   │                     │
│  │   Store    │ │   Store    │                     │
│  └────────────┘ └────────────┘                     │
└─────────────────────────────────────────────────────┘
```

### 6.2 File Structure
```
BLEMesh/
├── App/
│   └── BLEMeshApp.swift
│
├── Core/
│   ├── Constants.swift
│   ├── Logger.swift
│   └── Errors.swift
│
├── Models/
│   ├── Identity/
│   │   ├── DeviceIdentity.swift
│   │   └── Peer.swift
│   ├── Messaging/
│   │   ├── MessageEnvelope.swift
│   │   ├── MessageContent.swift
│   │   ├── Conversation.swift
│   │   └── MessageChunk.swift
│   ├── Routing/
│   │   ├── RouteEntry.swift
│   │   ├── RouteRequest.swift
│   │   └── RouteReply.swift
│   └── Groups/
│       ├── Group.swift
│       └── GroupMember.swift
│
├── Services/
│   ├── Bluetooth/
│   │   ├── BluetoothManager.swift
│   │   ├── CentralManager.swift
│   │   └── PeripheralManager.swift
│   ├── Routing/
│   │   ├── RoutingService.swift
│   │   ├── RouteDiscovery.swift
│   │   └── RoutingTable.swift
│   ├── Messaging/
│   │   ├── MessagingService.swift
│   │   ├── MessageQueue.swift
│   │   └── DeliveryTracker.swift
│   ├── Encryption/
│   │   ├── EncryptionService.swift
│   │   ├── KeyExchange.swift
│   │   └── KeyStore.swift
│   ├── Groups/
│   │   ├── GroupService.swift
│   │   └── GroupKeyManager.swift
│   └── Storage/
│       ├── StorageService.swift
│       ├── MessageStore.swift
│       └── PeerStore.swift
│
├── ViewModels/
│   ├── ChatViewModel.swift
│   ├── ConversationListViewModel.swift
│   ├── PeersViewModel.swift
│   └── GroupViewModel.swift
│
└── Views/
    ├── Main/
    │   └── ContentView.swift
    ├── Chat/
    │   ├── ChatView.swift
    │   ├── MessageBubble.swift
    │   └── MessageInput.swift
    ├── Conversations/
    │   ├── ConversationListView.swift
    │   └── ConversationRow.swift
    ├── Peers/
    │   ├── PeersView.swift
    │   └── PeerRow.swift
    ├── Groups/
    │   ├── NewGroupView.swift
    │   └── GroupSettingsView.swift
    └── Debug/
        └── DebugView.swift
```

---

## 7. MESSAGE FLOW DIAGRAMS

### 7.1 One-to-One Message (Direct Connection)
```
┌───────┐                              ┌───────┐
│   A   │                              │   B   │
└───┬───┘                              └───┬───┘
    │                                      │
    │  1. Lookup sessionKey for B          │
    │                                      │
    │  2. Encrypt message                  │
    │                                      │
    │  3. Create envelope                  │
    │     (destID: B, encrypted payload)   │
    │                                      │
    │  4. Send via BLE ──────────────────► │
    │                                      │
    │                     5. Verify signature
    │                                      │
    │                     6. Decrypt with sessionKey
    │                                      │
    │                     7. Display message
    │                                      │
    │  8. ◄─────────────── ACK ────────── │
    │                                      │
    │  9. Mark as delivered                │
    │                                      │
```

### 7.2 One-to-One Message (Multi-Hop)
```
┌───────┐        ┌───────┐        ┌───────┐
│   A   │        │   B   │        │   C   │
└───┬───┘        └───┬───┘        └───┬───┘
    │                │                │
    │ 1. No direct route to C         │
    │                │                │
    │ 2. Check routing table          │
    │    Route to C: via B            │
    │                │                │
    │ 3. Encrypt for C (E2E)          │
    │                │                │
    │ 4. Send to B ──►                │
    │   (destID: C, nextHop: B)       │
    │                │                │
    │                │ 5. B checks: not for me
    │                │    Forward to dest   │
    │                │                │
    │                │ 6. ────────────►
    │                │                │
    │                │     7. C decrypts (E2E)
    │                │                │
    │                │     8. ◄── ACK ──
    │                │                │
    │  9. ◄── ACK ───┤                │
    │                │                │
```

### 7.3 Group Message
```
┌───────┐     ┌───────┐     ┌───────┐     ┌───────┐
│   A   │     │   B   │     │   C   │     │   D   │
└───┬───┘     └───┬───┘     └───┬───┘     └───┬───┘
    │             │             │             │
    │ Group: [A, B, C, D]       │             │
    │ A sends to group          │             │
    │             │             │             │
    │ 1. Encrypt with groupKey  │             │
    │             │             │             │
    │ 2. Create envelope        │             │
    │    (groupID: G, destID: null)           │
    │             │             │             │
    │ 3. Lookup routes for B, C, D            │
    │             │             │             │
    │ 4. ────────►│             │             │
    │    (via direct)           │             │
    │             │             │             │
    │ 5. ─────────┼────────────►│             │
    │             │  (via relay)│             │
    │             │             │             │
    │ 6. ─────────┼─────────────┼────────────►│
    │             │             │  (via relay)│
    │             │             │             │
    │   All decrypt with groupKey             │
    │             │             │             │
```

---

## 8. IMPLEMENTATION PHASES

### Phase 1: Foundation (Current + Fixes)
```
Duration: Done
─────────────────────────────────────────────
✅ Dual-role BLE (Central + Peripheral)
✅ Device discovery
✅ Basic messaging (broadcast)
✅ Message chunking
✅ TTL-based flooding
✅ Duplicate prevention
```

### Phase 2: Routing Layer
```
Duration: DONE ✅
─────────────────────────────────────────────
✅ Route Request (RREQ) broadcast
✅ Route Reply (RREP) unicast
✅ Routing table with expiry
✅ Route error handling
✅ Next-hop forwarding
✅ Multi-path support
```

### Phase 3: Encryption
```
Duration: DONE ✅
─────────────────────────────────────────────
✅ Device identity (keypair generation)
✅ ECDH key exchange
✅ Session key derivation
✅ AES-GCM message encryption
✅ Key storage (Keychain)
✅ ECDSA signature generation
✅ Signature verification on incoming messages
```

### Phase 4: Direct Messaging
```
Duration: DONE ✅
─────────────────────────────────────────────
✅ Conversation model
✅ Destination picker UI
✅ Chat UI improvements
✅ 1:1 encrypted chat
✅ Delivery acknowledgments (ACK)
✅ Delivery status tracking (sent → delivered → read)
✅ Message persistence (SwiftData)
✅ Conversation list UI
```

### Phase 5: Group Messaging
```
Duration: DONE ✅
─────────────────────────────────────────────
✅ Group model in Conversation
✅ Group key generation
✅ Key rotation on member leave
✅ Key distribution to members
✅ Group message routing
✅ Member management UI
✅ Group UI (create, leave, view)
```

### Phase 6: Reliability & Polish
```
Duration: DONE ✅
─────────────────────────────────────────────
✅ Offline message queue (OfflineQueueService)
✅ Retry with exponential backoff
✅ Read receipts
□ Typing indicators (future)
□ Background operation (requires entitlements)
□ Battery optimization (future)
□ Performance tuning (future)
```

---

## 9. SECURITY CONSIDERATIONS

### 9.1 Threat Model
```
┌─────────────────────────────────────────────────────┐
│ THREAT                │ MITIGATION                  │
├───────────────────────┼─────────────────────────────┤
│ Eavesdropping         │ E2E encryption (AES-GCM)   │
│ Message tampering     │ AEAD + signatures          │
│ Replay attacks        │ Nonce + message ID         │
│ Impersonation         │ Public key verification    │
│ Man-in-the-middle     │ Key fingerprint comparison │
│ Routing manipulation  │ Signed route messages      │
│ Denial of service     │ Rate limiting, TTL         │
└─────────────────────────────────────────────────────┘
```

### 9.2 Key Management
```
┌─────────────────────────────────────────────────────┐
│ KEY TYPE          │ STORAGE        │ ROTATION      │
├───────────────────┼────────────────┼───────────────┤
│ Identity keypair  │ Secure Enclave │ Never         │
│ Session keys      │ Keychain       │ Per session   │
│ Group keys        │ Keychain       │ On membership │
│                   │                │ change        │
└─────────────────────────────────────────────────────┘
```

---

## 10. LIMITATIONS & FUTURE WORK

### Current Limitations
- BLE range: ~10-100 meters
- Max 7 simultaneous connections (iOS limit)
- No internet bridge
- No cross-platform (iOS only)

### Future Enhancements
- WiFi Direct for longer range
- Internet gateway nodes
- Android companion app
- File/media transfer
- Voice messages
- Push notifications via relay

---

## DECISION: Proceed?

This architecture supports:
✅ One-to-one encrypted messaging
✅ Group chats with shared keys
✅ Multi-hop routing (message reaches far devices)
✅ End-to-end encryption
✅ Offline resilience

**Estimated total implementation: ~10-14 days**

**Shall I proceed with Phase 2 (Routing Layer) first?**
