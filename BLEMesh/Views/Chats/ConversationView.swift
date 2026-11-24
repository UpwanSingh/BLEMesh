import SwiftUI
import SwiftData
import MeshCore

/// A single conversation (direct, group, or the public Nearby channel when embedded).
struct ConversationView: View {
    @EnvironmentObject private var mesh: MeshService
    let conversationKey: String
    @State private var showInfo = false
    @State private var showCatchUp = false

    var body: some View {
        VStack(spacing: 0) {
            MessageList(conversationKey: conversationKey, showSenders: ConversationKey.peer(from: conversationKey) == nil)
            Composer(conversationKey: conversationKey)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption2).foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCatchUp = true } label: { Image(systemName: "text.badge.star") }
                    .accessibilityIdentifier("conversation.catchUp")
                    .accessibilityLabel("Catch me up")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
                    .accessibilityIdentifier("conversation.info")
            }
        }
        .sheet(isPresented: $showInfo) { ConversationInfoView(conversationKey: conversationKey) }
        .sheet(isPresented: $showCatchUp) { CatchUpView(conversationKey: conversationKey) }
        .onAppear {
            mesh.openConversationKey = conversationKey
            mesh.markRead(key: conversationKey)
        }
        .onDisappear {
            if mesh.openConversationKey == conversationKey { mesh.openConversationKey = nil }
        }
    }

    private var title: String {
        if let peer = ConversationKey.peer(from: conversationKey) { return mesh.uniqueName(for: peer) }
        return mesh.fetchConversation(conversationKey)?.title ?? "Chat"
    }

    private var subtitle: String {
        if let peer = ConversationKey.peer(from: conversationKey) {
            guard let hops = mesh.peers.first(where: { $0.peerID == peer })?.hops else { return "Out of range · messages will wait" }
            let verified = mesh.trust.isVerified(peer) ? "✓ Verified · " : ""
            return verified + (hops == 0 ? "Nearby · end-to-end encrypted" : "\(hops + 1) hops · end-to-end encrypted")
        }
        if let group = mesh.group(for: conversationKey) {
            return "\(group.members.count) members · encrypted group"
        }
        return ""
    }
}

struct MessageList: View {
    @Query private var messages: [StoredMessage]
    let showSenders: Bool

    init(conversationKey: String, showSenders: Bool, includeSpam: Bool = false) {
        if includeSpam {
            _messages = Query(filter: #Predicate<StoredMessage> { $0.conversationKey == conversationKey },
                              sort: \StoredMessage.sentAt)
        } else {
            _messages = Query(filter: #Predicate<StoredMessage> { $0.conversationKey == conversationKey && $0.isSpam == false },
                              sort: \StoredMessage.sentAt)
        }
        self.showSenders = showSenders
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message, showSender: showSenders)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

/// Safety number, reachability and group membership.
struct ConversationInfoView: View {
    @EnvironmentObject private var mesh: MeshService
    @EnvironmentObject private var trust: TrustStore
    @Environment(\.dismiss) private var dismiss
    let conversationKey: String
    @State private var confirmLeave = false
    @State private var showInvite = false
    @State private var confirmReport = false
    @State private var verifying = false
    @State private var showLocator = false
    @State private var askedSafety = false

