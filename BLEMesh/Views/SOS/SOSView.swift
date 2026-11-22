import SwiftUI
import SwiftData
import MeshCore

/// Send an SOS and see all SOS calls nearby, ranked by on-device triage.
struct SOSView: View {
    @EnvironmentObject private var mesh: MeshService
    @Query(filter: #Predicate<StoredMessage> { $0.conversationKey == "nearby" }, sort: \StoredMessage.sentAt, order: .reverse)
    private var nearbyMessages: [StoredMessage]
    @State private var showCompose = false
    @State private var path: [String] = []
    @State private var showMap = false

    private var reports: [(StoredMessage, SOSReport)] {
        nearbyMessages.compactMap { message in
            guard case .sos(let report)? = message.content else { return nil }
            return (message, report)
        }
        .sorted { lhs, rhs in
            let lp = lhs.1.triage?.priority ?? .medium, rp = rhs.1.triage?.priority ?? .medium
            return lp != rp ? lp > rp : lhs.0.sentAt > rhs.0.sentAt
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button {
                        showCompose = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "sos.circle.fill").font(.system(size: 64))
                            Text("Send SOS").font(.title2.weight(.bold))
                            Text("Reaches every phone in range and is relayed onward")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.Colors.danger))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("sos.compose")
                }
                CheckInSection(path: $path)
                Section {
                    Picker("View", selection: $showMap) {
                        Text("List").tag(false)
                        Text("Map").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("sos.viewPicker")
                    if reports.isEmpty {
                        Text("No SOS calls nearby.").foregroundStyle(Theme.Colors.secondaryText)
                    }
                    if showMap {
                        SOSMapView(reports: reports, me: mesh.myLocation)
                            .frame(height: 360)
                            .listRowInsets(EdgeInsets())
                    } else {
                        ForEach(reports, id: \.0.id) { message, report in
                            SOSRow(message: message, report: report) { key in path.append(key) }
                        }
                    }
                } header: {
                    Text("SOS board (\(reports.count))").foregroundStyle(Theme.Colors.secondaryText)
                } footer: {
                    Text("Ranked by urgency using on-device triage. Treat single, unconfirmed reports with care.").foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            .navigationTitle("SOS")
            .navigationDestination(for: String.self) { key in
                if key.hasPrefix("family:") {
                    FamilyLocatorView(groupKey: String(key.dropFirst("family:".count)))
                } else {
                    ConversationView(conversationKey: key)
                }
            }
            .sheet(isPresented: $showCompose) { SOSComposeView() }
            .task { await mesh.refreshMyLocation() }
            .onChange(of: showMap) { _, map in
                if map { Task { await mesh.refreshMyLocation(prompt: true) } }
            }
        }
    }
}

struct SOSRow: View {
    @EnvironmentObject private var mesh: MeshService
    @Query private var updates: [StoredMessage] // refreshes the row when new SOS updates arrive
    let message: StoredMessage
    let report: SOSReport
    /// Opens a direct chat with the sender (conversation created on tap, not while rendering).
    let onReply: (String) -> Void

