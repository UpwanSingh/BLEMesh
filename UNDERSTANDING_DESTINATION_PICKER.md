# How Device Selection Works in Multi-Hop Scenarios

## The Key Insight

**Device C is out of BLE range from Device A, but you CAN still select it!**

Why? Because the **destination picker shows TWO types of devices**:

```
1. DIRECT PEERS      - Devices you can see via BLE (in range)
2. ROUTABLE PEERS    - Devices reachable through the mesh network
```

---

## Visual Flow: Device C Appearing in the Picker

### Timeline: How Device C Becomes Selectable on Device A

```
┌─────────────────────────────────────────────────────────────────┐
│ STEP 1: INITIAL STATE (Device A & C out of range)              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Device A (Sender)                    Device C (Recipient)     │
│  ┌──────────────┐                     ┌──────────────┐         │
│  │ No route to  │ ←←← OUT OF RANGE ←→ │              │         │
│  │ Device C yet │   (> 100 meters)    │              │         │
│  └──────────────┘                     └──────────────┘         │
│                      ▲                                           │
│                      │ (BLE range)                              │
│                      │                                           │
│                  ┌──────────┐                                   │
│                  │ Device B │ ← RELAY (in range of both)       │
│                  │ (Relay)  │                                   │
│                  └──────────┘                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

Device A's Destination Picker at this point:
┌─ DIRECT PEERS ─────────────────────┐
│ Device B (1 hop, direct)           │
│                                    │
├─ ROUTABLE PEERS ──────────────────┤
│ (empty - no routes discovered yet) │
│                                    │
└────────────────────────────────────┘

📍 Device C is NOT in the picker yet!
```

---

### Timeline: Route Discovery Happens

```
┌─────────────────────────────────────────────────────────────────┐
│ STEP 2: ROUTE DISCOVERY (automatic or manual)                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│ When you open Messages tab (or tap "Force Route Discovery"):   │
│                                                                 │
│ Device A broadcasts ROUTE REQUEST:                             │
│   "Who knows about other devices?"                             │
│                                                                 │
│       ┌─ RREQ broadcasts from A                               │
│       ▼                                                         │
│  Device A ←→ Device B ←→ Device C                             │
│                  │                                             │
│                  └─→ Device B responds:                       │
│                      "I know Device C!                        │
│                       It's 1 hop from me                      │
│                       So 2 hops from you (A)"                │
│                  ┌─ RREP (Route Reply) back to A             │
│                  ▼                                             │
│       Device A receives route info                            │
│       Updates its routing table                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

Device A's Routing Table NOW contains:
┌────────────────────────────────┐
│ Device B: 1 hop (direct)       │
│ Device C: 2 hops (via B)  ← NEW│
└────────────────────────────────┘
```

---

### Timeline: Device C Now Appears in Picker

```
┌─────────────────────────────────────────────────────────────────┐
│ STEP 3: DEVICE C BECOMES SELECTABLE                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│ Device A's Destination Picker NOW shows:                       │
│                                                                 │
│ ┌─ DIRECT PEERS ──────────────────────────────┐               │
│ │ Device B (1 hop, direct)        [Select]     │               │
│ │                                              │               │
│ ├─ ROUTABLE PEERS ────────────────────────────┤               │
│ │ Device C (2 hops, via B)         [Select] ←─┤ SELECT THIS!  │
│ │                                              │               │
│ ├─ GROUPS ────────────────────────────────────┤               │
│ │ (none yet)                                   │               │
│ └──────────────────────────────────────────────┘               │
│                                                                 │
│ You can now tap on "Device C (2 hops)" and send a message!    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## What's Happening Under the Hood

### When Route Discovery Happens

```swift
// Device A code:
// Every few seconds, or when you tap "Force Route Discovery"

routingService.discoverRoute(to: deviceC_ID) { route in
    // Updates internal routing table
    // Device C now appears in destination picker
}

// Device B code:
// When it receives route request
// It forwards it and replies with its known devices

routingService.handleRouteRequest(from: deviceA_ID) {
    // Tells Device A: "I know Device C"
    // Provides path: A → B → C (2 hops)
}
```

### What the Destination Picker Displays

```swift
// ContentView.swift - DestinationPickerView

// DIRECT PEERS section:
// Shows all devices from bluetoothManager.discoveredPeers
// (devices in BLE range)

