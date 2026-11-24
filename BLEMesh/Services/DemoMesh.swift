import Foundation
import MeshCore
import MeshSimulator

/// A simulated neighbourhood so the full app can be tried (and UI-tested) without other phones:
///
///     Me ── Asha ── Ravi (AI) ── Meera
///      └── Kabir ──┘
///
/// Virtual devices reply to direct messages, join groups, answer "Ask the mesh" questions, send
/// read receipts, and post a scripted stream of public reports and SOS calls for the digest.
@MainActor
final class DemoMesh {
    private let mesh: SimulatedMesh
    private let localNode: MeshNode
    private weak var service: MeshService?
    private var timer: Timer?
    private var lastRealTime = Date()
    private var scriptIndex = 0
    private var greetedGroups: Set<String> = []
    private let startedAt = Date()

    static let localName = "Me"

    /// (seconds after start, sender, content)
    private let script: [(TimeInterval, String, MeshContent)] = [
        (3, "Asha", .voice(VoiceNote(transcript: "Road is blocked near the old bridge, take the east route",
                                     languageCode: "en-US", durationSeconds: 4))),
        (6, "Kabir", .text("Is anyone else near the market? Power is out on our street.")),
        (14, "Meera", .sos(SOSReport(text: "Two children trapped under rubble behind the school, one is bleeding",
                                     location: GeoPoint(latitude: 28.6139, longitude: 77.2090, accuracyMeters: 25)))),
        (22, "Asha", .text("Fire near the market, lots of smoke. Avoid Main Road.")),
        (30, "Kabir", .text("Confirming fire near the market, it's spreading to the next block")),
        (40, "Ravi", .text("We have drinking water and blankets at the community hall, come by")),
        (55, "Asha", .sos(SOSReport(text: "Elderly man fell near the bus stand and can't move his leg"))),
    ]

    init(localNode: MeshNode, service: MeshService) {
        self.localNode = localNode
        self.service = service
        self.mesh = SimulatedMesh(seed: 2026, start: Date())
    }

    func start() {
        mesh.adopt(localNode, as: Self.localName)
        let names = ["Asha", "Kabir", "Ravi", "Meera"]
        for name in names {
            mesh.addNode(name, capabilities: name == "Ravi" ? [.onDeviceAI, .medic] : name == "Asha" ? [.rescuer] : [])
        }
        for name in names { installBot(name) }
        let profile = SimulatedMesh.LinkProfile(mtu: 182, latency: 0.03)
        mesh.connect(Self.localName, "Asha", profile: profile)
        mesh.connect(Self.localName, "Kabir", profile: profile)
        mesh.connect("Asha", "Ravi", profile: profile)
        mesh.connect("Kabir", "Ravi", profile: profile)
        mesh.connect("Ravi", "Meera", profile: profile)

        lastRealTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        let now = Date()
        mesh.run(for: max(0, now.timeIntervalSince(lastRealTime)))
        lastRealTime = now
        runScript()
        service?.refreshPeersIfChanged()
    }

    private func runScript() {
        let elapsed = Date().timeIntervalSince(startedAt)
        while scriptIndex < script.count, script[scriptIndex].0 <= elapsed {
            let (_, sender, content) = script[scriptIndex]
            scriptIndex += 1
            var payload = content
            if case .sos(var report) = content, report.triage == nil {
                report.triage = HeuristicTriage.triage(report.text)
                payload = .sos(report)
            }
            _ = try? mesh.node(sender).sendBroadcast(payload)
        }
    }

    private func installBot(_ name: String) {
        let node = mesh.node(name)
        let recorder = mesh.recorder(name)
        recorder.onReceive = { [weak self] message in
            if message.scope == .broadcast {
                self?.respondToBroadcast(as: node, message: message)
                return
            }
            self?.respond(as: node, to: message)
        }
    }

