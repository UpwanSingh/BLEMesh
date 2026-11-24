# MeshCore

MeshCore is the offline mesh-messaging engine behind BLE Mesh, packaged as a Swift package. It has no UI
and no radio code, and it doesn't depend on any particular transport: you supply a transport that moves
bytes between nearby devices (Bluetooth LE, Wi-Fi Aware, a simulator…), and MeshCore handles the rest:

- **Identity and signing:** Ed25519 identities; every packet is signed.
- **Routing:** multi-hop routing with relay suppression and store-and-forward.
- **Encryption:** end-to-end encrypted direct messages with forward secrecy, and groups with re-keying.
- **Delivery:** delivery and read receipts, and SOS priority with proof-of-work.
- **Intelligence:** offline triage, a first-aid guide and answer safeguards.

Platforms: iOS 17+, macOS 14+. Swift 6 toolchain (Swift 5 language mode).

## Products

| Product | What it is |
|---|---|
| `MeshCore` | The engine: `MeshNode`, protocol, crypto, routing, intelligence. |
| `MeshSimulator` | A deterministic in-process radio simulator for tests and demos (crowds, link profiles, a seeded RNG). |
| `mesh-demo` | A runnable example: `swift run mesh-demo`. |

## Quick start

```swift
import MeshCore

let node = MeshNode(identity: MeshIdentity(), nickname: "Asha")
node.delegate = myDelegate        // receives messages and delivery updates
node.transport = myTransport      // moves frames to neighbours

// Your transport reports link events and inbound frames:
node.linkDidConnect(link)                 // a neighbour connected
node.receive(frame: data, from: link)     // a frame arrived
node.linkDidDisconnect(link)              // it went away

// Call about once a second (announces, retries, expiry); poll() every ~50 ms if you can.
node.tick()

// Send
try node.sendBroadcast(.text("Is anyone near the market?"))     // public, signed
let id = try node.sendDirect(.text("Are you okay?"), to: peerID) // end-to-end encrypted, acknowledged
let group = try node.createGroup(name: "Family", members: [peerID])
try node.sendGroup(.text("Everyone safe?"), groupID: group.id)
```

### The transport contract

```swift
public protocol MeshTransport: AnyObject {
    func send(frames: [Data], over link: LinkID, priority: TrafficPriority) -> Bool
    func maximumFrameSize(for link: LinkID) -> Int
}
```

- **Fragmentation:** MeshCore splits packets into frames that fit `maximumFrameSize`. Deliver the
  frames of one `send` call in order.
- **Flow control:** queue frames and retry on back-pressure. When the radio is congested, send
  higher `priority` first and drop the lowest first.
- **Link IDs:** a `LinkID` is any opaque string you choose, such as a BLE connection identifier.

`Tests/MeshCoreSDKTests/SDKUsageTests.swift` is a complete working example: an in-memory transport
wiring three nodes, written against the public API only. The app's `BLETransport.swift` is the
production Bluetooth LE implementation (dual-role central/peripheral, flow control, state restoration).

### Receiving

```swift
final class MyDelegate: MeshNodeDelegate {
    func meshNode(_ node: MeshNode, didReceive message: ReceivedMessage) {
        // message.sender is a verified PeerID (signature-checked); message.scope is
        // .broadcast, .direct or .group(id); message.envelope.content is the MeshContent.
    }
    func meshNode(_ node: MeshNode, didUpdateDelivery messageID: UUID, status: DeliveryStatus) {}
    func meshNodeDidUpdatePeers(_ node: MeshNode) {}
}
```

### Persistence

The node's state lives in a `MeshNodeSnapshot`: the outbox, groups and group keys, known peers and
prekeys. Save it after changes, and restore it at launch with the same `MeshIdentity`:

```swift
let data = try JSONEncoder().encode(node.snapshot())   // store with file protection
node.restore(try JSONDecoder().decode(MeshNodeSnapshot.self, from: data))
```

Keep the identity's private keys in the Keychain: save `identity.signingKeyData` and
`identity.agreementKeyData`, and rebuild it with `MeshIdentity(signingKeyData:agreementKeyData:)`.

## Content types

`MeshContent` covers:

- `text`
- `voice` (an on-device transcript, so a voice note is about 200 bytes)
- `sos` (with optional GPS, triage and medical ID) and `sosUpdate` (responding / on the way / resolved)
- `checkIn` and `safetyCheck` ("are you safe?")
- group control: invites, leaves, and join requests from QR invite codes
- `aiQuery` / `aiResponse`: ask a nearby phone that has an on-device model

## Intelligence (no model or network needed)

- **SOS triage:**
  - `HeuristicTriage.triage(_:)` gives the category, priority, people affected and landmarks.
  - `EmbeddingTriage` and `HybridTriage` add Apple's on-device sentence embeddings.
- **Answers:**
  - `EmergencyKnowledge.search(_:)` searches an offline first-aid and safety guide (46 topics, with sources).
  - `AnswerSafety.compose(question:generated:references:)` refuses dosing questions, gives crisis
    guidance, replaces dangerous model output, and attaches confidence and sources.
- **Local messages:**
  - `LocalRetriever` answers "where is water being given out?" from recent messages.
  - `CatchUpBuilder` summarises what you missed.
  - `RumourAnalyzer` labels reports as corroborated, unverified or disputed.
  - `SpamFilter` hides public-channel spam.
- **Responders and navigation:**
  - `ResponderMatcher` suggests nearby medics and rescuers.
  - `GeoPoint.directions(to:)` gives the distance and compass direction to another GPS fix.

## Testing your integration

```swift
import MeshSimulator

let mesh = SimulatedMesh(seed: 1)
for name in ["A", "B", "C"] { mesh.addNode(name) }
mesh.connect("A", "B"); mesh.connect("B", "C")
mesh.run(for: 10)
let id = try mesh.node("A").sendDirect(.text("hi"), to: mesh.node("C").peerID)
mesh.run(until: { mesh.recorder("C").hasReceived(id) }, timeout: 10)
```

`SimulatedMesh` can also build random crowds (`scatter`), model a shared radio per phone with
priority queues, and report airtime and coverage. The package's own tests use it to measure crowd
behaviour.

## Security model and limits

See `docs/ARCHITECTURE.md` in the repository. In short:

- **Signatures:** packets are signed, and relays can't forge or alter them.
- **What relays can see:** the sender and recipient mesh IDs (needed for routing), but not the
  content of direct or group messages.
- **The public channel and SOS calls** are signed but readable by anyone nearby. That's by design,
  so anyone nearby can help.
- **Forward secrecy:** prekeys rotate daily and are deleted after 7 days. There's no per-message
  ratchet.
- **Wire format:** v1. Version changes are breaking.

## Running the tests

```bash
./scripts/test-core.sh                         # from the repository root
swift run mesh-demo                            # from Packages/MeshCore
```
