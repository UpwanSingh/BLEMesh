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
                                .opacity(0.9)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 20).fill(Color.red.gradient))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("sos.compose")
                }
                Section {
                    if reports.isEmpty {
                        Text("No SOS calls nearby.").foregroundStyle(.secondary)
                    }
                    ForEach(reports, id: \.0.id) { message, report in
                        SOSRow(message: message, report: report) { key in path.append(key) }
                    }
                } header: {
                    Text("SOS board (\(reports.count))")
                } footer: {
                    Text("Ranked by urgency using on-device triage. Treat single, unconfirmed reports with care.")
                }
            }
            .navigationTitle("SOS")
            .navigationDestination(for: String.self) { key in ConversationView(conversationKey: key) }
            .sheet(isPresented: $showCompose) { SOSComposeView() }
        }
    }
}

struct SOSRow: View {
    @EnvironmentObject private var mesh: MeshService
    let message: StoredMessage
    let report: SOSReport
    /// Opens a direct chat with the sender (conversation created on tap, not while rendering).
    let onReply: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let triage = report.triage {
                    PriorityBadge(priority: triage.priority)
                    Text(triage.category.label).font(.subheadline.weight(.semibold))
                    if let people = triage.peopleAffected { Text("· \(people) people").font(.caption) }
                }
                Spacer()
                Text(message.sentAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            Text(report.triage?.summary ?? report.text).font(.body)
            if report.triage?.summary != nil {
                Text("“\(report.text)”").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text(message.isOutgoing ? "You" : message.senderName).font(.caption.weight(.medium))
                if message.hops > 0 { Text("\(message.hops + 1) hops away").font(.caption) }
                if let location = report.location, let url = location.mapsURL {
                    Link(destination: url) { Label("Location", systemImage: "location.fill").font(.caption) }
                }
                if let hints = report.triage?.locationHints, let first = hints.first {
                    Label(first, systemImage: "mappin").font(.caption)
                }
                Spacer()
                if !message.isOutgoing, let sender = message.sender {
                    Button {
                        onReply(mesh.startDirectConversation(with: sender, name: message.senderName))
                    } label: {
                        Text("Reply").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sos.row")
    }
}

struct SOSComposeView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var includeLocation = true
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
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("sos.sent")
                        HStack { PriorityBadge(priority: sentTriage.priority); Text(sentTriage.summary) }
                    }
                } else {
                    Section("What's happening?") {
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
                    }
                    Section {
                        Toggle("Include my GPS location", isOn: $includeLocation)
                    } footer: {
                        Text("GPS works without internet. Your SOS is signed but not encrypted, so anyone nearby can help.")
                    }
                    if let preview {
                        Section("On-device triage") {
                            HStack { PriorityBadge(priority: preview.priority); Text(preview.category.label).bold() }
                            Text(preview.summary).font(.callout)
                            Text(preview.source == "llm" ? "Assessed by on-device AI" : "Assessed by offline rules")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
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
                        .tint(.red)
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
        sentTriage = await mesh.sendSOS(text: text.trimmingCharacters(in: .whitespacesAndNewlines), location: location)
        sending = false
    }
}
