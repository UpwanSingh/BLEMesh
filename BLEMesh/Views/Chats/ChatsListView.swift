import SwiftUI
import SwiftData
import MeshCore

struct ChatsListView: View {
    @EnvironmentObject private var mesh: MeshService
    @Query(filter: #Predicate<StoredConversation> { $0.kindRaw == 1 || $0.kindRaw == 2 },
           sort: \StoredConversation.updatedAt, order: .reverse)
    private var conversations: [StoredConversation]

    @State private var showPeerPicker = false
    @State private var showNewGroup = false
    @State private var showSettings = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                RadioStatusBanner()
                List {
                    if conversations.isEmpty {
                        ContentUnavailableView {
                            Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("Start a private, end-to-end encrypted chat with anyone the mesh can reach.")
                        } actions: {
                            Button("New Chat") { showPeerPicker = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    ForEach(conversations) { conversation in
                        NavigationLink(value: conversation.key) {
                            ConversationRow(conversation: conversation)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                if conversation.kind == .group {
                                    mesh.leaveGroup(key: conversation.key)
                                } else {
                                    mesh.deleteConversation(key: conversation.key)
                                }
                            } label: {
                                Label(conversation.kind == .group ? "Leave" : "Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Chats")
            .navigationDestination(for: String.self) { key in
                ConversationView(conversationKey: key)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityIdentifier("chats.settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showNewGroup = true } label: { Image(systemName: "person.3") }
                        .accessibilityIdentifier("chats.newGroup")
                        .accessibilityLabel("New group")
                    Button { showPeerPicker = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityIdentifier("chats.newChat")
                        .accessibilityLabel("New chat")
                }
            }
            .sheet(isPresented: $showPeerPicker) {
                PeerPickerView { peer in
                    let key = mesh.startDirectConversation(with: peer)
                    showPeerPicker = false
                    path = [key]
                }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView { key in
                    showNewGroup = false
                    path = [key]
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

struct ConversationRow: View {
    @EnvironmentObject private var mesh: MeshService
    let conversation: StoredConversation

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(name: conversation.title, size: 44, tint: conversation.kind == .group ? .purple : .blue)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.title).font(.headline).lineLimit(1)
                    if conversation.kind == .group {
                        Image(systemName: "person.3.fill").font(.caption).foregroundStyle(.purple)
                    }
                    Spacer()
                    Text(conversation.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                HStack {
                    Text(conversation.lastPreview.isEmpty ? reachability : conversation.lastPreview)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("conversation.\(conversation.title)")
    }

    private var reachability: String {
        guard let peer = ConversationKey.peer(from: conversation.key) else { return "Group" }
        guard let hops = mesh.peers.first(where: { $0.peerID == peer })?.hops else { return "Out of range — messages will wait" }
        return hops == 0 ? "Nearby" : "\(hops + 1) hops away"
    }
}

/// Pick someone the mesh knows about (by mesh identity — never by Bluetooth identifiers).
struct PeerPickerView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    let onPick: (PeerInfo) -> Void

    var body: some View {
        NavigationStack {
            List {
                let reachable = mesh.peers.filter(\.isReachable)
                let offline = mesh.peers.filter { !$0.isReachable }
                if mesh.peers.isEmpty {
                    ContentUnavailableView("Nobody nearby yet", systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text("Other phones running BLE Mesh appear here automatically when in range."))
                }
                if !reachable.isEmpty {
                    Section {
                        ForEach(reachable) { peer in row(peer) }
                    } header: { SectionTitle("Reachable now") }
                }
                if !offline.isEmpty {
                    Section {
                        ForEach(offline) { peer in row(peer) }
                    } header: { SectionTitle("Seen before — messages wait until they're back") }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func row(_ peer: PeerInfo) -> some View {
        Button { onPick(peer) } label: {
            HStack {
                PeerAvatar(name: peer.nickname)
                VStack(alignment: .leading) {
                    HStack(spacing: 4) {
                        Text(mesh.uniqueName(for: peer.peerID)).foregroundStyle(.primary)
                        if mesh.trust.isVerified(peer.peerID) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.Colors.success).accessibilityLabel("Verified")
                        }
                    }
                    if mesh.impersonatesVerifiedContact(peer.peerID) {
                        Text("Same name as a verified contact — not them").font(.caption2).foregroundStyle(Theme.Colors.danger)
                    }
                    Text(peer.hops.map { $0 == 0 ? "Direct connection" : "\($0 + 1) hops away" } ?? "Out of range")
                        .font(.caption).foregroundStyle(Theme.Colors.secondaryText)
                }
                Spacer()
                if peer.capabilities.contains(.onDeviceAI) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.Colors.warning).accessibilityLabel("Has on-device AI")
                }
            }
        }
        .accessibilityIdentifier("peer.\(peer.nickname)")
    }
}

struct NewGroupView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void
    @State private var name = ""
    @State private var selected: Set<PeerID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Family, Rescue team", text: $name)
                        .accessibilityIdentifier("group.name")
                } header: { SectionTitle("Group name") }
                Section {
                    if mesh.peers.isEmpty {
                        Text("No one to add yet — people appear when they're in range.").foregroundStyle(Theme.Colors.secondaryText)
                    }
                    ForEach(mesh.peers) { peer in
                        Button {
                            if selected.contains(peer.peerID) { selected.remove(peer.peerID) } else { selected.insert(peer.peerID) }
                        } label: {
                            HStack {
                                PeerAvatar(name: peer.nickname, size: 30)
                                Text(peer.nickname).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selected.contains(peer.peerID) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(peer.peerID) ? Color.accentColor : .secondary)
                            }
                        }
                        .accessibilityIdentifier("groupMember.\(peer.nickname)")
                    }
                } header: {
                    Text("Members (\(selected.count))").foregroundStyle(Theme.Colors.secondaryText)
                } footer: {
                    Text("Members get the group key in an end-to-end encrypted invite. Phones that relay group messages can't read them.").foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if let key = mesh.createGroup(name: name, members: selected) { onCreated(key) }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                    .accessibilityIdentifier("group.create")
                }
            }
        }
    }
}
