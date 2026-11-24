import SwiftUI
import VisionKit
import MeshCore

/// Admin: show a QR invite code for the group. Whoever scans it asks this phone to add them.
struct GroupInviteCodeView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    let groupKey: String
    @State private var code: GroupJoinCode?
    @State private var demoScanned = false

    var body: some View {
        NavigationStack {
            List {
                if let code {
                    Section {
                        if let image = QRCode.image(for: code.string) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(Text("Invite code for \(code.groupName)"))
                        }
                        Text(code.string)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("invite.code")
                        Text("Valid until \(code.expires.formatted(date: .omitted, time: .shortened)).")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    } header: {
                        SectionTitle("Scan to join “\(code.groupName)”")
                    } footer: {
                        Text("The code has no key in it. Whoever scans it asks your phone over the mesh, and you add them automatically. Share it only in person. The group gets a new key when someone joins.")
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    Section {
                        Button("Make a new code (the old one stops working)") { self.code = mesh.makeJoinCode(groupKey: groupKey) }
                            .accessibilityIdentifier("invite.regenerate")
                        if mesh.mode == .demo {
                            Button(demoScanned ? "Meera scanned it" : "Let Meera scan it (demo)") {
                                mesh.demoScan(code, by: "Meera")
                                demoScanned = true
                            }
                            .disabled(demoScanned)
                            .accessibilityIdentifier("invite.demoScan")
                        }
                    }
                } else {
                    Text("Only the group admin can invite with a code.")
                }
            }
            .navigationTitle("Invite with QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if code == nil { code = mesh.makeJoinCode(groupKey: groupKey) } }
        }
    }
}

/// Join a group by scanning (or pasting) its invite code.
struct JoinGroupView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scanning = false
    @State private var result: MeshService.JoinResult?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button { scanning = true } label: { Label("Scan the invite QR code", systemImage: "qrcode.viewfinder") }
                    }
                    TextField("…or paste the invite code", text: $text, axis: .vertical)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("join.code")
                    Button("Join") { result = mesh.joinGroup(code: text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("join.submit")
                } footer: {
                    Text("Your phone asks the group's admin over the mesh. You'll join as soon as their phone accepts, even if they're out of range right now.")
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                if let result {
                    Section {
                        switch result {
                        case .requested(let admin):
                            Label("Request sent to \(admin). The group will appear in Chats when you're added.", systemImage: "paperplane.fill")
                                .foregroundStyle(Theme.Colors.success)
                                .accessibilityIdentifier("join.requested")
                        case .invalid:
                            Label("That isn't a BLE Mesh invite code.", systemImage: "questionmark.circle")
                                .foregroundStyle(Theme.Colors.warning)
                                .accessibilityIdentifier("join.invalid")
                        case .expired:
                            Label("This invite code has expired. Ask for a new one.", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(Theme.Colors.warning)
                                .accessibilityIdentifier("join.expired")
                        case .alreadyMember:
                            Label("You're already in this group.", systemImage: "checkmark.circle")
                                .accessibilityIdentifier("join.already")
                        }
                    }
                }
            }
            .navigationTitle("Join a group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScannerView { code in
                    scanning = false
                    text = code
                    result = mesh.joinGroup(code: code)
                }
                .ignoresSafeArea()
            }
        }
    }
}
