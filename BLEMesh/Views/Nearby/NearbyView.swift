import SwiftUI
import MeshCore

/// Public channel for everyone in range, with an AI "what's happening around me" digest.
struct NearbyView: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var digestExpanded = true
    @State private var showSpam = false
    @State private var showCatchUp = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RadioStatusBanner()
                DigestCard(expanded: $digestExpanded)
                    .fixedSize(horizontal: false, vertical: true) // never squeezed by the message list
                if mesh.spamHiddenCount > 0 {
                    Button {
                        showSpam.toggle()
                    } label: {
                        Label(showSpam ? "Hide spam" : mesh.spamHiddenCount == 1 ? "1 message hidden as spam — show"
                                : "\(mesh.spamHiddenCount) messages hidden as spam — show",
                              systemImage: "eye.slash")
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("nearby.spamToggle")
                }
                Divider()
                MessageList(conversationKey: ConversationKey.nearby, showSenders: true, includeSpam: showSpam)
                    .id(showSpam)
                Composer(conversationKey: ConversationKey.nearby, placeholder: "Message everyone nearby")
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCatchUp = true } label: { Image(systemName: "text.badge.star") }
                        .accessibilityIdentifier("nearby.catchUp")
                        .accessibilityLabel("Catch me up")
                }
            }
            .sheet(isPresented: $showCatchUp) { CatchUpView(conversationKey: ConversationKey.nearby) }
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
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("digest.refresh")
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
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
                                if let credibility = mesh.digestCredibility[item.id] {
                                    Label(L(credibility.label), systemImage: credibility == .corroborated ? "checkmark.circle"
                                          : (credibility == .disputed ? "exclamationmark.bubble" : "questionmark.circle"))
                                        .font(.caption2)
                                        .foregroundStyle(credibility == .corroborated ? Theme.Colors.success : (credibility == .disputed ? Theme.Colors.danger : Theme.Colors.warning))
                                        .accessibilityIdentifier("digest.credibility.\(credibility.rawValue)")
                                }
                                (Text(item.reporters == 1 ? "1 report" : "\(item.reporters) reports")
                                    + Text(item.locations.first.map { " · \($0)" } ?? ""))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }
                        }
                    }
                    Text(mesh.ai.hasGenerativeModel ? "Summarised on this phone by on-device AI" : "Summarised on this phone (offline rules)")
                        .font(.caption2)
                        .foregroundStyle(Theme.Colors.secondaryText)
                } else {
                    Text("Summarises the last hour of public messages and SOS calls nearby — on your phone, offline.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
        .padding()
        .background(Theme.Colors.card)
        .task { if mesh.digest == nil { await mesh.refreshDigest() } }
    }
}
