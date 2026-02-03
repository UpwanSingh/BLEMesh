import SwiftUI

/// View for creating a new group
struct NewGroupView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var groupName = ""
    @State private var selectedMembers: Set<UUID> = []
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Group Name")) {
                    TextField("Enter group name", text: $groupName)
                }
                
                Section(header: Text("Select Members (\(selectedMembers.count) selected)")) {
                    if viewModel.knownDevices.isEmpty && viewModel.peers.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.3.fill")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No devices available")
                                .font(.headline)
                            Text("Connect to other devices first")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else {
                        // Connected peers
                        ForEach(viewModel.peers.filter { $0.state == .connected }) { peer in
                            MemberSelectionRow(
                                name: peer.name,
                                deviceID: peer.id,
                                isMultiHop: false,
                                isSelected: selectedMembers.contains(peer.id)
                            ) {
                                toggleSelection(peer.id)
                            }
                        }
                        
                        // Known devices via mesh
                        ForEach(viewModel.knownDevices.filter { $0.hopCount > 0 }, id: \.deviceID) { device in
                            MemberSelectionRow(
                                name: device.deviceName,
                                deviceID: device.deviceID,
                                isMultiHop: true,
                                isSelected: selectedMembers.contains(device.deviceID)
                            ) {
                                toggleSelection(device.deviceID)
                            }
                        }
                    }
                }
                
                Section {
                    Button(action: createGroup) {
                        HStack {
                            Spacer()
                            Text("Create Group")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!canCreateGroup)
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    private var canCreateGroup: Bool {
        !groupName.trimmingCharacters(in: .whitespaces).isEmpty && !selectedMembers.isEmpty
    }
    
    private func toggleSelection(_ deviceID: UUID) {
        if selectedMembers.contains(deviceID) {
            selectedMembers.remove(deviceID)
        } else {
            selectedMembers.insert(deviceID)
        }
    }
    
    private func createGroup() {
        let name = groupName.trimmingCharacters(in: .whitespaces)
        viewModel.createGroup(name: name, members: selectedMembers)
        dismiss()
    }
}

struct MemberSelectionRow: View {
    let name: String
    let deviceID: UUID
    let isMultiHop: Bool
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: isMultiHop ? "point.3.connected.trianglepath.dotted" : "iphone")
                    .foregroundColor(isMultiHop ? .purple : .blue)
                    .frame(width: 30)
                
                VStack(alignment: .leading) {
                    Text(name)
                        .foregroundColor(.primary)
                    Text(deviceID.uuidString.prefix(8))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Group settings/management view
struct GroupSettingsView: View {
    let conversation: Conversation
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Group Info")) {
                    HStack {
                        Label("Name", systemImage: "person.3.fill")
                        Spacer()
                        Text(conversation.name)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Label("Created", systemImage: "calendar")
                        Spacer()
                        Text(conversation.createdAt, style: .date)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Label("Members", systemImage: "person.2.fill")
                        Spacer()
                        Text("\(conversation.participantIDs.count)")
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Members")) {
                    ForEach(Array(conversation.otherParticipants), id: \.self) { memberID in
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundColor(.blue)
                                .frame(width: 30)
                            
                            VStack(alignment: .leading) {
                                if let device = viewModel.knownDevices.first(where: { $0.deviceID == memberID }) {
                                    Text(device.deviceName)
                                    if device.hopCount > 0 {
                                        Text("\(device.hopCount) hops away")
                                            .font(.caption)
                                            .foregroundColor(.purple)
                                    }
                                } else {
                                    Text(memberID.uuidString.prefix(8))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                
                Section {
                    Button(action: { showDeleteConfirmation = true }) {
                        Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Group Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Leave this group?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Leave", role: .destructive) {
                    viewModel.leaveGroup(conversation)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will no longer receive messages from this group.")
            }
        }
    }
}

/// Conversation list view showing all chats
struct ConversationListView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var showNewGroup = false
    
    var body: some View {
        NavigationStack {
            List {
                // Groups
                if !viewModel.groups.isEmpty {
                    Section(header: Text("Groups")) {
                        ForEach(viewModel.groups) { group in
                            ConversationRow(conversation: group)
                        }
                    }
                }
                
                // Direct messages from known devices
                Section(header: Text("Direct Messages")) {
                    if viewModel.knownDevices.isEmpty {
                        Text("No direct conversations yet")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.knownDevices, id: \.deviceID) { device in
                            DirectMessageRow(device: device)
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Conversations")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showNewGroup = true }) {
                        Image(systemName: "person.3.fill.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView(viewModel: viewModel)
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var showGroupSettings = false
    
    var body: some View {
        Button(action: {
            viewModel.openConversation(conversation)
        }) {
            HStack {
                Image(systemName: conversation.type == .group ? "person.3.fill" : "person.fill")
                    .foregroundColor(conversation.type == .group ? .purple : .blue)
                    .frame(width: 40, height: 40)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.name)
                        .font(.body)
                        .fontWeight(conversation.unreadCount > 0 ? .semibold : .regular)
                    
                    if let lastMsg = conversation.lastMessage {
                        Text(lastMsg.content)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    if let lastMsg = conversation.lastMessage {
                        Text(lastMsg.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }
                
                // Group settings button
                if conversation.type == .group {
                    Button {
                        showGroupSettings = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if conversation.type == .group {
                Button {
                    showGroupSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .tint(.blue)
            }
            
            Button(role: .destructive) {
                viewModel.leaveGroup(conversation)
            } label: {
                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
        .sheet(isPresented: $showGroupSettings) {
            GroupSettingsView(conversation: conversation)
                .environmentObject(viewModel)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.name), \(conversation.type == .group ? "group" : "direct message"), \(conversation.unreadCount) unread")
        .accessibilityHint("Double tap to open conversation")
    }
}

struct DirectMessageRow: View {
    let device: RoutingService.PeerInfo
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        Button(action: {
            viewModel.selectDestination(device.deviceID)
        }) {
            HStack {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(device.isDirect ? Color.green : Color.purple)
                        .frame(width: 8, height: 8)
                }
                .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.deviceName)
                        .font(.body)
                    
                    HStack(spacing: 4) {
                        Text(device.deviceID.uuidString.prefix(8))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if device.hopCount > 0 {
                            Text("• \(device.hopCount) hops")
                                .font(.caption2)
                                .foregroundColor(.purple)
                        }
                    }
                }
                
                Spacer()
                
                Image(systemName: "message")
                    .foregroundColor(.blue)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("New Group") {
    NewGroupView(viewModel: ChatViewModel.preview)
}

#Preview("Conversation List") {
    ConversationListView()
        .environmentObject(ChatViewModel.preview)
}
