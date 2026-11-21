import SwiftUI
import SwiftData
import MeshCore

struct MainTabView: View {
    @EnvironmentObject private var mesh: MeshService
    @Query(filter: #Predicate<StoredConversation> { $0.kindRaw == 1 || $0.kindRaw == 2 })
    private var chats: [StoredConversation]

    private var unreadChats: Int { chats.reduce(0) { $0 + $1.unreadCount } }

    var body: some View {
        TabView {
            ChatsListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(unreadChats)
                .accessibilityIdentifier("tab.chats")

            NearbyView()
                .tabItem { Label("Nearby", systemImage: "dot.radiowaves.left.and.right") }
                .accessibilityIdentifier("tab.nearby")

            SOSView()
                .tabItem { Label("SOS", systemImage: "sos") }
                .accessibilityIdentifier("tab.sos")

            AskMeshView()
                .tabItem { Label("Ask", systemImage: "sparkles") }
                .accessibilityIdentifier("tab.ask")

            NetworkView()
                .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
                .accessibilityIdentifier("tab.network")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { mesh.lastError != nil },
            set: { if !$0 { mesh.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { mesh.lastError = nil }
        } message: {
            Text(mesh.lastError ?? "")
        }
    }
}

/// Compact radio/connection status shown at the top of screens.
struct RadioStatusBanner: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(mesh.radioStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("radio.status")
            Spacer()
            if mesh.linkCount > 0 {
                Label("\(mesh.peers.filter(\.isReachable).count) reachable", systemImage: "person.2.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var color: Color {
        if !mesh.isRadioReady { return .red }
        return mesh.linkCount > 0 ? .green : .orange
    }
}