    init(message: StoredMessage, report: SOSReport, onReply: @escaping (String) -> Void) {
        self.message = message
        self.report = report
        self.onReply = onReply
        let since = message.sentAt
        _updates = Query(filter: #Predicate<StoredMessage> { $0.conversationKey == "nearby" && $0.sentAt >= since })
    }

    var body: some View {
        let state = mesh.sosState(for: message)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let triage = report.triage {
                    PriorityBadge(priority: triage.priority)
                    Text(L(triage.category.label)).font(.subheadline.weight(.semibold))
                    if let people = triage.peopleAffected { Text("· \(people) people").font(.caption) }
                }
                Spacer()
                Text(message.sentAt, style: .relative).font(.caption2).foregroundStyle(Theme.Colors.secondaryText)
            }
            AdaptiveRow(spacing: 6) {
                StatusPill(status: state.status)
                if !state.responders.isEmpty {
                    Text("\(state.responders.count) responding").font(.caption).foregroundStyle(Theme.Colors.secondaryText)
                }
                if state.resolvedClaims == 1 && state.status != .resolved {
                    Text("1 says resolved").font(.caption).foregroundStyle(Theme.Colors.secondaryText)
                }
                if !message.isOutgoing, let sender = message.sender, mesh.isNewDevice(sender) {
                    InlineLabel("New device", systemImage: "exclamationmark.shield").font(.caption2).foregroundStyle(Theme.Colors.warning)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("sos.newDevice")
                }
            }
            Text(report.triage?.summary ?? report.text).font(.body)
            if report.triage?.summary != nil {
                Text("“\(report.text)”").font(.caption).foregroundStyle(Theme.Colors.secondaryText)
            }
            if let medical = report.medical, !medical.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(medical.summaryLines, id: \.self) { Text($0) }
                }
                .font(.caption)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                .accessibilityIdentifier("sos.medical")
            }
            if !message.isOutgoing || state.responders.isEmpty {
                let helpers = ResponderMatcher.suggest(for: report.triage, among: mesh.peers.filter { $0.peerID != message.sender })
                if !helpers.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: report.triage?.category == .medical ? "cross.case.fill" : "person.badge.shield.checkmark")
                            .accessibilityHidden(true)
                        Text("Nearby: " + helpers.map { "\(mesh.uniqueName(for: $0.peerID)) (\($0.capabilities.contains(.medic) ? "medic" : "rescuer"), \(($0.hops ?? 0) + 1) hop\(($0.hops ?? 0) == 0 ? "" : "s"))" }.joined(separator: ", "))
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.accent)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sos.suggestedResponders")
                }
            }
            ForEach(state.responders, id: \.peer) { responder in
                InlineLabel("\(mesh.uniqueName(for: responder.peer)): \(L(responder.status.label))" + (responder.note.map { " — \($0)" } ?? ""),
                            systemImage: "figure.run")
                    .accessibilityElement(children: .combine)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            HStack(spacing: 10) {
                Text(message.isOutgoing ? "You" : message.senderName).font(.caption.weight(.medium))
                if message.hops > 0 { Text("\(message.hops + 1) hops away").font(.caption) }
                Spacer(minLength: 0)
                if !message.isOutgoing, let sender = message.sender {
                    Button {
                        onReply(mesh.startDirectConversation(with: sender, name: message.senderName))
                    } label: {
                        Text("Reply").font(.caption.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Colors.accent)
                    .fixedSize()
                }
            }
            .foregroundStyle(Theme.Colors.secondaryText)
            if report.location != nil || report.triage?.locationHints.first != nil {
                AdaptiveRow(spacing: 14) {
                    if let location = report.location, let me = mesh.myLocation, !message.isOutgoing {
                        InlineLabel(me.localizedDirections(to: location), systemImage: "location.north.line")
                            .font(.caption.weight(.semibold))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("Distance and direction: \(me.localizedDirections(to: location))"))
                            .accessibilityIdentifier("sos.directions")
                    }
                    if let location = report.location, let url = location.mapsURL {
                        Link(destination: url) {
                            InlineLabel("Location", systemImage: "location.fill").font(.caption)
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .foregroundStyle(Theme.Colors.accent)
                    }
                    if let first = report.triage?.locationHints.first {
                        InlineLabel(first, systemImage: "mappin").font(.caption)
                    }
                }
                .foregroundStyle(Theme.Colors.secondaryText)
            }
            if state.status < .resolved {
                actions
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sos.row")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if message.isOutgoing {
                Button("I'm safe now") { mesh.sendSOSUpdate(sosID: message.id, status: .resolved) }
                    .accessibilityIdentifier("sos.action.resolve")
                Button("Cancel SOS", role: .destructive) { mesh.sendSOSUpdate(sosID: message.id, status: .cancelled) }
                    .accessibilityIdentifier("sos.action.cancel")
            } else {
                Button("I'm responding") { mesh.sendSOSUpdate(sosID: message.id, status: .acknowledged) }
                    .accessibilityIdentifier("sos.action.ack")
                Button("On my way") { mesh.sendSOSUpdate(sosID: message.id, status: .enRoute) }
                    .accessibilityIdentifier("sos.action.enRoute")
                Button("Resolved") { mesh.sendSOSUpdate(sosID: message.id, status: .resolved) }
                    .accessibilityIdentifier("sos.action.resolved")
            }
        }
        .buttonStyle(.borderedProminent) // white on the accessible accent: readable on any row
        .controlSize(.small)
        .font(.caption.weight(.semibold))
    }
}

struct StatusPill: View {
    let status: SOSStatus

    var body: some View {
        Text(L(status.label))
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
            .accessibilityIdentifier("sos.status.\(status.label)")
    }

    private var color: Color {
        switch status {
        case .open: return Theme.Colors.danger
        case .acknowledged: return Theme.Colors.warning
        case .enRoute: return Theme.Colors.accent
        case .resolved: return Theme.Colors.success
        case .cancelled: return Theme.Colors.secondaryText
        }
    }
}

