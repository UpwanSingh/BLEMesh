import SwiftUI
import MeshCore

/// Public channel for everyone in range, with an AI "what's happening around me" digest.
struct NearbyView: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var digestExpanded = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RadioStatusBanner()
                DigestCard(expanded: $digestExpanded)
                Divider()
                MessageList(conversationKey: ConversationKey.nearby, showSenders: true)
                Composer(conversationKey: ConversationKey.nearby, placeholder: "Message everyone nearby")
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                mesh.openConversationKey = ConversationKey.nearby
                mesh.markRead(key: ConversationKey.nearby)
            }
            .onDisappear {
                if mesh.openConversationKey == ConversationKey.nearby { mesh.openConversationKey = nil }
            }
        }
    }
}

struct DigestCard: View {
    @EnvironmentObject private var mesh: MeshService
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Area summary", systemImage: "sparkles.rectangle.stack")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if mesh.isBuildingDigest {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await mesh.refreshDigest() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("digest.refresh")
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .accessibilityIdentifier("digest.toggle")
                .accessibilityLabel(expanded ? "Collapse summary" : "Expand summary")
            }
            if expanded {
                if let digest = mesh.digest {
                    Text(mesh.digestOverview)
                        .font(.callout)
                        .accessibilityIdentifier("digest.overview")
                    ForEach(digest.items.prefix(4)) { item in
                        HStack(alignment: .top, spacing: 6) {
                            PriorityBadge(priority: item.priority)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.headline).font(.caption)
                                Text("\(item.reporters) report\(item.reporters == 1 ? "" : "s")\(item.locations.first.map { " · \($0)" } ?? "")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(mesh.ai.hasGenerativeModel ? "Summarised on this phone by on-device AI" : "Summarised on this phone (offline rules)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Summarises the last hour of public messages and SOS calls nearby — on your phone, offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Theme.Colors.card)
        .task { if mesh.digest == nil { await mesh.refreshDigest() } }
    }
}
