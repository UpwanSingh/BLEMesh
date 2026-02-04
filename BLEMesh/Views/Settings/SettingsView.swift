import SwiftUI

/// Settings view for app configuration (Plaintext Version)
struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
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
        messageRetention = 7
        showDeliveryStatus = true
        enableNotifications = true
        autoReconnect = true
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
                        Text(peer.displayName) // Changed peer.name to peer.displayName
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
                            Text("•")
                            Text(viewModel.formattedRouteQuality(to: entry.id))
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
                    • Nicknames and Route Quality metrics
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
