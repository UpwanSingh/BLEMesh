import Foundation
import MeshCore
import MeshSimulator

// A five-phone line (A — B — C — D — E) in the simulator: E is four hops from A.
// Run with: swift run mesh-demo   (from Packages/MeshCore)
let mesh = SimulatedMesh(seed: 7)
let names = ["A", "B", "C", "D", "E"]
for name in names { mesh.addNode(name) }
for (a, b) in zip(names, names.dropFirst()) { mesh.connect(a, b) }
mesh.run(for: 10)

let a = mesh.node("A"), e = mesh.node("E")
print("A can reach E in \((a.peer(e.peerID)?.hops ?? -1) + 1) hops")

let dm = try a.sendDirect(.text("Are you okay?"), to: e.peerID)
_ = mesh.run(until: { a.outgoingStatus(dm) == .delivered }, timeout: 20)
print("Direct message status: \(a.outgoingStatus(dm).map { "\($0)" } ?? "unknown")")

let sos = SOSReport(text: "Two people trapped under rubble near the school, one bleeding",
                    location: GeoPoint(latitude: 28.6139, longitude: 77.2090))
var triaged = sos
triaged.triage = HeuristicTriage.triage(sos.text)
try e.sendBroadcast(.sos(triaged))
mesh.run(for: 5)
let got = mesh.recorder("A").received.contains { if case .sos = $0.envelope.content { return true }; return false }
print("SOS from E reached A: \(got) — triaged \(triaged.triage!.priority.label) / \(triaged.triage!.category.label)")
let cReadIt = mesh.recorder("C").hasReceived(dm)
print("C (relay in the middle) relayed \(mesh.node("C").stats.relayed) packets; received the DM's content: \(cReadIt)")
