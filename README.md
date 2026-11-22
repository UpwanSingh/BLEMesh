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
| **Ask the Mesh** | Questions are answered by this phone's on-device model (iOS 26 Apple Intelligence). If this phone has no model, the nearest phone that has one answers over an encrypted link. If none is reachable, an offline first-aid and safety guide (46 topics) answers. Local questions ("where is water being given out?") are answered from messages this phone has heard. Every answer is labelled with what actually produced it, its sources and a confidence. |
| **Medical-answer safeguards** | No medicine doses (refers to a pharmacist or doctor), crisis guidance for self-harm, and dangerous myths (butter on burns, cutting snake bites, inducing vomiting…) removed from model output and replaced with the vetted guide. Covered by adversarial tests. |
| **SOS triage** | Keyword rules plus on-device sentence-embedding neighbours (English), with an SOS never ranked below "high". Measured on a held-out benchmark (see Known limitations). |
| **Catch me up** | "What did I miss?" for any chat: SOS calls and questions to you first, duplicates merged, plus a short summary (by this phone's model or a nearby AI phone). |
| **Rumour checks** | Area-summary items are labelled "corroborated" (2+ independent reporters or a verified contact), "single report" or "disputed" (someone nearby called it a false alarm). |
| **Spam filter** | Scam phrases, links, floods and repeats on the public channel are hidden, with a one-tap "show". Repeated pleas for help are never hidden. |
| **Responder matching & auto-reply** | Declare yourself a medic or rescuer. SOS calls show the nearest matching responders. An unanswered "are you safe?" gets a facts-only auto-reply after 5 minutes: not answered yet, battery and last activity. It never claims you're safe. |
| **Shared AI** | Phones without a model can ask a nearby AI phone to translate, summarise or triage. |
| **Crowd-ready** | Traffic priorities (SOS first), relay suppression and adaptive announcements. In a simulated 100-phone crowd: about 38% less radio traffic with the same reach, and SOS in under 1 s while chat is saturated. |
| **Battery-aware** | Low-battery phones relay and carry less, and routes avoid them. |
| **Forward secrecy** | Rotating short-lived keys: captured messages become permanently unreadable after 7 days, even if the phone is later stolen. |
| **SOS status** | Responders mark SOS calls "responding" or "on my way"; only the sender (or two responders) can close one. Fake-SOS floods are resisted with proof-of-work and per-sender limits. |
| **Check-ins & family locator** | "I'm safe" / "I need help" to your groups, "Are you safe?" requests, and each member's latest status, location and battery. |
| **Medical ID** | Blood type, allergies, conditions and more, kept in the Keychain and attached to an SOS only when you choose. |
| **Trust** | QR verification, warnings about look-alike names, block and report, and group re-keying when members leave or are removed. |
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

- Xcode 26 or later; tested with Xcode 27.2 and the iOS 27.2 simulator. The app runs on iOS 17+, and the on-device model features turn on with iOS 26+ on Apple Intelligence devices.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Real mesh testing needs two or more physical iPhones (the Simulator has no Bluetooth). Everything else, including multi-hop behaviour, is tested in the simulator and the demo mesh.

## Build and run

```bash
xcodegen generate          # regenerate BLEMesh.xcodeproj from project.yml
open BLEMesh.xcodeproj     # pick your team under Signing & Capabilities, then run
```

## Tests

```bash
./scripts/test-core.sh     # MeshCore: 122 tests: protocol, crypto, routing, security, crowds, AI safety, triage benchmark
xcodegen generate
xcodebuild test -project BLEMesh.xcodeproj -scheme BLEMesh \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'   # 41 app unit tests + 34 UI tests
```

The UI tests drive the real app in demo-mesh mode. They cover onboarding, a direct chat with
delivery and read receipts, a 3-hop chat, group creation, SOS triage and the SOS board, the
public channel and area digest, Ask the Mesh, and panic wipe with identity rotation. A further 12 UI tests tap every
remaining control: swipe-to-delete, chat info and safety numbers, leave group, the long-press
menu (copy, read aloud, translate), voice-note playback, the hold-to-record mic, the digest
toggle, SOS quick picks, the GPS toggle and Reply, Ask suggestions, pull-to-refresh, onboarding
Skip, and every Settings control. Phase 1 and Phase 2 UI tests cover SOS status, check-ins, the
family locator, the medical ID, verification and blocking, answers from nearby messages, refused
dosing questions, catch-up, rumour labels, the spam filter, suggested responders and roles.

CI (`.github/workflows/ci.yml`) runs both on every pull request.

## Known limitations

- **Not yet tested on real phones.** Every result here comes from the simulator and the simulated mesh. Bluetooth range, background behaviour and battery use need testing on physical devices.
- **Offline triage is imperfect.** On a held-out set written after tuning, the offline triage gets the category right 80% of the time and the priority 77% of the time, but catches only 57% of critical cases. An SOS is never ranked below "high". The on-device language-model path couldn't be measured: the iOS simulator reports the model as available, but its model assets are missing, so every generation fails. The app detects this and labels answers by their real source.
- **Medical content needs clinical review** before real-world use. The guide follows public first-aid guidance (sources are listed per entry) but hasn't been reviewed by a clinician.
- **Forward secrecy is coarse:** prekeys rotate daily and are deleted after 7 days, so the exposure window is up to a week (no per-message ratchet).
- **Proof-of-work slows fake SOS floods** but doesn't stop an attacker with many devices.
- **Metadata:** relays can see sender and recipient mesh IDs, which they need for routing, though not the content.
- **iOS background limits:** iOS restricts Bluetooth advertising in the background, so two phones that are both in the background discover each other slowly. Existing connections stay up and state restoration is enabled.
- **App Store:** before submitting, declare encryption export compliance (the app uses standard encryption algorithms) and justify the Bluetooth background modes.
