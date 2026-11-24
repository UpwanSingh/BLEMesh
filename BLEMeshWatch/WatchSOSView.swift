import SwiftUI

/// Hold the SOS button for 2 seconds (no accidental SOS from a bumped wrist), or tell your groups you're safe.
struct WatchSOSView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var holding = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(holdHint)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("watch.hint")

                ZStack {
                    Circle().fill(Color(red: 0.75, green: 0.15, blue: 0.18))
                    Circle()
                        .trim(from: 0, to: holding ? 1 : 0)
                        .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(4)
                        .animation(holding ? .linear(duration: 2) : .default, value: holding)
                    Text("SOS").font(.title.bold()).foregroundStyle(.white)
                }
                .frame(width: 110, height: 110)
                .contentShape(Circle())
                .onLongPressGesture(minimumDuration: 2, pressing: { holding = $0 }) {
                    holding = false
                    model.sendSOS()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Send SOS"))
                .accessibilityHint(Text("Hold for two seconds"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.sendSOS() } // VoiceOver: double-tap sends
                .accessibilityIdentifier("watch.sos")

                if let sosLine {
                    Text(sosLine).font(.footnote).multilineTextAlignment(.center)
                        .accessibilityIdentifier("watch.sosState")
                }

                Button {
                    model.sendSafe()
                } label: {
                    Label("I'm safe", systemImage: "checkmark.shield.fill")
                }
                .tint(Color(red: 0.12, green: 0.48, blue: 0.2))
                .accessibilityIdentifier("watch.safe")

                if let safeLine {
                    Text(safeLine).font(.footnote).multilineTextAlignment(.center)
                        .accessibilityIdentifier("watch.safeState")
                }

                if let peers = model.peers {
                    Text("\(peers) people in reach of your iPhone").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var holdHint: LocalizedStringKey {
        holding ? "Keep holding…" : "Hold SOS for 2 seconds"
    }

    private var sosLine: String? {
        switch model.sosDelivery {
        case .idle: return model.sosStatus.map { String(localized: "Your SOS: \($0)") }
        case .sending: return String(localized: "Sending…")
        case .sent:
            let status = model.sosStatus.map { " \($0)." } ?? ""
            return String(localized: "SOS sent by your iPhone.\(status)")
        case .queued: return String(localized: "iPhone not reachable. Your SOS will be sent as soon as it is.")
        case .noGroups, .failed: return String(localized: "Couldn't send. Use your iPhone.")
        }
    }

    private var safeLine: String? {
        switch model.safeDelivery {
        case .idle: return nil
        case .sending: return String(localized: "Sending…")
        case .sent: return String(localized: "Sent to your groups.")
        case .queued: return String(localized: "Will be sent when your iPhone is reachable.")
        case .noGroups: return String(localized: "You're not in any group yet.")
        case .failed: return String(localized: "Couldn't send.")
        }
    }
}
