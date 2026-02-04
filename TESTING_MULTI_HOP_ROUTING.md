# BLE Mesh - Multi-Hop Routing & Encryption Verification Guide

## Testing Strategy: 3-Device Scenario

```
Device A (Sender)  ←→  Device B (Relay)  ←→  Device C (Recipient)
   (Direct range)          (No direct range)        (Out of range)
   
Message: "Hello" from A to C
- Hops through B
- B relays but CANNOT decrypt message
- C receives and decrypts
```

---

## Test Setup

### Requirements
- **3 iPhones/iPads** (minimum)
- **All running BLE Mesh app**
- **All with Bluetooth enabled**
- **Network without internet** (to isolate from other devices)

### Physical Arrangement
```
[Device A]  ←← 10m ←→ [Device B]  ←← 10m ←→ [Device C]
(Sender)    (RELAY)            (Recipient)
            (OUT OF RANGE FROM A and C)
```

**Key:** Device B must be in range of both A and C, but A and C should NOT be in direct range.

---

## How Destination Picker Works (Critical Understanding)

### Why You Can Select Device C Even Though It's Out of Range

**The Destination Picker shows TWO types of devices:**

```
┌─────────────────────────────────────┐
│  DESTINATION PICKER (on Device A)   │
├─────────────────────────────────────┤
│ [Broadcast to All] ← No encryption  │
│                                     │
│ DIRECT PEERS (in BLE range):        │
│  ├─ Device B (1 hop, direct)        │
│                                     │
│ ROUTABLE PEERS (via mesh):          │
│  ├─ Device C (2 hops) ← SELECT THIS │
│                                     │
│ GROUPS:                             │
│  ├─ (none yet)                      │
└─────────────────────────────────────┘
```

**What's happening:**
1. Device B is in range of both A and C
2. Device B tells Device A: "I know about Device C"
3. Device A's routing table now has entry for C
4. Device C appears in the "ROUTABLE PEERS" section with hop count
5. You can select it even though you can't directly reach it

**The key phrase you'll see in the picker:**
- `Device C (2 hops)` ← This indicates it's reachable via routing, not direct BLE
- `Device B (1 hop)` ← This would be direct (in BLE range)

### How the Routing Discovery Happens (Behind the Scenes)

```
Timeline:
─────────────────────────────────────────────────────────

1. [Device A starts]
   - Opens Messages tab
   - Scans for peers
   - Finds: Device B (direct)
   - Routing table: A ↔ B (1 hop)

2. [Device B receives route request]
   - B has direct connection to both A and C
   - B forwards route info to A
   - Tells A: "Device C is reachable through me (2 hops)"

3. [Device A updates routing table]
   - New entry: A → C (via B, 2 hops)
   - Device C now appears in destination picker
   - You can now select Device C

4. [You send message]
   - Select "Device C (2 hops)"
   - Message gets routed A → B → C
```

---

## Before Test: Route Discovery Must Happen First

**Important:** Before Device C appears in the picker, the routing must be discovered.

**On Device A, to force route discovery:**
1. Open **Network** tab
2. Look at "Mesh Network" section
3. If Device C is NOT listed, tap **"Force Route Discovery"** button
4. Wait 2-3 seconds
5. Device C should appear with hop count
6. Now open **Messages** tab
7. Tap destination picker
8. Device C should be selectable under "ROUTABLE PEERS"

**If Device C doesn't appear:**
- Device B might not be relaying route info
- Check Device B's Bluetooth is on
- Check Device C's Bluetooth is on
- Make sure B can see both A and C

---

### Step 1: Verify Initial State
**On Device A:**
- Open **Network** tab
- Confirm Device B shows in "Discovered Peers"
- Confirm Device C does NOT show in "Discovered Peers" (out of range)
- Confirm Device C shows in "Mesh Network" (reachable via routing)

**On Device B:**
- Should see both A and C in "Discovered Peers"

**On Device C:**
- Confirm Device A does NOT show in "Discovered Peers"
- Confirm Device A shows in "Mesh Network" with hop count > 1