    var body: some View {
        NavigationStack {
            List {
                if let peerID = ConversationKey.peer(from: conversationKey), let peer = mesh.peerInfo(peerID) {
                    Section {
                        InfoRow("Name", value: mesh.uniqueName(for: peer.peerID))
                        if trust.isVerified(peer.peerID) {
                            Label("Verified in person", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.Colors.success)
                                .accessibilityIdentifier("info.verified")
                        } else if mesh.impersonatesVerifiedContact(peer.peerID) {
                            Label("Not your verified “\(peer.nickname)” — same name, different device", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.Colors.danger)
                                .accessibilityIdentifier("info.impersonation")
                        }
                        InfoRow("Mesh ID", value: peer.peerID.short)
                        InfoRow("Reachability", value: peer.hops.map { $0 == 0 ? "Direct" : "\($0 + 1) hops" } ?? "Out of range")
                        if peer.capabilities.contains(.onDeviceAI) {
                            Label("Can answer Ask-the-Mesh questions", systemImage: "sparkles")
                        }
                    } header: { SectionTitle("Contact") }
                    Section {
                        Text(peer.identity.fingerprint).font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("info.theirSafetyNumber")
                        Text(mesh.myFingerprint).font(.system(.body, design: .monospaced)).foregroundStyle(Theme.Colors.secondaryText)
                    } header: {
                        Text("Safety numbers (theirs, then yours)").foregroundStyle(Theme.Colors.secondaryText)
                    } footer: {
                        Text("Compare these in person. If they match on both phones, nobody is impersonating either of you.").foregroundStyle(Theme.Colors.secondaryText)
                    }
                    Section {
                        Button {
                            verifying = true
                        } label: {
                            Label(trust.isVerified(peer.peerID) ? "Verified — show codes" : "Verify with QR code", systemImage: "qrcode")
                        }
                        .accessibilityIdentifier("info.verify")
                        Button(trust.isBlocked(peer.peerID) ? "Unblock" : "Block") {
                            trust.setBlocked(peer.peerID, !trust.isBlocked(peer.peerID))
                        }
                        .accessibilityIdentifier("info.block")
                        Button("Report as spam or abuse", role: .destructive) { confirmReport = true }
                            .accessibilityIdentifier("info.report")
                    } footer: {
                        Text("Blocked and reported devices disappear from this phone. Their traffic is still relayed for others.").foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
                if let group = mesh.group(for: conversationKey) {
                    Section {
                        ForEach(group.members.sorted(), id: \.self) { member in
                            HStack {
                                Text(member == mesh.myPeerID ? "\(mesh.nickname) (you)" : mesh.uniqueName(for: member))
                                if trust.isVerified(member) { Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.Colors.success) }
                                Spacer()
                                if member == group.admin { Text("Admin").font(.caption).foregroundStyle(Theme.Colors.secondaryText) }
                                if mesh.isGroupAdmin(groupKey: conversationKey) && member != mesh.myPeerID {
                                    Button("Remove") { mesh.removeMember(member, groupKey: conversationKey) }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(Theme.Colors.danger)
                                        .accessibilityIdentifier("info.remove.\(mesh.displayName(for: member))")
                                }
                            }
                        }
                        if mesh.isGroupAdmin(groupKey: conversationKey) {
                            Button {
                                showInvite = true
                            } label: {
                                Label("Invite with QR code", systemImage: "qrcode")
                            }
                            .accessibilityIdentifier("info.invite")
                        }
                    } header: {
                        Text("Members").foregroundStyle(Theme.Colors.secondaryText)
                    } footer: {
                        Text("Removing someone, or anyone leaving, changes the group key so they can't read new messages.").foregroundStyle(Theme.Colors.secondaryText)
                    }
                    Section {
                        NavigationLink {
                            FamilyLocatorView(groupKey: conversationKey)
                        } label: {
                            Label("Who's safe? (family locator)", systemImage: "person.3.sequence.fill")
                        }
                        .accessibilityIdentifier("info.locator")
                        Button {
                            askedSafety = mesh.askAreYouSafe(groupKey: conversationKey)
                        } label: {
                            Label(askedSafety ? "Asked everyone" : "Ask everyone: are you safe?", systemImage: "questionmark.bubble")
                        }
                        .accessibilityIdentifier("info.askSafe")
                    }
                    Section {
                        Button("Leave group", role: .destructive) { confirmLeave = true }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            // Presented from the list level: sheets attached to lazily-built rows may never appear.
            .sheet(isPresented: $showInvite) { GroupInviteCodeView(groupKey: conversationKey) }
            .sheet(isPresented: $verifying) {
                if let peer = ConversationKey.peer(from: conversationKey) { VerifyContactView(peer: peer) }
            }
            .confirmationDialog("Report and block this device?", isPresented: $confirmReport, titleVisibility: .visible) {
                Button("Report and block", role: .destructive) {
                    if let peer = ConversationKey.peer(from: conversationKey) { trust.report(peer) }
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) {
                    mesh.leaveGroup(key: conversationKey)
                    dismiss()
                }
            }
        }
    }
}


/// #10: "what did I miss?" — the important messages since you last opened this chat, plus a
/// short summary written on this phone (or by a nearby AI phone).
struct CatchUpView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    let conversationKey: String
    @State private var result: (summary: CatchUpSummary, abstract: String?)?

    var body: some View {
        NavigationStack {
            List {
                if let result {
                    Section {
                        Text(result.summary.overview).font(.headline)
                            .accessibilityIdentifier("catchup.overview")
                        if let abstract = result.abstract {
                            Text(abstract).font(.callout).accessibilityIdentifier("catchup.abstract")
                        }
                    }
                    if !result.summary.highlights.isEmpty {
                        Section {
                            ForEach(result.summary.highlights, id: \.id) { message in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(message.senderName).font(.caption.weight(.semibold))
                                    Text(message.text)
                                    Text(message.date, style: .relative).font(.caption2).foregroundStyle(Theme.Colors.secondaryText)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("catchup.highlight")
                            }
                        } header: { SectionTitle("Most important") }
                    }
                } else {
                    HStack { ProgressView(); Text("Reading what you missed…") }
                }
            }
            .navigationTitle("Catch me up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { result = await mesh.catchUp(key: conversationKey) }
        }
    }
}