// ROUTABLE PEERS section:
// Shows all devices from routingService.knownPeers
// BUT NOT in discoveredPeers
// (devices reachable via mesh, out of direct range)

// When you select Device C:
// Sends message → MessageRelayService finds route A→B→C
// Routes message automatically!
```

---

## Step-by-Step: How to Make Device C Appear

### Method 1: Automatic (Passive Discovery)
```
1. Open Messages tab on Device A
2. Wait 3-5 seconds
3. Tap destination picker
4. Device C should appear under "ROUTABLE PEERS"

Why? Because Device B automatically shares route info
```

### Method 2: Manual (Force Discovery)
```
1. Open Network tab on Device A
2. Look at "Mesh Network" section
3. If Device C is NOT listed, tap "Force Route Discovery" button
4. Wait 2-3 seconds
5. Device C now appears in Network tab with hop count
6. Go back to Messages tab
7. Tap destination picker
8. Device C is now in "ROUTABLE PEERS" section
9. Tap to select!
```

---

## Visual Breakdown: Destination Picker Sections

### DIRECT PEERS
```
┌──────────────────────────────────────────┐
│ DIRECT PEERS (In BLE Range)              │
├──────────────────────────────────────────┤
│ Device B (1 hop)                [Select] │
│ Device D (1 hop)                [Select] │
│                                          │
│ These are devices you can reach directly│
│ via Bluetooth without relaying          │
└──────────────────────────────────────────┘
```

### ROUTABLE PEERS
```
┌──────────────────────────────────────────┐
│ ROUTABLE PEERS (Via Mesh Network)        │
├──────────────────────────────────────────┤
│ Device C (2 hops)               [Select] │
│ Device E (3 hops)               [Select] │
│ Device F (2 hops)               [Select] │
│                                          │
│ These are devices OUT OF YOUR BLE RANGE │
│ but reachable through the mesh!         │
│ The hop count shows distance            │
└──────────────────────────────────────────┘
```

---

## Common Questions

### Q1: "Device C is out of range, so how can I select it?"
**A:** The destination picker shows BOTH direct and routable devices. Device C appears under "ROUTABLE PEERS" because it's in the routing table (reachable via Device B).

### Q2: "What if Device C doesn't appear even after waiting?"
**A:** 
1. Check Device B's Bluetooth is ON
2. Check Device C's Bluetooth is ON
3. Make sure Device B can see both A and C
4. Tap "Force Route Discovery" on Device A
5. Wait 2-3 seconds
6. Check Network tab - if C appears there, go back to Messages

### Q3: "Does Device A need to see Device C directly to send a message?"
**A:** NO! That's the whole point of the mesh! As long as Device C is in the routing table (routable via B), Device A can send to it.

### Q4: "What if the route is broken (Device B goes offline)?"
**A:** 
- Message gets queued in the offline queue
- When Device B comes back online, the message auto-retries
- Or Device A discovers a new route if one exists

---

## The Magic: How It All Works Together

```
┌──────────────────────────────────────────────────────────────┐
│                    THE MESH MAGIC                            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│ You (Device A)                                              │
│ └─ Can't see Device C (out of range)                        │
│    BUT...                                                   │
│    Device B tells you about Device C                        │
│    Device B becomes your "gateway" to Device C              │
│                                                              │
│ When you send message to Device C:                          │
│ 1. You tap "Device C (2 hops)" in destination picker       │
│ 2. Message goes to Device B                                │
│ 3. Device B can't read it (encrypted for Device C)         │
│ 4. Device B relays it to Device C                          │
│ 5. Device C decrypts and reads it                          │
│                                                              │
│ You communicate with unreachable devices through the mesh! │
│ And intermediate nodes can't read your messages!           │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Testing Checklist: Before Sending Message

- [ ] Device B is in BLE range of Device A
- [ ] Device C is in BLE range of Device B
- [ ] Device A and Device C are OUT OF RANGE (>100m or different rooms)
- [ ] All three Bluetooth are ON
- [ ] Open Messages tab on Device A
- [ ] Tap destination picker
- [ ] Device C appears under "ROUTABLE PEERS" with hop count
- [ ] If not visible, tap "Force Route Discovery" first
- [ ] Select Device C
- [ ] Type message
- [ ] Encryption enabled (lock icon green)
- [ ] Send!

---

**The key takeaway: The destination picker is smart. It shows you all reachable devices, whether direct or through the mesh. The mesh extends your communication range! 🎉**
