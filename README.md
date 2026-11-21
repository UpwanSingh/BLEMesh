# BLE Mesh

Off-grid messaging for iPhone. Phones talk directly over Bluetooth LE and relay for each
other, so messages reach people several hops away with no internet, SIM or server. On-device
AI keeps working offline: voice notes, translation, SOS triage, an area summary and
"Ask the Mesh".

## Features

| | |
|---|---|
| **Mesh messaging** | Automatic discovery and connection. Multi-hop routing by mesh identity, duplicate suppression, and per-sender relay rate limits. |
| **Private chats** | End-to-end encrypted direct messages (X25519 + ChaCha20-Poly1305, sealed per message). Every packet is Ed25519-signed. Safety numbers let you verify contacts. |
| **Groups** | Group key shared through encrypted invites. Relays can't read group traffic. Members can leave. |
| **Reliable delivery** | End-to-end delivery and read receipts, retries with backoff, an outbox that survives restarts, and store-and-forward that carries messages through gaps in the network. |
| **Nearby channel** | Signed public channel for everyone in range. |
| **Voice notes over Bluetooth** | Speech is transcribed on the phone, so a voice note is about 200 bytes of text instead of audio. The receiver's phone reads it aloud. |
| **On-device translation** | Translate any message, or auto-translate incoming ones (iOS 18+). |
| **SOS** | One-tap SOS with GPS (GPS needs no network), triaged on the phone (critical/high/medium/low, category, people affected, landmarks). An SOS board ranks requests by urgency. |
| **Area summary** | Clusters the last hour of public reports into a ranked digest ("Fire near the market, 2 reports…"). |
| **Ask the Mesh** | Questions are answered by this phone's on-device model (iOS 26 Apple Intelligence). If this phone has no model, the nearest phone that has one answers over an encrypted link. If none is reachable, a vetted offline first-aid guide answers. |
| **Safety** | Panic wipe erases messages, groups, contacts and keys, then creates a new identity. Message retention is configurable. |
| **Demo mesh** | Simulated neighbours, for trying the app or UI-testing it with no other phones (`-demoMesh` launch argument). |

## Architecture

```
BLEMesh (iOS app, SwiftUI + SwiftData)
├── Transport/BLETransport      CoreBluetooth central+peripheral; one GATT link = one mesh link
├── Services/MeshService        owns the node, persistence, notifications, AI features
├── Services/DemoMesh           simulated neighbourhood (demo + tests)
├── Intelligence/               Foundation Models engine, speech, location
└── Views/                      Chats · Nearby · SOS · Ask · Network · Settings
Packages/MeshCore (platform-independent, fully unit tested)
├── Protocol/   signed binary packets, per-link fragmentation, content model
├── Crypto/     identities, sealed-box DMs, group encryption
├── Routing/    distance-vector routing table, dedup cache, rate limiter
├── Engine/     MeshNode: relay, routing, acks, retries, store-and-forward, groups
├── Intelligence/ heuristic SOS triage, area digest, offline emergency guide
└── MeshSimulator  deterministic in-memory mesh with virtual time, MTU, latency, loss
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the wire format and the security model.

## Requirements

- Xcode 16 or later (the iOS 26 SDK enables the on-device model features). The app runs on iOS 17+.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Real mesh testing needs two or more physical iPhones (the Simulator has no Bluetooth). Everything else, including multi-hop behaviour, is tested in the simulator and the demo mesh.

## Build and run

```bash
xcodegen generate          # regenerate BLEMesh.xcodeproj from project.yml
open BLEMesh.xcodeproj     # pick your team under Signing & Capabilities, then run
```

## Tests

```bash
./scripts/test-core.sh     # MeshCore: protocol, crypto, framing, routing, multi-hop simulations
xcodebuild test -project BLEMesh.xcodeproj -scheme BLEMesh \
  -destination 'platform=iOS Simulator,name=iPhone 17'   # app unit + UI tests
```

CI (`.github/workflows/ci.yml`) runs both on every pull request.

## Known limitations

- **No forward secrecy for direct messages yet.** Each message uses a fresh ephemeral key, but anyone who later steals the recipient's long-term key could decrypt captured traffic. A double-ratchet session is the next security step.
- **Metadata:** relays can see sender and recipient mesh IDs, which they need for routing, though not the content.
- **iOS background limits:** iOS restricts Bluetooth advertising in the background, so two phones that are both in the background discover each other slowly. Existing connections stay up and state restoration is enabled.
- **Group membership:** the creator distributes the group key. When a member leaves, the key isn't rotated yet.
- **App Store:** before submitting, declare encryption export compliance (the app uses standard encryption algorithms) and justify the Bluetooth background modes.
