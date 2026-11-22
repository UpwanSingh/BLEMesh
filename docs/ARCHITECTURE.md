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


## Crowds and congestion (Phase 1)

- **Priorities:** every packet has a scheduling class, `control` (hello, acks) > `urgent` (SOS) >
  `direct` (DMs, groups) > `normal` (public chat) > `background` (announces, store-and-forward).
  Transports send higher classes first. When a queue is full, the lowest class is dropped first.
- **Relay suppression:** a phone with more than 3 links that receives a flooded packet waits a
  random 20–250 ms before relaying it. If it hears 3 copies in that time (1 for announces), it
  skips its own relay. Urgent packets are never suppressed.
- **Shorter-path copies:** if a copy arrives with more hops left than the one this phone relayed,
  or this phone couldn't relay the first copy at all, it relays once more. Without this,
  deduplication would shrink a flood's reach.
- **Announces:** the interval stretches with density (×links/4, capped at 45 s) and with low
  battery. With 6 or more links, announces travel 3 hops instead of 5.
- **Results in the simulated 100-phone crowd** (`CrowdTests`: shared ~120 kbit/s radio, ≤8 links):
  - about 38% less total airtime than plain flooding;
  - reach of at least 95% of phones within the hop limit, equal to or better than plain flooding;
  - SOS: 90th-percentile latency under 1 s while chat under saturation takes 30 s or more;
  - all direct messages to known contacts 4–7 hops away are delivered and acknowledged.

## Battery

- Low battery (<20%, unplugged): announces less often, relays later with stricter suppression,
  carries a quarter as many store-and-forward packets, and advertises `lowPower`, which makes
  routes through it cost 2 extra.
- Critical battery (<10%, unplugged): relays only SOS, direct and control traffic, and carries
  nothing.

## Fake-SOS resistance

- Urgent packets need proof-of-work: SHA-256(packetID ‖ origin ‖ timestamp) must have at least
  18 leading zero bits, which takes about 0.5 s on a phone per SOS. Verifying is a single hash.
- Each relay gives every sender a budget of 4 urgent relays, refilled at 1 per 2 minutes.
  Anything over budget is still delivered, but as ordinary traffic.
- The app marks SOS calls from identities first seen less than 10 minutes ago as "New device".

## Forward secrecy

- Every phone rotates a short-lived X25519 prekey every 24 hours. It's announced, and the
  announce signature authenticates it. Old prekeys are deleted after 7 days.
- Direct messages use ECDH(ephemeral, prekey) and ECDH(ephemeral, static key), combined with
  HKDF that includes the sender's key. Once the prekey is deleted, a captured message can't be
  decrypted even with every key the phone still holds.
- If a contact's prekey isn't known (for example an old contact record), messages fall back to
  static-key encryption. Prekeys are persisted in the node snapshot (data-protected file).

## Groups

- The admin is the creator while they're a member, otherwise the remaining member with the
  lowest ID, so every member agrees without coordinating.
- When a member leaves or is removed, the admin generates a new key and sends it to the
  remaining members. The old key keeps working for 10 minutes for messages already in flight.

## Emergency features

- `sosUpdate` (acknowledged / on the way / resolved / cancelled), with these rules
  (`SOSTracker`):
  - only the SOS sender can close it on their own;
  - two other people saying "resolved" also closes it.
- `checkIn` (safe / need help, plus optional location and battery) and `safetyCheck` ("are you
  safe?") go to groups. `FamilyLocator` shows each member's latest check-in, needs-help first.
- A medical ID (blood type, allergies, conditions, medications, emergency contact) is stored in
  the Keychain and attached to an SOS only on request.

## Trust (app)

- QR verification code: `blemesh:v1:<peerID hex>:<safety number>`. Scanning it, or pasting it,
  marks the contact verified. An ID with the wrong keys is reported as a possible impostor.
- Names that appear more than once get a short-ID suffix, and an unverified device using a
  verified contact's name is flagged.
- Blocking hides a device everywhere on this phone; its traffic is still relayed for others.
  Reporting also blocks it.

## Local intelligence (Phase 2)

Everything runs on the phone; nothing leaves the mesh.

- **Answers (`AnswerSafety`, `LocalRetriever`).** Every answer is a `SafeAnswer`: text,
  confidence (high/medium/low/refused), sources, an optional safety note, and whether a model
  wrote it. The pipeline:
  1. Dosing and self-harm questions are refused, with crisis guidance for self-harm.
  2. Local questions are answered from recent messages (BM25 over the last 6 h, newer messages
     preferred) and marked unverified.
  3. Otherwise the model writes an answer grounded in the matching guide entries.
  4. Model text that recommends a known-dangerous practice (negations such as "do not" are
     understood) is replaced with the guide entry.
  The app labels each answer by what actually produced it.
- **Triage (`HeuristicTriage`, `EmbeddingTriage`, `HybridTriage`).**
  - Weighted concept rules are combined with k-nearest-neighbour search over Apple's on-device
    sentence embeddings.
  - SOS calls are floored at "high".
  - `TriageBenchmark` keeps the tuning set separate from two held-out sets.
  - `TriageComparisonTests` guards the measured accuracy on the blind set: category at least 75%,
    priority at least 70%, critical recall at least 50%.
- **Catch-up (`CatchUpBuilder`).**
  - Ranking: SOS first, then need-help check-ins, then messages to you, then safety checks, then
    other emergencies, then chat.
  - Near-duplicates (60% shared words) are merged.
  - The window starts at the previous visit, not the current one.
- **Credibility (`RumourAnalyzer`).**
  - "Corroborated" means 2 or more distinct reporters, or 1 verified contact.
  - "Disputed" means a later message about the same place or topic contains a denial ("false
    alarm", "not true", …).
- **Spam (`SpamFilter`).**
  - Only the public channel is filtered. Signals: repeats in 10 minutes, more than 6 messages a
    minute, links, scam phrases, all caps, and reported devices.
  - Urgent texts skip the repeat and flood rules. SOS packets are never filtered.
- **Roles and shared AI.**
  - Roles: `PeerCapabilities.medic` / `.rescuer` are announced, and `ResponderMatcher` suggests
    the nearest matching reachable peers.
  - Shared AI: `AIQuery.task` (answer / triage / translate / summarize) lets phones without a
    model use a nearby one. Older queries without a task decode as `answer`.
- **Routing fix found by these tests.** Only the first copy of each announce was processed. When
  a costlier copy (for example via a low-battery relay) arrived first, the cheaper path was never
  refreshed and expired. Duplicate announces, which have already been signature-checked, now
  offer their path too.