### Step 2: Send Test Message
**On Device A:**
1. Open **Messages** tab
2. Tap destination picker button
3. **Device C will appear in two ways:**
   - **Under "Direct Peers"** section if in direct range (won't be - out of range)
   - **Under "Routable Peers" section** (from routing table) ← **SELECT FROM HERE**
   - Device C should show: `"Device C (2 hops)"`
4. Tap to select Device C
5. Type message: `"Test hop from A through B to C"`
6. **ENSURE ENCRYPTION IS ENABLED** (lock icon should be green/filled)
7. Tap send

**Why Device C appears even though out of range:**
- The destination picker shows BOTH discovered peers (direct BLE) AND routable peers (via routing table)
- When Device B discovers Device C earlier, it shares this info with Device A via the mesh
- Device A's routing table now knows Device C is reachable via Device B
- So Device C appears in the picker with hop count "2 hops"

### Step 3: Monitor Routing on Device B
**On Device B:**
1. Open **Debug** tab immediately
2. Watch for:
   - `messagesRelayed` counter increases
   - Message appears in the list (or you can add logging)
   - **DO NOT look at the message content in relay** - it should be encrypted

### Step 4: Verify Message Received
**On Device C:**
1. Open **Messages** tab
2. Confirm message arrives from Device A
3. Read: `"Test hop from A through B to C"`
4. Timestamp should match when A sent it

### Step 5: Monitor Network Tab Stats
**Check all three devices' Network tab:**
- Device A: See Device C marked with hop count (e.g., "2 hops")
- Device B: See both A and C as direct peers
- Device C: See Device A marked with hop count

---

## Verification Checklist

### ✅ Message Delivery
- [ ] Message sent from Device A
- [ ] Message relayed through Device B
- [ ] Message received on Device C with correct content
- [ ] Message timestamp is accurate

### ✅ Encryption (Intermediate Node Blindness)
- [ ] Device B's relay operation uses MessageEnvelope
- [ ] Device B **cannot** decrypt the encrypted payload
- [ ] Device C **can** decrypt and read the message
- [ ] Check logs: No "decryption failed" errors on Device B

### ✅ Hop Counting
- [ ] Device A → Device C shows hop count = 2
- [ ] Message TTL decrements correctly
- [ ] Route entry in Device B's routing table shows correct hop count

### ✅ Routing Table Updates
- [ ] Device A discovers route to Device C
- [ ] Route shows next hop as Device B
- [ ] Route caches and doesn't flood network

---

## What to Look At in the Code During Testing

### 1. **Verify Encryption Barrier** (EncryptionService.swift)
```swift
// Device B CANNOT decrypt this:
func decryptMessage(_ payload: EncryptedPayload, from peerID: UUID) throws -> String

// Why? Because:
// - Device A encrypted with Device C's public key
// - Device B only has Device A and Device C's public keys
// - Device B doesn't have the derived session key with Device C
// - Decryption fails → message stays encrypted for relay
```

### 2. **Verify Relay Logic** (MessageRelayService.swift)
```swift
// Device B does this when relaying:
func relayMessage(_ envelope: MessageEnvelope) {
    // 1. Check if it's for B (destination == B's ID) → deliver locally
    // 2. Otherwise → relay to neighbors with TTL-1
    // 3. NEVER decrypt payload for relay
    // 4. Forward envelope as-is (encrypted payload intact)
}
```

### 3. **Check Debug Statistics** (ContentView.swift - DebugView)
Look at these counters while message hops:
```
messagesReceived:  +1 (on Device C)
messagesRelayed:   +1 (on Device B)
messagesSent:      +1 (on Device A)
duplicatesBlocked: 0 (routing cache working)
```

### 4. **Verify Route Discovery** (RoutingService.swift)
```swift
// Device A discovers route to Device C:
func discoverRoute(to destinationID: UUID) {
    // 1. Sends RREQ (Route Request) broadcast
    // 2. Device B receives RREQ, forwards it (still no decryption)
    // 3. Device C receives RREQ, sends RREP (Route Reply)
    // 4. RREP traces back: C → B → A
    // 5. Device A now knows: C is reachable via B (2 hops)
}
```

---

## Deep Dive: Why Intermediate Nodes Can't Read Messages

### Message Flow on Device B (Relay)

**When Device A sends to Device C:**

```
Device A:
  1. plaintext = "Hello"
  2. key = derive_session_key_with(Device_C)
  3. encrypted = AES_256_GCM_encrypt(plaintext, key)
  4. message = MessageEnvelope(encrypted, destinationID=C)
  5. SEND to neighbors

Device B (receives):
  1. Extract MessageEnvelope
  2. Check: is destination == B? NO
  3. So: RELAY to neighbors
  4. Try to decrypt for inspection? NO! 
       - Device B doesn't have session key with Device C
       - Device B's key with Device A is different
       - Decryption FAILS → message stays encrypted
  5. Forward envelope unchanged

Device C (receives):
  1. Extract MessageEnvelope
  2. Check: is destination == C? YES
  3. Extract encrypted payload
  4. key = derive_session_key_with(Device_A)
  5. plaintext = AES_256_GCM_decrypt(encrypted, key)
  6. plaintext = "Hello" ✅ SUCCESS
```

### Key Insight: Session Key Derivation
- Device A ↔ Device B: Session key = HKDF(ECDH(A_private, B_public))
- Device B ↔ Device C: Session key = HKDF(ECDH(B_private, C_public))
- Device A ↔ Device C: Session key = HKDF(ECDH(A_private, C_public))

**These are ALL DIFFERENT!** Device B cannot use any of its keys to decrypt A→C messages.

---

## Advanced Testing: Monitor BLE Packets

### Using macOS Bluetooth Packet Logger
If you're developing on Mac with multiple devices:

1. **Install Bluetooth Packet Logger** (comes with Xcode)
2. **Run on each test device via logging:**
   - `MeshLogger.relay.info("Relaying message from \(envelope.originID) to \(envelope.destinationID)")`
   - These logs show routing but NOT decrypted content

3. **Observe on Device B's Console:**
   - Message enters relay
   - Message exits relay  
   - Payload remains as `Data` (encrypted bytes)

### Inspect Logs in Xcode Console
**On Device B, watch for relay logs:**
```
[BLEMesh.Relay] ✓ Relaying message 12345 from A to C via relay
[BLEMesh.Relay] ✓ Message forwarded to 2 neighbors
[BLEMesh.Relay] ✗ Decryption not attempted (destination ≠ self)
```

---

## Test Variations

### Test 1: Direct Message (Baseline)
```
Device A ←→ Device B
(in direct range)

Expected:
- Hop count = 1
- No relaying needed
- Direct delivery
```

### Test 2: Two-Hop (Main Test)
```
Device A ←→ Device B ←→ Device C
(B is relay)

Expected:
- Hop count = 2
- Device B relays but doesn't decrypt
- Device C reads encrypted message
```

### Test 3: Out-of-Range Recovery
```
1. Start with A → C (2 hops via B)
2. Turn OFF Device B's Bluetooth
3. Try to send A → C again
4. Expected: Message queued, FAIL to deliver

Turn Device B back ON:
5. Queue should auto-retry
6. Message should deliver again
```

### Test 4: Broadcast (All Devices)
```
Device A broadcasts to ALL

Expected:
- Devices B and C both receive
- No encryption (broadcast mode)
- All devices see the message
```

---

## Verification Outcomes

### ✅ SUCCESS Indicators
1. **Message reaches destination:**
   - Device C receives the exact message Device A sent
   - Timestamp and content match

2. **Device B doesn't decrypt:**
   - Device B's logs show "Relaying" not "Decrypted"
   - Device B NEVER displays the message to user (unless explicitly addressed)
   - No "decryption failed" warnings on Device B's UI

3. **Hop counting works:**
   - Device A knows Device C is 2 hops away
   - RREP contains correct hop count

4. **No message duplication:**
   - Device C receives message once, not multiple times
   - Debug stats show duplicates blocked = 0

5. **TTL protection:**
   - Messages don't loop infinitely
   - TTL decrements and drops messages when TTL = 0

### ❌ FAILURE Indicators
1. **Device B can read the message** → Encryption broken
2. **Device C never receives message** → Routing broken
3. **Hop count shows 1 when should be 2** → Routing table wrong
4. **Message duplicates** → Relay/cache logic broken
5. **Infinite loops** → TTL not decrementing

---

## Code-Level Verification

### Check These Functions During Testing

**RoutingService.swift - Route Discovery:**
```swift
func discoverRoute(to destinationID: UUID, completion: @escaping (RouteEntry?) -> Void)
// Should find Device C via Device B
```

**MessageRelayService.swift - Relay Logic:**
```swift
func relayMessage(_ envelope: MessageEnvelope) async throws
// Should forward without decryption attempt
```

**EncryptionService.swift - Key Derivation:**
```swift
func deriveSessionKey(with peerID: UUID) -> SymmetricKey
// Device B cannot derive key with Device C for Device A's encrypted message
```

**ChatViewModel.swift - Delivery Tracking:**
```swift
@Published var stats: DebugStats
// .messagesRelayed should increment on Device B
// .messagesReceived should increment on Device C
```

---

## Debugging: If Test Fails

### Problem: Message Doesn't Arrive
**Debug steps:**
1. Check Device C's Bluetooth is on
2. Verify Device C shows in "Mesh Network" on Device A
3. Check Device B's relay logs (tap Debug tab)
4. Verify message wasn't dropped due to TTL

**Code to check:**
- `RoutingService.discoverRoute()` - is route found?
- `MessageRelayService.relayMessage()` - is relay happening?

### Problem: Device B Can Read Message
**This means encryption is broken!**
1. Check EncryptionService session key derivation
2. Verify ECDH is using correct public keys
3. Check AES-256-GCM implementation
4. Inspect KeychainService - are keys stored correctly?

### Problem: Hop Count Wrong
**Debug steps:**
1. Open Network tab on Device A
2. Check "Mesh Network" entry for Device C
3. Hop count should be 2 (not 1, not 3)
4. Inspect RoutingTable.swift - route TTL handling

---

## Network Monitoring (Advanced)

### Wireshark on Mac + Bluetooth Sniffer
If you have a Bluetooth sniffer on macOS:

```
You'll see raw BLE packets:
- GATT notifications
- Your MessageEnvelope data
- Encrypted payload (opaque bytes)
- Route Request/Reply messages

Signature: You CANNOT decrypt the payload by sniffing
because you don't have the session keys!
```

---

## Final Checklist Before Deployment

- [ ] **3-device test completed** - A sends to C via B
- [ ] **Message reaches recipient** - C reads exact message
- [ ] **Device B cannot read message** - Relay doesn't decrypt
- [ ] **Hop count correct** - Shows 2 hops, not 1
- [ ] **Routing table updated** - Device A knows C via B
- [ ] **No message duplicates** - Stats show 0 duplicates blocked
- [ ] **TTL working** - Messages don't loop endlessly
- [ ] **Offline queue works** - Queue + auto-retry tested
- [ ] **Multiple hops** - Test A → B → C → D (3 hops)
- [ ] **Encryption confirmed** - B cannot decrypt A→C message

---

## Success Metrics

| Metric | Target | How to Verify |
|--------|--------|---------------|
| **Message Delivery Rate** | 100% | Message arrives on Device C |
| **Relay Success** | 100% | Device B relays to Device C |
| **Decryption Integrity** | Device C only | Only C reads message, not B |
| **Hop Count Accuracy** | +/- 0 | Shows 2 hops for A→C via B |
| **Routing Discovery Time** | < 5 seconds | RREP returns quickly |
| **Duplication Rate** | 0% | Message received once |
| **TTL Protection** | Working | Messages expire correctly |
| **Security** | Uncompromised | B cannot decrypt A→C |

---

**Once all tests pass, your routing and encryption are production-ready! 🎉**
