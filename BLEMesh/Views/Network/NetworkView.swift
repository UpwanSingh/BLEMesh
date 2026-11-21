import SwiftUI
import MeshCore

struct NetworkView: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        NavigationStack {
            List {
                Section("This phone") {
                    LabeledContent("Name", value: mesh.nickname)
                    LabeledContent("Mesh ID", value: mesh.myPeerID.short)
                    LabeledContent("Radio", value: mesh.radioStatus)
                    LabeledContent("Links", value: "\(mesh.linkCount)")
                        .accessibilityIdentifier("network.links")
                    LabeledContent("AI", value: mesh.ai.hasGenerativeModel ? "On-device model" : "Offline guide")
                }

                Section {
                    if mesh.peers.isEmpty {
                        Text("No devices yet. Phones running BLE Mesh connect automatically when in range.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(mesh.peers) { peer in
                        HStack {
                            Circle().fill(peer.isNeighbor ? Color.green : (peer.isReachable ? Color.purple : Color.gray)).frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(peer.nickname)
                                Text(peer.peerID.short).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if peer.capabilities.contains(.onDeviceAI) {
                                Image(systemName: "sparkles").foregroundStyle(.orange)
                            }
                            Text(peer.hops.map { $0 == 0 ? "direct" : "\($0 + 1) hops" } ?? "offline")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("network.peer.\(peer.nickname)")
                    }
                } header: {
                    Text("Mesh (\(mesh.peers.filter(\.isReachable).count) reachable)")
                }

                Section("Traffic") {
                    LabeledContent("Packets received", value: "\(mesh.stats.packetsReceived)")
                    LabeledContent("Packets sent", value: "\(mesh.stats.packetsSent)")
                    LabeledContent("Relayed for others", value: "\(mesh.stats.relayed)")
                    LabeledContent("Carried (store & forward)", value: "\(mesh.stats.carried)")
                    LabeledContent("Duplicates suppressed", value: "\(mesh.stats.duplicatesDropped)")
                    LabeledContent("Invalid / forged dropped", value: "\(mesh.stats.invalidDropped)")
                    LabeledContent("Rate-limited", value: "\(mesh.stats.rateLimited)")
                }
            }
            .navigationTitle("Network")
            .refreshable { mesh.refreshPeers() }
        }
    }
}
