# BLE Mesh Testing - Quick Reference Checklist

## Pre-Test Setup (5 minutes)

### Physical Setup
```
[iPhone A]  ←← 10m ←→  [iPhone B]  ←← 10m ←→  [iPhone C]
 SENDER      (RELAY)             RECIPIENT
  └─ Out of range of C            └─ Out of range of A
```

- [ ] All 3 iPhones have app installed and running
- [ ] All Bluetooth enabled
- [ ] All on same Wi-Fi (optional, for logging)
- [ ] Note device names: A=Sender, B=Relay, C=Recipient

---

## Quick Test Flow (2 minutes)

### Device A (Sender) - Messages Tab
1. Tap destination picker button
2. Scroll down → find **Device C**
3. Type: `Test message from A to C`
4. **Verify LOCK ICON IS GREEN** (encryption enabled)
5. Tap send button

### Device B (Relay) - Debug Tab
- [ ] Watch `messagesRelayed` counter increase by 1
- [ ] Verify NO message content visible to user
- [ ] Check logs don't show "decryption succeeded"

### Device C (Recipient) - Messages Tab
- [ ] Message appears immediately
- [ ] Content reads: `Test message from A to C`
- [ ] Sender shows as Device A
- [ ] Timestamp matches when A sent it

---

## Network Tab Verification (1 minute each)

### On Device A - Network Tab
```
Discovered Peers: ✓ Device B (direct, RSSI: ~-50)
                  ✗ Device C (should NOT be here)

Mesh Network: ✓ Device C (2 hops via B)
              ✓ Device B (1 hop, direct)
```

### On Device B - Network Tab
```
Discovered Peers: ✓ Device A (direct)
                  ✓ Device C (direct)

Mesh Network: ✓ Both A and C (both direct)
```

### On Device C - Network Tab
```
Discovered Peers: ✗ Device A (should NOT be here)
                  ✓ Device B (direct)

Mesh Network: ✓ Device A (2 hops via B)
              ✓ Device B (1 hop, direct)
```

---

## Debug Statistics (Check on All Devices)

### Before Sending Message
```
Device A:  sent=0, relay=0, received=0
Device B:  sent=0, relay=0, received=0
Device C:  sent=0, relay=0, received=0
```

### After Sending Message A→C via B
```
Device A:  sent=1 ✓
Device B:  relay=1 ✓  (relayed, NOT decrypted)
Device C:  received=1 ✓
```

### Critical Check
- [ ] Device B shows `relay=1` (proves it relayed)
- [ ] Device B does NOT show message in Messages tab
- [ ] Device C shows `received=1` with readable message

---

## Encryption Verification (Most Important)

### The Test: Can Device B Read the Message?

**Expected Answer: NO**

**How to verify:**
1. On Device B, open **Messages** tab
2. You should see empty list or only direct messages you sent
3. You should **NOT** see the A→C message that you relayed
4. This proves encryption is working!

**Why?** Because:
- Message was encrypted with C's public key
- Device B only has its own keys
- Device B cannot decrypt → can't read → can't display

**If Device B CAN read the message:**
- ❌ Encryption is broken
- ❌ Investigate EncryptionService.swift
- ❌ Check session key derivation

---

## Hop Count Verification

### Device A Network Tab
Look at "Mesh Network" section:

```
Device C: 2 hops away
```

This means:
- Direct: 1 hop
- Via relay: 2 hops ✓

**If it shows:**
- `1 hop` → A and C are in direct range (test setup failed, move further apart)
- `3+ hops` → routing is taking wrong path (shouldn't happen with 3 devices)

---

## Success Checklist (✓ All Should Pass)

- [ ] Message sent from A
- [ ] Message relayed by B (no decryption)
- [ ] Message received by C with correct content
- [ ] Device B cannot see A→C message (crucial!)
- [ ] Hop count on A shows 2 for device C
- [ ] Hop count on C shows 2 for device A
- [ ] Device B shows both A and C as direct (1 hop each)
- [ ] Debug stats: sent=1 on A, relay=1 on B, received=1 on C
- [ ] No "duplicate" messages received
- [ ] Message arrives within 2-3 seconds

---

## Failure Troubleshooting

### Message Never Arrives on C
- [ ] Check: Is C's Bluetooth on?
- [ ] Check: Is C in range of B?
- [ ] Check: Does A show C in "Mesh Network"?
- [ ] Check: Tap "Force Route Discovery" on A, wait 2 sec, resend
- [ ] Check: Look at B's Debug tab - any relay errors?

### Device B CAN Read the Message ❌
**CRITICAL - Encryption failure!**
- [ ] Investigate EncryptionService.swift
- [ ] Check ECDH key exchange
- [ ] Verify session key derivation is correct
- [ ] DO NOT release app until fixed!

### Hop Count Wrong on Device A
- [ ] Force route discovery (Debug tab → tap button)
- [ ] Wait 2-3 seconds for RREP to return
- [ ] Check Mesh Network tab again
- [ ] If still wrong, check RoutingService.swift

### Message Duplicated
- [ ] Check: Did you send twice by accident?
- [ ] Check: Is B relaying to A? (should not)
- [ ] Check: TTL working? (should expire messages)
- [ ] If duplicates persist: routing logic issue

---

## What to Watch During Test

### Device A (Console/Logs)
```
[BLEMesh.App] Sending message to: Device C
[BLEMesh.Crypto] ✓ Message encrypted
[BLEMesh.Relay] ✓ Message broadcasted
```

### Device B (Console/Logs)
```
[BLEMesh.Relay] ✓ Received message from A, destination C
[BLEMesh.Relay] ✓ Relaying to neighbors (not destination)
[BLEMesh.Relay] ✗ NOT decrypting (destination ≠ self)
```

### Device C (Console/Logs)
```
[BLEMesh.Relay] ✓ Received message, destination is SELF
[BLEMesh.Crypto] ✓ Message decrypted
[BLEMesh.App] ✓ Message displayed: "Test message from A to C"
```

---

## Next Steps After Passing Test

1. **Test with 4 devices** (A→B→C→D, 3 hops)
2. **Test offline queueing** (send while C is offline, reconnect)
3. **Test group messages** (multiple recipients)
4. **Test broadcast** (message to all)
5. **Test large messages** (10KB max)
6. **Stress test** (rapid fire messages)
7. **Battery/memory test** (long-running session)

---

## Device Log Locations

### To view logs on each device:
1. Open Xcode
2. Connect device via USB
3. Window → Devices and Simulators
4. Select device
5. View Console output
6. Filter by "BLEMesh" to see app logs

---

**Good luck with testing! This is the crucial validation step. 🚀**
