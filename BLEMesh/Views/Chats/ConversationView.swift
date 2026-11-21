import SwiftUI
import SwiftData
import MeshCore

/// A single conversation (direct, group, or the public Nearby channel when embedded).
struct ConversationView: View {
    @EnvironmentObject private var mesh: MeshService
    let conversationKey: String
    @State private var showInfo = false

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
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
                    .accessibilityIdentifier("conversation.info")
            }
        }
        .sheet(isPresented: $showInfo) { ConversationInfoView(conversationKey: conversationKey) }
        .onAppear {
            mesh.openConversationKey = conversationKey
            mesh.markRead(key: conversationKey)
        }
        .onDisappear {
            if mesh.openConversationKey == conversationKey { mesh.openConversationKey = nil }
        }
    }

    private var title: String { mesh.fetchConversation(conversationKey)?.title ?? "Chat" }

    private var subtitle: String {
        if let peer = ConversationKey.peer(from: conversationKey) {
            guard let hops = mesh.peers.first(where: { $0.peerID == peer })?.hops else { return "Out of range · messages will wait" }
            return hops == 0 ? "Nearby · end-to-end encrypted" : "\(hops + 1) hops · end-to-end encrypted"
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

    init(conversationKey: String, showSenders: Bool) {
        _messages = Query(filter: #Predicate<StoredMessage> { $0.conversationKey == conversationKey },
                          sort: \StoredMessage.sentAt)
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
    @Environment(\.dismiss) private var dismiss
    let conversationKey: String
    @State private var confirmLeave = false

    var body: some View {
        NavigationStack {
            List {
                if let peerID = ConversationKey.peer(from: conversationKey), let peer = mesh.peerInfo(peerID) {
                    Section("Contact") {
                        LabeledContent("Name", value: peer.nickname)
                        LabeledContent("Mesh ID", value: peer.peerID.short)
                        LabeledContent("Reachability", value: peer.hops.map { $0 == 0 ? "Direct" : "\($0 + 1) hops" } ?? "Out of range")
                        if peer.capabilities.contains(.onDeviceAI) {
                            Label("Can answer Ask-the-Mesh questions", systemImage: "sparkles")
                        }
                    }
                    Section {
                        Text(peer.identity.fingerprint).font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("info.theirSafetyNumber")
                        Text(mesh.myFingerprint).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    } header: {
                        Text("Safety numbers (theirs, then yours)")
                    } footer: {
                        Text("Compare these in person. If they match on both phones, nobody is impersonating either of you.")
                    }
                }
                if let group = mesh.group(for: conversationKey) {
                    Section("Members") {
                        ForEach(group.members.sorted(), id: \.self) { member in
                            Text(member == mesh.myPeerID ? "\(mesh.displayName(for: member)) (you)" : mesh.displayName(for: member))
                        }
                    }
                    Section {
                        Button("Leave group", role: .destructive) { confirmLeave = true }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
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