    /// Asha (nearest to you) answers your SOS calls the way a nearby responder would.
    private func respondToBroadcast(as bot: MeshNode, message: ReceivedMessage) {
        guard bot.nickname == "Asha", case .sos = message.envelope.content,
              message.sender == localNode.peerID else { return }
        let sosID = message.envelope.messageID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak bot] in
            guard self?.timer != nil, let bot else { return }
            _ = try? bot.sendBroadcast(.sosUpdate(SOSUpdate(sosID: sosID, status: .enRoute, note: "Coming from the market")))
        }
    }

    private func respond(as bot: MeshNode, to message: ReceivedMessage) {
        let sender = message.sender
        let reply: MeshContent?
        switch message.envelope.content {
        case .text(let text):
            reply = .text(Self.reply(to: text, from: bot.nickname))
        case .voice(let note):
            reply = .text("Heard your voice note: “\(note.transcript)” 👍")
        case .aiQuery(let query):
            let label = "\(bot.nickname)’s on-device AI"
            switch query.effectiveTask {
            case .answer:
                let answer = OfflineKnowledgeEngine.offlineAnswer(query.prompt, local: [])
                reply = .aiResponse(AIResponse(queryID: query.queryID, text: answer.renderedText, answeredBy: label))
            case .triage:
                let triage = HybridTriage.triageSOS(query.prompt, embedding: HybridTriage.shared)
                reply = .aiResponse(AIResponse(queryID: query.queryID, text: triage.summary, answeredBy: label, triage: triage))
            case .translate:
                reply = .aiResponse(AIResponse(queryID: query.queryID, text: Self.demoTranslate(query.prompt, to: query.targetLanguage ?? "en"),
                                               answeredBy: label))
            case .summarize:
                let lines = query.prompt.split(separator: "\n").prefix(3).map { "• " + $0 }.joined(separator: "\n")
                reply = .aiResponse(AIResponse(queryID: query.queryID, text: lines, answeredBy: label))
            }
        case .safetyCheck(let check):
            if case .group(let groupID) = message.scope {
                // Meera is hurt; everyone else is fine.
                let status: CheckIn.Status = bot.nickname == "Meera" ? .needHelp : .safe
                let answer = CheckIn(status: status, location: GeoPoint(latitude: 28.61, longitude: 77.21),
                                     batteryPercent: bot.nickname == "Meera" ? 12 : 64,
                                     note: status == .needHelp ? "Twisted ankle near the school" : nil,
                                     inReplyTo: check.requestID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak bot] in
                    guard self?.timer != nil, let bot else { return }
                    _ = try? bot.sendGroup(.checkIn(answer), groupID: groupID)
                }
            }
            reply = nil
        case .groupInvite(let invite):
            let isNewGroup = (bot.groups[invite.groupID]?.key == invite.key) && !greetedGroups.contains("\(bot.nickname):\(invite.groupID)")
            guard isNewGroup else { reply = nil; break } // re-key, not a new group
            greetedGroups.insert("\(bot.nickname):\(invite.groupID)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak bot] in
                guard self?.timer != nil, let bot else { return }
                _ = try? bot.sendGroup(.text("Hi everyone, \(bot.nickname) here 👋"), groupID: invite.groupID)
            }
            if bot.nickname == "Kabir" {
                // Kabir is the worrier: he asks the new group whether everyone is safe.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak bot] in
                    guard self?.timer != nil, let bot else { return }
                    _ = try? bot.sendGroup(.safetyCheck(SafetyCheck(note: "aftershock just now")), groupID: invite.groupID)
                }
            }
            reply = nil
        default:
            reply = nil
        }
        // Read receipt shortly after "reading", then reply.
        if case .direct = message.scope {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak bot] in
                guard self?.timer != nil, let bot else { return }
                bot.sendReadReceipt(for: message.envelope.messageID, to: sender)
            }
        }
        guard let reply else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak bot] in
            guard self?.timer != nil, let bot else { return }
            if case .group(let groupID) = message.scope {
                _ = try? bot.sendGroup(reply, groupID: groupID)
            } else {
                _ = try? bot.sendDirect(reply, to: sender)
            }
        }
    }

    /// Tiny phrasebook standing in for Ravi's model in the demo.
    static func demoTranslate(_ text: String, to language: String) -> String {
        let phrasebook: [String: [String: String]] = [
            "hi": ["help": "मदद", "water": "पानी", "i'm safe": "मैं सुरक्षित हूँ", "hello": "नमस्ते", "fire": "आग"],
            "es": ["help": "ayuda", "water": "agua", "i'm safe": "estoy a salvo", "hello": "hola", "fire": "fuego"],
        ]
        let words = phrasebook[language] ?? [:]
        let lower = text.lowercased()
        if let exact = words[lower] { return exact }
        return words.reduce(lower) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    static func reply(to text: String, from name: String) -> String {
        let lower = text.lowercased()
        if lower.contains("where") { return "I'm near the community hall. Signal is down but the mesh works!" }
        if lower.contains("ok") || lower.contains("safe") { return "Glad you're safe. Stay in touch here." }
        if lower.contains("hi") || lower.contains("hello") { return "Hi! \(name) here. Got your message over the mesh 🙌" }
        return "\(name) got it: “\(text.prefix(60))”"
    }

    /// A bot scans an invite code and asks its admin to join.
    func requestToJoin(_ code: GroupJoinCode, as name: String) {
        _ = try? mesh.node(name).requestToJoin(code)
    }

    /// A bot creates a group with other bots and returns an invite code for it.
    func makeGroupCode(admin: String, members: [String], name: String) -> GroupJoinCode? {
        let node = mesh.node(admin)
        guard let group = try? node.createGroup(name: name, members: Set(members.map { mesh.node($0).peerID })) else { return nil }
        greetedGroups.insert("\(admin):\(group.id)")
        return try? node.makeJoinCode(for: group.id)
    }

    /// Broadcast on the public channel as one of the bots (tests and the `-demoSpam` launch argument).
    func broadcast(_ content: MeshContent, from name: String) {
        _ = try? mesh.node(name).sendBroadcast(content)
    }

    /// Simulate the local device moving out of / back into range (used by UI tests and the demo toggle).
    func setLocalLinks(enabled: Bool) {
        let profile = SimulatedMesh.LinkProfile(mtu: 182, latency: 0.03)
        if enabled {
            mesh.connect(Self.localName, "Asha", profile: profile)
            mesh.connect(Self.localName, "Kabir", profile: profile)
        } else {
            mesh.disconnect(Self.localName, "Asha")
            mesh.disconnect(Self.localName, "Kabir")
        }
    }
}
