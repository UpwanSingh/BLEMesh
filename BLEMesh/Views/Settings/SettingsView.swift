import SwiftUI

/// Settings view for app configuration
struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @AppStorage("defaultEncryption") private var defaultEncryption = true
    @AppStorage("messageRetention") private var messageRetention = 7 // days
    @AppStorage("showDeliveryStatus") private var showDeliveryStatus = true
    @AppStorage("enableNotifications") private var enableNotifications = true
    @AppStorage("autoReconnect") private var autoReconnect = true
    
    @State private var showingClearConfirmation = false
    @State private var showingResetConfirmation = false
    @State private var showOnboarding = false
    
    var body: some View {
        NavigationView {
            List {
                // Device Info
                Section("Device") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(viewModel.localDeviceName)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("ID")
                        Spacer()
                        Text(viewModel.localDeviceID)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Encryption
                Section("Security") {
                    Toggle("Encrypt Messages by Default", isOn: $defaultEncryption)
                        .onChange(of: defaultEncryption) { oldValue, newValue in
                            viewModel.encryptionEnabled = newValue
                        }
                    
                    NavigationLink {
                        EncryptionDetailsView(viewModel: viewModel)
                    } label: {
                        HStack {
                            Text("Encryption Details")
                            Spacer()
                            Image(systemName: "lock.shield")
                                .foregroundColor(.green)
                        }
                    }
                }
                
                // Network
                Section("Network") {
                    Toggle("Auto Reconnect", isOn: $autoReconnect)
                    
                    HStack {
                        Text("Connected Peers")
                        Spacer()
                        Text("\(viewModel.connectedPeersCount)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Known Routes")
                        Spacer()
                        Text("\(viewModel.routes.count)")
                            .foregroundColor(.secondary)
                    }
                    
                    NavigationLink {
                        NetworkDiagnosticsView(viewModel: viewModel)
                    } label: {
                        Text("Network Diagnostics")
                    }
                }
                
                // Messages
                Section("Messages") {
                    Toggle("Show Delivery Status", isOn: $showDeliveryStatus)
                    
                    Picker("Message Retention", selection: $messageRetention) {
                        Text("1 Day").tag(1)
                        Text("7 Days").tag(7)
                        Text("30 Days").tag(30)
                        Text("Forever").tag(0)
                    }
                    
                    HStack {
                        Text("Stored Messages")
                        Spacer()
                        Text("\(viewModel.messages.count)")
                            .foregroundColor(.secondary)
                    }
                    
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Text("Clear Message History")
                    }
                }
                
                // Notifications
                Section("Notifications") {
                    Toggle("Enable Notifications", isOn: $enableNotifications)
                }
                
                // Stats
                Section("Statistics") {
                    HStack {
                        Text("Messages Sent")
                        Spacer()
                        Text("\(viewModel.stats.messagesSent)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Messages Received")
                        Spacer()
                        Text("\(viewModel.stats.messagesReceived)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Encrypted Messages")
                        Spacer()
                        Text("\(viewModel.stats.encryptedMessages)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Messages Relayed")
                        Spacer()
                        Text("\(viewModel.stats.messagesRelayed)")
                            .foregroundColor(.secondary)
                    }
                }
                
                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    NavigationLink {
                        AboutView()
                    } label: {
                        Text("About BLE Mesh")
                    }
                    
                    Button {
                        showOnboarding = true
                    } label: {
                        HStack {
                            Text("View Onboarding")
                            Spacer()
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                        }
                    }
                }
                
                // Debug
                Section("Debug") {
                    Button(role: .destructive) {
                        showingResetConfirmation = true
                    } label: {
                        Text("Reset All Settings")
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showOnboarding) {
                OnboardingReplayView()
            }
            .confirmationDialog("Clear Messages", isPresented: $showingClearConfirmation) {
                Button("Clear All Messages", role: .destructive) {
                    viewModel.clearMessages()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all message history. This action cannot be undone.")
            }
            .confirmationDialog("Reset Settings", isPresented: $showingResetConfirmation) {
                Button("Reset All", role: .destructive) {
                    resetAllSettings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will reset all settings to their defaults.")
            }
        }
    }
    
    private func resetAllSettings() {
        defaultEncryption = true
        messageRetention = 7
        showDeliveryStatus = true
        enableNotifications = true
        autoReconnect = true
    }
}

// MARK: - Encryption Details View

struct EncryptionDetailsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var showingPeerKeys = false
    
    var body: some View {
        List {
            Section("Encryption Protocol") {
                InfoRow(title: "Key Exchange", value: "ECDH P-256")
                InfoRow(title: "Encryption", value: "AES-256-GCM")
                InfoRow(title: "Key Derivation", value: "HKDF-SHA256")
                InfoRow(title: "Signatures", value: "ECDSA P-256")
                InfoRow(title: "Replay Protection", value: "Sequence Numbers")
            }
            
            Section("How It Works") {
                Text("""
                BLE Mesh uses end-to-end encryption for direct messages:
                
                1. Each device generates a P-256 key pair on first launch
                2. Public keys are exchanged during peer discovery via BLE
                3. A shared secret is derived using ECDH
                4. Messages are encrypted with AES-256-GCM
                5. All messages are signed with ECDSA
                6. Sequence numbers prevent replay attacks
                7. Only the intended recipient can decrypt
                """)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            
            Section("Your Public Key Fingerprint") {
                let fingerprint = DeviceIdentity.shared.publicKeyFingerprint
                HStack {
                    Text(formatFingerprint(fingerprint))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button {
                        UIPasteboard.general.string = fingerprint
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.blue)
                    }
                }
                
                Text("Share this fingerprint to verify your identity with peers")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Section("Your Signing Key Fingerprint") {
                let signingFingerprint = DeviceIdentity.shared.signingKeyFingerprint
                HStack {
                    Text(formatFingerprint(signingFingerprint))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button {
                        UIPasteboard.general.string = signingFingerprint
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.blue)
                    }
                }
                
                Text("This key signs your messages to prove authenticity")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Section("Peer Key Verification") {
                NavigationLink {
                    PeerKeyVerificationView(viewModel: viewModel)
                } label: {
                    HStack {
                        Image(systemName: "person.badge.key")
                            .foregroundColor(.blue)
                        Text("Verify Peer Keys")
                    }
                }
                
                Text("Compare fingerprints with peers to ensure secure communication")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Encryption")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func formatFingerprint(_ fingerprint: String) -> String {
        // Format fingerprint for readability: XXXX XXXX XXXX XXXX
        var result = ""
        for (index, char) in fingerprint.enumerated() {
            if index > 0 && index % 4 == 0 {
                result += " "
            }
            result += String(char)
        }
        return result
    }
}

// MARK: - Peer Key Verification View

struct PeerKeyVerificationView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var selectedPeer: Peer?
    
    private var connectedPeers: [Peer] {
        viewModel.peers.filter { $0.isConnected }
    }
    
    var body: some View {
        List {
            instructionsSection
            peersSection
            if let peer = selectedPeer {
                peerDetailsSection(peer)
            }
        }
        .navigationTitle("Peer Verification")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var instructionsSection: some View {
        Section {
            Text("Compare these fingerprints with your peers out-of-band (in person or via a trusted channel) to verify you're communicating securely.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var peersSection: some View {
        Section("Connected Peers") {
            if connectedPeers.isEmpty {
                Text("No connected peers")
                    .foregroundColor(.secondary)
            } else {
                ForEach(connectedPeers) { peer in
                    PeerKeyRow(peer: peer, isSelected: selectedPeer?.id == peer.id)
                        .onTapGesture {
                            selectedPeer = peer
                        }
                }
            }
        }
    }
    
    @ViewBuilder
    private func peerDetailsSection(_ peer: Peer) -> some View {
        Section("Peer Details: \(peer.name)") {
            peerIDRow(peer)
            publicKeyRow(peer)
            signingKeyRow(peer)
            verificationStatusRow(peer)
        }
    }
    
    private func peerIDRow(_ peer: Peer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Device ID")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(peer.id.uuidString)
                .font(.system(.caption2, design: .monospaced))
        }
    }
    
    @ViewBuilder
    private func publicKeyRow(_ peer: Peer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Public Key Fingerprint")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if let fingerprint = EncryptionService.shared.getPeerPublicKeyFingerprint(for: peer.id) {
                HStack {
                    Text(formatFingerprint(fingerprint))
                        .font(.system(.caption2, design: .monospaced))
                    Spacer()
                    Image(systemName: peer.hasExchangedKeys ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .foregroundColor(peer.hasExchangedKeys ? .green : .orange)
                }
            } else {
                Text("Key not yet exchanged")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }
    
    @ViewBuilder
    private func signingKeyRow(_ peer: Peer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Signing Key Fingerprint")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if let fingerprint = EncryptionService.shared.getPeerSigningKeyFingerprint(for: peer.id) {
                HStack {
                    Text(formatFingerprint(fingerprint))
                        .font(.system(.caption2, design: .monospaced))
                    Spacer()
                    Image(systemName: peer.hasExchangedSigningKeys ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .foregroundColor(peer.hasExchangedSigningKeys ? .green : .orange)
                }
            } else {
                Text("Signing key not yet exchanged")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }
    
    private func verificationStatusRow(_ peer: Peer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Verification Status")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                let keysExchanged = peer.hasExchangedKeys && peer.hasExchangedSigningKeys
                Image(systemName: keysExchanged ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(keysExchanged ? .green : .orange)
                Text(keysExchanged ? "Keys Exchanged" : "Pending Key Exchange")
                    .font(.caption2)
                    .foregroundColor(keysExchanged ? .green : .orange)
            }
        }
    }
    
    private func formatFingerprint(_ fingerprint: String) -> String {
        var result = ""
        for (index, char) in fingerprint.enumerated() {
            if index > 0 && index % 4 == 0 {
                result += " "
            }
            result += String(char)
        }
        return result
    }
}

// MARK: - Peer Key Row

struct PeerKeyRow: View {
    let peer: Peer
    let isSelected: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.body)
                
                HStack(spacing: 4) {
                    Image(systemName: peer.hasExchangedKeys ? "key.fill" : "key")
                        .font(.caption2)
                        .foregroundColor(peer.hasExchangedKeys ? .green : .gray)
                    
                    Image(systemName: peer.hasExchangedSigningKeys ? "signature" : "pencil.slash")
                        .font(.caption2)
                        .foregroundColor(peer.hasExchangedSigningKeys ? .green : .gray)
                    
                    Text(peer.id.uuidString.prefix(8).description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Network Diagnostics View

struct NetworkDiagnosticsView: View {
    @ObservedObject var viewModel: ChatViewModel
    
    var body: some View {
        List {
            Section("Bluetooth") {
                InfoRow(title: "State", value: viewModel.isBluetoothReady ? "Ready" : "Not Ready")
                InfoRow(title: "Scanning", value: viewModel.isScanning ? "Yes" : "No")
                InfoRow(title: "Advertising", value: viewModel.isAdvertising ? "Yes" : "No")
            }
            
            Section("Connected Peers") {
                ForEach(viewModel.availablePeers) { peer in
                    HStack {
                        Circle()
                            .fill(peer.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(peer.name)
                        Spacer()
                        Text(peer.id.uuidString.prefix(8).description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if viewModel.availablePeers.isEmpty {
                    Text("No connected peers")
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Routing Table") {
                ForEach(viewModel.routes) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("→ \(entry.id.uuidString.prefix(8))")
                            .font(.caption.monospaced())
                        HStack {
                            Text("via \(entry.nextHopID.uuidString.prefix(8))")
                            Text("•")
                            Text("\(entry.hopCount) hop\(entry.hopCount > 1 ? "s" : "")")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                
                if viewModel.routes.isEmpty {
                    Text("No routes")
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Actions") {
                Button("Force Route Discovery") {
                    viewModel.forceRouteDiscovery()
                }
                
                Button("Clear Routing Table") {
                    viewModel.clearRoutingTable()
                }
                .foregroundColor(.red)
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                    .padding(.top, 40)
                
                Text("BLE Mesh")
                    .font(.largeTitle.bold())
                
                Text("Version 1.0.0")
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("About")
                        .font(.headline)
                    
                    Text("""
                    BLE Mesh is a decentralized messaging application that uses Bluetooth Low Energy to create ad-hoc mesh networks between nearby devices.
                    
                    Features:
                    • Multi-hop message routing
                    • End-to-end encryption
                    • Group messaging
                    • Offline message queueing
                    • No internet required
                    """)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                
                Spacer()
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helper Views

struct InfoRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView(viewModel: .preview)
}
