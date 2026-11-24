import SwiftUI
import MeshCore

struct NetworkView: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    InfoRow("Name", value: mesh.nickname)
                    InfoRow("Mesh ID", value: mesh.myPeerID.short)
                    InfoRow("Radio", value: mesh.radioStatus)
                    InfoRow("Links", value: "\(mesh.linkCount)")
                        .accessibilityIdentifier("network.links")
                    InfoRow("AI", value: mesh.ai.hasGenerativeModel ? "On-device model" : "Offline guide")
                } header: { SectionTitle("This phone") }

                Section {
                    if mesh.peers.isEmpty {
                        Text("No devices yet. Phones running BLE Mesh connect automatically when in range.")
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    ForEach(mesh.peers) { peer in
                        HStack {
                            Circle().fill(peer.isNeighbor ? Theme.Colors.success : (peer.isReachable ? Theme.Colors.multiHop : Theme.Colors.secondaryText))
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true) // the hop count says the same in words
                            VStack(alignment: .leading) {
                                HStack(spacing: 4) {
                                    Text(mesh.uniqueName(for: peer.peerID))
                                    if mesh.trust.isVerified(peer.peerID) {
                                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.Colors.success).font(.caption)
                                    }
                                    if peer.capabilities.contains(.lowPower) {
                                        Image(systemName: "battery.25").foregroundStyle(Theme.Colors.warning).font(.caption)
                                            .accessibilityLabel("Low battery")
                                    }
                                }
                                Text(peer.peerID.short).font(.caption2.monospaced()).foregroundStyle(Theme.Colors.secondaryText)
                            }
                            Spacer()
                            if peer.capabilities.contains(.onDeviceAI) {
                                Image(systemName: "sparkles").foregroundStyle(Theme.Colors.warning)
                                    .accessibilityLabel("Has on-device AI")
                            }
                            Text(peer.hops.map { $0 == 0 ? "direct" : "\($0 + 1) hops" } ?? "offline")
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }
                        .accessibilityIdentifier("network.peer.\(peer.nickname)")
                    }
                } header: {
                    Text("Mesh (\(mesh.peers.filter(\.isReachable).count) reachable)").foregroundStyle(Theme.Colors.secondaryText)
                }

                Section {
                    InfoRow("Packets received", value: "\(mesh.stats.packetsReceived)")
                    InfoRow("Packets sent", value: "\(mesh.stats.packetsSent)")
                    InfoRow("Relayed for others", value: "\(mesh.stats.relayed)")
                    LabeledContent("Carried (store & forward)", value: "\(mesh.stats.carried)")
                    InfoRow("Duplicates suppressed", value: "\(mesh.stats.duplicatesDropped)")
                    InfoRow("Invalid / forged dropped", value: "\(mesh.stats.invalidDropped)")
                    InfoRow("Rate-limited", value: "\(mesh.stats.rateLimited)")
                } header: { SectionTitle("Traffic") }
            }
            .navigationTitle("Network")
            .refreshable { mesh.refreshPeers() }
        }
    }
}