/// "I'm safe" / "I need help" to all your groups, plus each group's family locator.
struct CheckInSection: View {
    @EnvironmentObject private var mesh: MeshService
    @Binding var path: [String]
    @State private var confirmation: String?

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    report(.safe)
                } label: {
                    Label("I'm safe", systemImage: "checkmark.shield.fill").frame(maxWidth: .infinity)
                        .foregroundStyle(.white)
                }
                .tint(Theme.Colors.success)
                .accessibilityIdentifier("checkin.safe")
                Button {
                    report(.needHelp)
                } label: {
                    Label("I need help", systemImage: "exclamationmark.triangle.fill").frame(maxWidth: .infinity)
                        .foregroundStyle(.white)
                }
                .tint(Theme.Colors.warning)
                .accessibilityIdentifier("checkin.needHelp")
            }
            .buttonStyle(.borderedProminent)
            if let confirmation {
                Text(confirmation).font(.caption).foregroundStyle(Theme.Colors.secondaryText)
                    .accessibilityIdentifier("checkin.confirmation")
            }
            ForEach(mesh.groups) { group in
                Button {
                    path.append("family:" + ConversationKey.group(group.id))
                } label: {
                    Label("\(group.name) — who's safe?", systemImage: "person.3.sequence.fill")
                }
                .accessibilityIdentifier("checkin.locator.\(group.name)")
            }
        } header: {
            Text("Check in").foregroundStyle(Theme.Colors.secondaryText)
        } footer: {
            Text(mesh.groups.isEmpty ? "Create a group (e.g. Family) in Chats to share check-ins privately."
                                     : "Sent end-to-end encrypted to your groups, with your battery level.").foregroundStyle(Theme.Colors.secondaryText)
        }
    }

    private func report(_ status: CheckIn.Status) {
        guard !mesh.groups.isEmpty else {
            confirmation = "You're not in any group yet."
            return
        }
        Task {
            let location = mesh.mode == .bluetooth ? await LocationProvider.currentLocation() : nil
            let sent = mesh.sendCheckIn(status, location: location)
            confirmation = sent > 0 ? "Sent to \(sent) group\(sent == 1 ? "" : "s")." : "Nobody is in range yet — try again soon."
        }
    }
}

struct SOSComposeView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var includeLocation = true
    @State private var includeMedical = false
    @State private var preview: SOSTriage?
    @State private var sending = false
    @State private var sentTriage: SOSTriage?

    private let quickPicks = ["Medical emergency", "Someone is trapped", "Fire", "Flood / water rising", "Need water and food", "Lost / missing person"]

    var body: some View {
        NavigationStack {
            Form {
                if let sentTriage {
                    Section {
                        Label("SOS sent to everyone in range", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.Colors.success)
                            .accessibilityIdentifier("sos.sent")
                        HStack { PriorityBadge(priority: sentTriage.priority); Text(sentTriage.summary) }
                    }
                } else {
                    Section {
                        TextField("Describe the emergency, people involved, and landmarks", text: $text, axis: .vertical)
                            .lineLimit(3...8)
                            .accessibilityIdentifier("sos.text")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(quickPicks, id: \.self) { pick in
                                    Button(pick) { text = text.isEmpty ? pick : "\(pick). \(text)" }
                                        .buttonStyle(.bordered)
                                        .font(.caption)
                                }
                            }
                        }
                    } header: { SectionTitle("What's happening?") }
                    Section {
                        Toggle("Include my GPS location", isOn: $includeLocation)
                        if !mesh.trust.medical.isEmpty {
                            Toggle("Attach my medical ID", isOn: $includeMedical)
                                .accessibilityIdentifier("sos.includeMedical")
                        }
                    } footer: {
                        Text("GPS works without internet. Your SOS is signed but not encrypted, so anyone nearby can help — including reading your medical ID if you attach it.").foregroundStyle(Theme.Colors.secondaryText)
                    }
                    if let preview {
                        Section {
                            HStack { PriorityBadge(priority: preview.priority); Text(L(preview.category.label)).bold() }
                            Text(preview.summary).font(.callout)
                            Text(preview.source == "llm" ? "Assessed by on-device AI" : "Assessed by offline rules")
                                .font(.caption2).foregroundStyle(Theme.Colors.secondaryText)
                        } header: { SectionTitle("On-device triage") }
                    }
                }
            }
            .navigationTitle("SOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(sentTriage == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sentTriage == nil {
                        Button {
                            Task { await send() }
                        } label: {
                            if sending { ProgressView() } else { Text("Send SOS").bold() }
                        }
                        .tint(Theme.Colors.danger)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                        .accessibilityIdentifier("sos.send")
                    }
                }
            }
            .task(id: text) {
                guard text.count > 8 else { preview = nil; return }
                try? await Task.sleep(nanoseconds: 600_000_000)
                preview = await mesh.ai.triage(text)
            }
        }
    }

    private func send() async {
        sending = true
        let location = includeLocation && mesh.mode == .bluetooth ? await LocationProvider.currentLocation() : nil
        sentTriage = await mesh.sendSOS(text: text.trimmingCharacters(in: .whitespacesAndNewlines), location: location,
                                        includeMedical: includeMedical)
        sending = false
    }
}
