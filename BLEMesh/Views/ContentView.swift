import SwiftUI

/// Main content view with tabbed navigation
// Local theme tokens (kept here so the file builds even if Theme.swift isn't included in the Xcode target)
private enum ThemeLocal {
    enum Colors {
        static let primary = SwiftUI.Color("AccentColor")
        static let background = SwiftUI.Color(.systemBackground)
        static let card = SwiftUI.Color(.secondarySystemBackground)
        static let accent = SwiftUI.Color.blue
        static let success = SwiftUI.Color.green
        static let muted = SwiftUI.Color(.secondaryLabel)
    }

    enum Spacing {
        static let small: CGFloat = 6
        static let base: CGFloat = 12
        static let large: CGFloat = 20
    }

    enum Corner {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }
}

// Namespace alias to match our Theme reference pattern
private struct Theme {
    typealias Color = ThemeLocal.Colors
    typealias Spacing = ThemeLocal.Spacing
    typealias Corner = ThemeLocal.Corner
}

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var showSettings = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status header
                StatusHeaderView()
                
                Divider()
                
                // Main content in tabs
                TabView {
                    // Chat tab
                    ChatTabView()
                        .navigationTitle("Messages")
                        .navigationBarTitleDisplayMode(.inline)
                        .tabItem {
                            Label("Chat", systemImage: "message.fill")
                        }
                        .badge(viewModel.stats.messagesReceived > 0 ? viewModel.stats.messagesReceived : 0)
                    
                    // Conversations tab
                    ConversationListView()
                        .tabItem {
                            Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
                        }
                        .badge(viewModel.groups.count)
                    
                    // Network tab (Peers + Routes)
                    NetworkTabView()
                        .navigationTitle("Network")
                        .navigationBarTitleDisplayMode(.inline)
                        .tabItem {
                            Label("Network", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    
                    // Debug tab
                    DebugView()
                        .tabItem {
                            Label("Debug", systemImage: "ladybug")
                        }
                }
            }
            .navigationTitle("BLE Mesh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Status Header

struct StatusHeaderView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        VStack(spacing: 4) {
            // Device info
            HStack {
                Image(systemName: viewModel.isBluetoothReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(viewModel.isBluetoothReady ? .green : .red)
                
                Text(viewModel.bluetoothStatus)
                    .font(.caption)
                
                Spacer()
                
                Text("ID: \(viewModel.localDeviceID)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Connection stats
            HStack {
                // Connected peers
                Label("\(viewModel.connectedPeersCount)", systemImage: "link")
                    .font(.caption2)
                
                Spacer()
                
                // Known devices (via routing)
                if viewModel.knownDevices.count > 0 {
                    Label("\(viewModel.knownDevices.count) reachable", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption2)
                        .foregroundColor(.purple)
                }
                
                Spacer()
                
                // Mode indicator
                Text(viewModel.messagingMode)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(viewModel.selectedDestination != nil ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }
}

// MARK: - Chat Tab

struct ChatTabView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var showDestinationPicker = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Destination selector bar
            DestinationBar(showPicker: $showDestinationPicker)
            
            Divider()
            
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Input area
            MessageInputView()
        }
        .sheet(isPresented: $showDestinationPicker) {
            DestinationPickerView()
        }
    }
}

// MARK: - Destination Bar

struct DestinationBar: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var showPicker: Bool
    
    var body: some View {
        HStack {
            // Current destination display
            Button(action: { showPicker = true }) {
                HStack {
                    Image(systemName: viewModel.selectedDestination != nil ? "person.fill" : "megaphone.fill")
                        .foregroundColor(viewModel.selectedDestination != nil ? .blue : .green)
                    
                    if let destID = viewModel.selectedDestination {
                        if let device = viewModel.knownDevices.first(where: { $0.deviceID == destID }) {
                            Text(device.deviceName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            if device.hopCount > 0 {
                                Text("(\(device.hopCount) hop\(device.hopCount > 1 ? "s" : ""))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text(destID.uuidString.prefix(8))
                                .font(.subheadline)
                        }
                    } else {
                        Text("Broadcast to All")
                            .font(.subheadline)
                    }
                    
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Quick broadcast button
            if viewModel.selectedDestination != nil {
                Button(action: { viewModel.selectDestination(nil) }) {
                    Image(systemName: "megaphone")
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Destination Picker

struct DestinationPickerView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                // Broadcast option
                Section {
                    Button(action: {
                        viewModel.selectDestination(nil)
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: "megaphone.fill")
                                .foregroundColor(.green)
                                .frame(width: 30)
                            
                            VStack(alignment: .leading) {
                                Text("Broadcast")
                                    .font(.body)
                                Text("Send to all connected devices")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if viewModel.selectedDestination == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                
                // Direct connected peers
                if !viewModel.peers.filter({ $0.state == .connected }).isEmpty {
                    Section(header: Text("Direct Connections")) {
                        ForEach(viewModel.peers.filter { $0.state == .connected }) { peer in
                            PeerDestinationRow(
                                name: peer.name,
                                deviceID: peer.id,
                                hopCount: 0,
                                rssi: peer.rssi,
                                isSelected: viewModel.selectedDestination == peer.id
                            ) {
                                viewModel.selectDestination(peer.id)
                                dismiss()
                            }
                        }
                    }
                }
                
                // Multi-hop reachable devices
                let multiHopDevices = viewModel.knownDevices.filter { $0.hopCount > 0 }
                if !multiHopDevices.isEmpty {
                    Section(header: Text("Reachable via Mesh")) {
                        ForEach(multiHopDevices, id: \.deviceID) { device in
                            PeerDestinationRow(
                                name: device.deviceName,
                                deviceID: device.deviceID,
                                hopCount: device.hopCount,
                                rssi: nil,
                                isSelected: viewModel.selectedDestination == device.deviceID
                            ) {
                                viewModel.selectDestination(device.deviceID)
                                dismiss()
                            }
                        }
                    }
                }
                
                // Hint if no devices
                if viewModel.peers.isEmpty && viewModel.knownDevices.isEmpty {
                    Section {
                        VStack(alignment: .center, spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No devices found")
                                .font(.headline)
                            Text("Make sure other devices are running the app and nearby")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                }
            }
            .navigationTitle("Send To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Peer Destination Row

struct PeerDestinationRow: View {
    let name: String
    let deviceID: UUID
    let hopCount: Int
    let rssi: Int?
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                // Icon with hop indicator
                ZStack {
                    Image(systemName: hopCount > 0 ? "point.3.connected.trianglepath.dotted" : "iphone")
                        .foregroundColor(hopCount > 0 ? .purple : .blue)
                        .frame(width: 30)
                }
                
                // Device info
                VStack(alignment: .leading) {
                    Text(name)
                        .font(.body)
                    
                    HStack(spacing: 4) {
                        Text(deviceID.uuidString.prefix(8))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if hopCount > 0 {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text("\(hopCount) hop\(hopCount > 1 ? "s" : "")")
                                .font(.caption2)
                                .foregroundColor(.purple)
                        }
                        
                        if let rssi = rssi {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text("\(rssi) dBm")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: MeshMessage
    
    var body: some View {
        VStack(alignment: message.isFromLocalDevice ? .trailing : .leading, spacing: 4) {
            // Sender info
            HStack(spacing: 4) {
                Text(message.senderName)
                    .font(.caption2)
                    .fontWeight(.medium)
                
                if message.ttl < 3 {
                    Text("•")
                        .foregroundColor(.secondary)
                    HStack(spacing: 2) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.caption2)
                        Text("\(3 - message.ttl) hops")
                    }
                    .font(.caption2)
                    .foregroundColor(.purple)
                }
            }
            
            // Message content
            Text(message.content)
                .padding(12)
                .foregroundColor(message.isFromLocalDevice ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Corner.medium, style: .continuous)
                        .fill(message.isFromLocalDevice ? Theme.Color.accent : Theme.Color.card)
                )
                .shadow(color: Color.black.opacity(0.02), radius: 2, x: 0, y: 1)
            
            // Timestamp
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: message.isFromLocalDevice ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.senderName) sent: \(message.content)")
        .accessibilityHint(message.isFromLocalDevice ? "Your message" : "Received message")
    }
}

// MARK: - Message Input

struct MessageInputView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            TextField("Message...", text: $viewModel.messageText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            Button(action: viewModel.sendMessage) {
                Image(systemName: viewModel.isSending ? "hourglass" : "paperplane.fill")
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(canSend ? Theme.Color.accent : Color.gray)
                    .cornerRadius(22)
            }
            .disabled(!canSend || viewModel.isSending)
        }
        .padding()
        .background(Color(.systemGray6))
    }
    
    private var canSend: Bool {
        !viewModel.messageText.isEmpty && viewModel.connectedPeersCount > 0
    }
}

// MARK: - Network Tab

struct NetworkTabView: View {
    var body: some View {
        List {
            PeersSection()
            RoutingSection()
            ControlsSection()
        }
        .listStyle(InsetGroupedListStyle())
    }
}

// MARK: - Peers Section

struct PeersSection: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        Section(header: Text("Discovered Peers (\(viewModel.peers.count))")) {
            if viewModel.peers.isEmpty {
                Text("No peers found. Make sure other devices are running the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(viewModel.peers) { peer in
                    PeerRow(peer: peer)
                }
            }
        }
    }
}

// MARK: - Routing Section

struct RoutingSection: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        Section(header: Text("Mesh Network (\(viewModel.knownDevices.count) devices)")) {
            if viewModel.knownDevices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No mesh routes discovered yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Routes are discovered automatically when devices connect")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(viewModel.knownDevices, id: \.deviceID) { device in
                    HStack {
                        // Hop indicator
                        ZStack {
                            Circle()
                                .fill(device.isDirect ? Color.green : Color.purple)
                                .frame(width: 8, height: 8)
                            
                            if device.hopCount > 0 {
                                Circle()
                                    .stroke(Color.purple.opacity(0.5), lineWidth: 1)
                                    .frame(width: 16, height: 16)
                            }
                        }
                        .frame(width: 20)
                        
                        // Device info
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.deviceName)
                                .font(.body)
                            
                            HStack(spacing: 4) {
                                Text(device.deviceID.uuidString.prefix(8))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                
                                if device.hopCount > 0 {
                                    Text("• \(device.hopCount) hop\(device.hopCount > 1 ? "s" : "") away")
                                        .font(.caption2)
                                        .foregroundColor(.purple)
                                } else {
                                    Text("• Direct")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        
                        Spacer()
                        
                        // Quick message button
                        Button(action: {
                            viewModel.selectDestination(device.deviceID)
                        }) {
                            Image(systemName: "message")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            
            // Stats
            HStack {
                Label("\(viewModel.stats.routeCount) routes", systemImage: "arrow.triangle.swap")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if viewModel.stats.pendingRoutes > 0 {
                    Text("• \(viewModel.stats.pendingRoutes) pending")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }
}

// MARK: - Controls Section

struct ControlsSection: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        Section(header: Text("Controls")) {
            Button(action: viewModel.toggleScanning) {
                Label(
                    viewModel.isScanning ? "Stop Scanning" : "Start Scanning",
                    systemImage: viewModel.isScanning ? "stop.fill" : "magnifyingglass"
                )
            }
            
            Button(action: viewModel.toggleAdvertising) {
                Label(
                    viewModel.isAdvertising ? "Stop Advertising" : "Start Advertising",
                    systemImage: viewModel.isAdvertising ? "stop.fill" : "antenna.radiowaves.left.and.right"
                )
            }
            
            Button(action: viewModel.refreshPeers) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }
}

// MARK: - Peer Row

struct PeerRow: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject var peer: Peer
    
    var body: some View {
        HStack {
            // Connection state indicator
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.body)
                
                HStack {
                    Text("RSSI: \(peer.rssi) dBm")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(peer.state.rawValue)
                        .font(.caption)
                        .foregroundColor(stateColor)
                }
            }
            
            Spacer()
            
            // Action button
            Button(action: {
                if peer.state == .connected {
                    viewModel.disconnect(from: peer)
                } else if peer.state == .discovered || peer.state == .disconnected {
                    viewModel.connect(to: peer)
                }
            }) {
                Text(buttonText)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(buttonColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .disabled(peer.state == .connecting)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(peer.name), signal \(peer.rssi) dBm, \(peer.state.rawValue)")
        .accessibilityHint("Double tap to \(peer.state == .connected ? "disconnect" : "connect")")
    }
    
    private var stateColor: Color {
        switch peer.state {
        case .connected: return .green
        case .connecting: return .orange
        case .discovered: return .blue
        case .disconnected: return .gray
        case .failed: return .red
        }
    }
    
    private var buttonText: String {
        switch peer.state {
        case .connected: return "Disconnect"
        case .connecting: return "Connecting..."
        case .discovered, .disconnected: return "Connect"
        case .failed: return "Retry"
        }
    }
    
    private var buttonColor: Color {
        switch peer.state {
        case .connected: return .red
        case .connecting: return .gray
        default: return .blue
        }
    }
}

// MARK: - Debug View

struct DebugView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        List {
            Section(header: Text("Device Identity")) {
                DebugRow(label: "Device Name", value: viewModel.localDeviceName)
                DebugRow(label: "Device ID", value: viewModel.localDeviceID)
                DebugRow(label: "Bluetooth Status", value: viewModel.bluetoothStatus)
            }
            
            Section(header: Text("Messaging Stats")) {
                DebugRow(label: "Messages Sent", value: "\(viewModel.stats.messagesSent)")
                DebugRow(label: "Messages Received", value: "\(viewModel.stats.messagesReceived)")
                DebugRow(label: "Messages Relayed", value: "\(viewModel.stats.messagesRelayed)")
                DebugRow(label: "Duplicates Blocked", value: "\(viewModel.stats.duplicatesBlocked)")
            }
            
            Section(header: Text("Network Stats")) {
                DebugRow(label: "Peers Discovered", value: "\(viewModel.stats.peersDiscovered)")
                DebugRow(label: "Peers Connected", value: "\(viewModel.connectedPeersCount)")
                DebugRow(label: "Known Devices", value: "\(viewModel.knownDevices.count)")
                DebugRow(label: "Active Routes", value: "\(viewModel.stats.routeCount)")
                DebugRow(label: "Pending Discoveries", value: "\(viewModel.stats.pendingRoutes)")
            }
            
            Section(header: Text("Configuration")) {
                DebugRow(label: "Max TTL", value: "\(BLEConstants.maxTTL)")
                DebugRow(label: "Default MTU", value: "\(BLEConstants.defaultMTU)")
                DebugRow(label: "Cache Expiry", value: "\(Int(BLEConstants.messageCacheExpiry))s")
            }
            
            Section(header: Text("Current Mode")) {
                DebugRow(label: "Messaging Mode", value: viewModel.messagingMode)
                if let dest = viewModel.selectedDestination {
                    DebugRow(label: "Target Device", value: dest.uuidString.prefix(8).description)
                }
            }
            
            Section(header: Text("Actions")) {
                Button(action: viewModel.clearMessages) {
                    Label("Clear Messages", systemImage: "trash")
                        .foregroundColor(.red)
                }
            }
            
            if let error = viewModel.errorMessage {
                Section(header: Text("Last Error")) {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }
}

// MARK: - Debug Row

struct DebugRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Preview

#Preview {
    let btManager = BluetoothManager()
    let routing = RoutingService()
    routing.configure(bluetoothManager: btManager)
    let relay = MessageRelayService(bluetoothManager: btManager, routingService: routing)
    let viewModel = ChatViewModel(
        bluetoothManager: btManager,
        routingService: routing,
        messageRelayService: relay
    )
    
    return ContentView()
        .environmentObject(btManager)
        .environmentObject(routing)
        .environmentObject(relay)
        .environmentObject(viewModel)
}
