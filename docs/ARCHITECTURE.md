# Architecture and security model

## Identities

Each device generates an Ed25519 signing key and an X25519 key-agreement key, stored in the
Keychain (`AfterFirstUnlockThisDeviceOnly`, never synced). Its **PeerID** is the first 16 bytes
of SHA-256(signing public key). PeerIDs are the only device identifiers above the transport
layer. CoreBluetooth identifiers differ per observer and per role, so they never reach routing,
storage or the UI.

## Wire format (v1)

Link frames:

```
0xA1 | packet                                   whole packet
0xA2 | group u32 | index u16 | count u16 | chunk   fragment (reassembled per link)
```

Packet (big-endian):

```
version u8 | type u8 | flags u8 | ttl u8 | hops u8
packetID 16 | origin 16 | destination 16 | timestampMs u64
originSigningKey 32 | payloadLen u16 | payload | signature 64
```

- The signature covers every field except `ttl` and `hops`, which relays change.
- A receiver drops a packet unless `origin == PeerID(originSigningKey)` and the signature
  verifies. Packets therefore can't be spoofed or modified in transit, even by relays.
- Age limits: announces and hellos older than 2 minutes, and messages and acks older than
  6 hours (the carry lifetime), are rejected, as is anything more than 10 minutes in the future.
  Duplicate `packetID`s are remembered for 7 hours, longer than any accepted age, so a replay
  inside the window is always caught. Inbound TTLs are capped at our own limits.
- Types: `hello` (link-local neighbour proof, never relayed), `announce` (presence: agreement
  key, capabilities, nickname), `message`, and `ack` (delivered or read, plus the message ID and
  the acknowledged packet ID).
- Neighbour proof: on link-up each side sends a signed `hello` with a random nonce, and the
  other side echoes it in its own signed hello. A peer counts as a direct neighbour (0 hops)
  only after proving itself on that link. A relay can't make a distant peer look adjacent by
  rewriting the unsigned `hops` field.

## Encryption

- **Direct:** a sealed box. The sender creates a fresh ephemeral X25519 key, does ECDH with the
  recipient's static key, derives a key with HKDF-SHA256 (salt = both public keys, info includes
  the sender's Ed25519 key), and encrypts with ChaCha20-Poly1305. Because the sender's key is part
  of the derivation, a relay that re-signs someone else's ciphertext as its own produces
  something that won't decrypt.
- **Group:** a 256-bit group key is sent to members inside encrypted direct invites.
  Group messages are encrypted with ChaCha20-Poly1305, with the group ID and the sender's key as
  associated data, and broadcast. Only the creator can change an existing group. Invites for a
  group you left are ignored unless they're newer than the leave. Posts from non-members are
  dropped. Control and AI content is accepted only in direct messages, so it can't be spoofed
  by broadcasting it.
- **Nearby/SOS:** signed but not encrypted, by design, so anyone in range can help.

## Routing and delivery

- Announces flood with TTL 5 every 20 seconds. Each node keeps the best next-hop link for each
  PeerID (fewest hops, then freshest). A route expires after 75 seconds without refresh and is
  removed immediately when its link drops.
- Directed packets follow the route when one exists and flood otherwise, never back over the
  link they arrived on. Broadcasts flood and are de-duplicated. Each relay enforces a token
  bucket per origin (burst 40, 4 packets/s). Traffic older than 2 minutes (carried or replayed)
  uses a separate, smaller bucket, so it can't use up a sender's allowance for live traffic.
- Direct messages are tracked until acknowledged. Retries use a new packet ID with the same
  message ID, so relays forward them and the receiver acknowledges again without delivering a
  duplicate. A message fails after 8 transmissions or 24 hours, and can be retried manually.
- Retries aren't triggered by link churn. A pending message is retried early only when its
  destination's route appears, and at most once every 2 seconds.
- Store-and-forward: a relay with no route keeps directed packets (capacity 200, at most 20 per
  origin, kept 6 hours). It hands them to every new neighbour, and to the route as soon as one
  to the destination appears. A carried copy is dropped only on an ack from the packet's real
  recipient addressed to its real sender.
- Memory limits: finished outbox entries are pruned after 24 hours; the peer directory is capped
  (1,000 peers, 30-day retention); fragment reassembly is capped per link.

## Transport (BLE)

- One service and one characteristic (write-without-response + notify). Centrals write;
  peripherals notify. Every link has a frame queue that drains only when CoreBluetooth reports
  capacity (`canSendWriteWithoutResponse`, or `updateValue` succeeding), so frames are never
  silently dropped.
- Frame size per link is `maximumWriteValueLength(.withoutResponse)` or
  `maximumUpdateValueLength`, capped at 512.
- Auto-connect is capped at 8 links. The advertised name is "M" plus the short PeerID; when two
  phones see each other, only the one with the smaller ID connects.
- State restoration identifiers are set for both managers.
