import SwiftUI

/// Main chat interface with conversation support
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    @State private var showDestinationPicker = false
    @State private var showNewGroupSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Destination bar
            destinationBar
            
            // Message list
            messageList
            
            // Input area
            inputArea
        }
        .sheet(isPresented: $showDestinationPicker) {
            DestinationPickerSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showNewGroupSheet) {
            NewGroupView(viewModel: viewModel)
        }
        .navigationTitle(destinationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Destination Bar
    
    private var destinationBar: some View {
        HStack {
            Button {
                showDestinationPicker = true
            } label: {
                HStack(spacing: 8) {
                    destinationIcon
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(destinationTitle)
                            .font(.headline)
                        
                        Text(destinationSubtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select message destination")
            .accessibilityHint("Tap to change who receives your messages")
            
            // Encryption indicator
            if viewModel.encryptionEnabled && viewModel.selectedDestination != nil {
                Image(systemName: "lock.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                    .accessibilityLabel("End-to-end encryption enabled")
            }
        }
        .padding()
        .background(Color(.systemGray6))
    }
    
    private var destinationIcon: some View {
        Group {
            if viewModel.selectedGroup != nil {
                Image(systemName: "person.3.fill")
                    .foregroundColor(.purple)
                    .accessibilityHidden(true)
            } else if viewModel.selectedDestination != nil {
                Image(systemName: "person.fill")
                    .foregroundColor(.blue)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 30, height: 30)
        .background(Color(.systemGray5))
        .clipShape(Circle())
    }
    
    private var destinationTitle: String {
        if let group = viewModel.selectedGroup {
            return group.name
        } else if let destID = viewModel.selectedDestination,
                  let peer = viewModel.availablePeers.first(where: { $0.id == destID }) {
            return peer.name
        } else {
            return "Broadcast"
        }
    }
    
    private var destinationSubtitle: String {
        if let group = viewModel.selectedGroup {
            return "\(group.otherParticipants.count + 1) members"
        } else if viewModel.selectedDestination != nil {
            return "Direct message"
        } else {
            return "All nearby devices"
        }
    }
    
    // MARK: - Message List
    
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if filteredMessages.isEmpty {
                    emptyStateView
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredMessages) { message in
                            ChatMessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastMessage = filteredMessages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: emptyStateIcon)
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text(emptyStateTitle)
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text(emptyStateSubtitle)
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
    
    private var emptyStateIcon: String {
        if viewModel.selectedGroup != nil {
            return "person.3"
        } else if viewModel.selectedDestination != nil {
            return "bubble.left.and.bubble.right"
        } else {
            return "antenna.radiowaves.left.and.right"
        }
    }
    
    private var emptyStateTitle: String {
        if viewModel.selectedGroup != nil {
            return "No group messages yet"
        } else if viewModel.selectedDestination != nil {
            return "No messages yet"
        } else {
            return "No broadcast messages"
        }
    }
    
    private var emptyStateSubtitle: String {
        if viewModel.selectedGroup != nil {
            return "Send a message to start the group conversation"
        } else if viewModel.selectedDestination != nil {
            return "Send a message to start the conversation"
        } else {
            return "Broadcast a message to all nearby devices"
        }
    }
    
    private var filteredMessages: [MeshMessage] {
        // In a full implementation, filter by conversation
        viewModel.messages
    }
    
    // MARK: - Input Area
    
    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 12) {
                // Encryption toggle
                Button {
                    viewModel.encryptionEnabled.toggle()
                } label: {
                    Image(systemName: viewModel.encryptionEnabled ? "lock.fill" : "lock.open")
                        .foregroundColor(viewModel.encryptionEnabled ? .green : .gray)
                }
                .disabled(viewModel.selectedDestination == nil)
                
                // Text field
                TextField("Message", text: $viewModel.messageText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .onSubmit {
                        viewModel.sendMessage()
                    }
                
                // Send button
                Button {
                    viewModel.sendMessage()
                    isInputFocused = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(viewModel.messageText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isSending)
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Chat Message Bubble

struct ChatMessageBubble: View {
    let message: MeshMessage
    
    var body: some View {
        HStack {
            if message.isFromLocalDevice {
                Spacer(minLength: 60)
            }
            
            VStack(alignment: message.isFromLocalDevice ? .trailing : .leading, spacing: 4) {
                if !message.isFromLocalDevice {
                    Text(message.senderName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isFromLocalDevice ? Color.blue : Color(.systemGray5))
                    .foregroundColor(message.isFromLocalDevice ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                
                HStack(spacing: 4) {
                    Text(formatTime(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if message.isFromLocalDevice {
                        deliveryStatusIcon
                    }
                }
            }
            
            if !message.isFromLocalDevice {
                Spacer(minLength: 60)
            }
        }
    }
    
    private var deliveryStatusIcon: some View {
        Group {
            switch message.deliveryStatus {
            case .pending:
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
            case .sent:
                Image(systemName: "checkmark")
                    .foregroundColor(.secondary)
            case .delivered:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
            case .read:
                Image(systemName: "eye.fill")
                    .foregroundColor(.blue)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }
        }
        .font(.caption2)
    }
    
    /// Cached DateFormatter for performance (creating DateFormatter is expensive)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
    
    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}

// MARK: - Destination Picker Sheet

struct DestinationPickerSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                // Broadcast option
                Section {
                    Button {
                        viewModel.selectedDestination = nil
                        viewModel.selectedGroup = nil
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.orange)
                                .frame(width: 30)
                            
                            VStack(alignment: .leading) {
                                Text("Broadcast")
                                    .foregroundColor(.primary)
                                Text("Send to all nearby devices")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if viewModel.selectedDestination == nil && viewModel.selectedGroup == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                
                // Direct messages
                Section("Direct Messages") {
                    ForEach(viewModel.availablePeers) { peer in
                        Button {
                            viewModel.selectedDestination = peer.id
                            viewModel.selectedGroup = nil
                            dismiss()
                        } label: {
                            HStack {
                                Circle()
                                    .fill(peer.isConnected ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                
                                VStack(alignment: .leading) {
                                    Text(peer.name)
                                        .foregroundColor(.primary)
                                    
                                    if let hopCount = viewModel.hopCountTo(peer.id) {
                                        Text("\(hopCount) hop\(hopCount > 1 ? "s" : "")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                if viewModel.selectedDestination == peer.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                    
                    if viewModel.availablePeers.isEmpty {
                        Text("No peers discovered")
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
                
                // Groups
                Section("Groups") {
                    ForEach(viewModel.groups) { group in
                        Button {
                            viewModel.selectedGroup = group
                            viewModel.selectedDestination = nil
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "person.3.fill")
                                    .foregroundColor(.purple)
                                    .frame(width: 30)
                                
                                VStack(alignment: .leading) {
                                    Text(group.name)
                                        .foregroundColor(.primary)
                                    Text("\(group.otherParticipants.count + 1) members")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                if viewModel.selectedGroup?.id == group.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                    
                    Button {
                        dismiss()
                        // Trigger new group sheet from parent
                    } label: {
                        Label("Create New Group", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Send To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ChatView(viewModel: .preview)
}
