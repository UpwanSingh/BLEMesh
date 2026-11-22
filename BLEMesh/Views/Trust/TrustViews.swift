import SwiftUI
import SwiftData
import CoreImage.CIFilterBuiltins
import VisionKit
import MeshCore

// MARK: - Family locator

/// Who in a group is safe: latest check-in per member, needs-help first, with location and battery.
struct FamilyLocatorView: View {
    @EnvironmentObject private var mesh: MeshService
    @Query private var groupMessages: [StoredMessage] // re-render when check-ins arrive
    let groupKey: String
    @State private var asked = false

    init(groupKey: String) {
        self.groupKey = groupKey
        _groupMessages = Query(filter: #Predicate<StoredMessage> { $0.conversationKey == groupKey })
    }

    var body: some View {
        List {
            Section {
                ForEach(mesh.familyEntries(groupKey: groupKey), id: \.member) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(entry))
                            .foregroundStyle(color(entry))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.member == mesh.myPeerID ? "\(mesh.nickname) (you)" : mesh.uniqueName(for: entry.member))
                                .font(.body.weight(.medium))
                            Text(statusText(entry)).font(.caption).foregroundStyle(Theme.Colors.secondaryText)
                            if let note = entry.checkIn?.note { Text("“\(note)”").font(.caption) }
                            HStack(spacing: 10) {
                                if let battery = entry.checkIn?.batteryPercent {
                                    Label("\(battery)%", systemImage: battery < 20 ? "battery.25" : "battery.75").font(.caption2)
                                }
                                if let location = entry.checkIn?.location, let url = location.mapsURL {
                                    Link(destination: url) { Label("Location", systemImage: "location.fill").font(.caption2) }
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("locator.\(entry.checkIn?.status == .needHelp ? "needHelp" : (entry.isStale ? "unknown" : "safe"))")
                }
            } footer: {
                Text("Shows each member's latest check-in. “Unknown” means no check-in in the last 6 hours.").foregroundStyle(Theme.Colors.secondaryText)
            }
            Section {
                Button {
                    asked = mesh.askAreYouSafe(groupKey: groupKey)
                } label: {
                    Label(asked ? "Asked everyone" : "Ask everyone: are you safe?", systemImage: "questionmark.bubble")
                }
                .accessibilityIdentifier("locator.ask")
            }
        }
        .navigationTitle(mesh.fetchConversation(groupKey)?.title ?? "Family")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func icon(_ e: FamilyLocator.Entry) -> String {
        if e.checkIn?.status == .needHelp { return "exclamationmark.triangle.fill" }
        return e.isStale ? "questionmark.circle" : "checkmark.shield.fill"
    }

    private func color(_ e: FamilyLocator.Entry) -> Color {
        if e.checkIn?.status == .needHelp { return .orange }
        return e.isStale ? .gray : .green
    }

    private func statusText(_ e: FamilyLocator.Entry) -> String {
        guard let checkIn = e.checkIn, let at = e.at else { return "No check-in yet" }
        let when = RelativeDateTimeFormatter().localizedString(for: at, relativeTo: Date())
        return (checkIn.status == .safe ? "Safe" : "Needs help") + " · " + when
    }
}

// MARK: - QR verification

struct VerifyContactView: View {
    @EnvironmentObject private var mesh: MeshService
    @EnvironmentObject private var trust: TrustStore
    @Environment(\.dismiss) private var dismiss
    let peer: PeerID
    @State private var manualCode = ""
    @State private var result: TrustStore.VerificationResult?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let image = qrImage(TrustStore.verificationCode(for: mesh.node.identity.publicIdentity)) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Your verification code")
                    }
                    Text(TrustStore.verificationCode(for: mesh.node.identity.publicIdentity))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("verify.myCode")
                } header: {
                    Text("Your code — let them scan it").foregroundStyle(Theme.Colors.secondaryText)
                }

                Section {
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button {
                            scanning = true
                        } label: {
                            Label("Scan their code", systemImage: "qrcode.viewfinder")
                        }
                    }
                    TextField("…or paste their code", text: $manualCode, axis: .vertical)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("verify.manualCode")
                    Button("Verify") { check(manualCode) }
                        .disabled(manualCode.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("verify.check")
                } header: {
                    Text("Their code").foregroundStyle(Theme.Colors.secondaryText)
                }

                if let result {
                    Section {
                        switch result {
                        case .verified:
                            Label("Verified — this really is \(mesh.uniqueName(for: peer))", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(Theme.Colors.success)
                                .accessibilityIdentifier("verify.success")
                        case .mismatch:
                            Label("That code belongs to a different device.", systemImage: "xmark.octagon.fill").foregroundStyle(Theme.Colors.danger)
                                .accessibilityIdentifier("verify.mismatch")
                        case .keyMismatch:
                            Label("Keys don't match — this may be an impostor. Don't trust this contact.", systemImage: "exclamationmark.shield.fill")
                                .foregroundStyle(Theme.Colors.danger)
                                .accessibilityIdentifier("verify.keyMismatch")
                        case .invalid:
                            Label("That isn't a BLE Mesh code.", systemImage: "questionmark.circle").foregroundStyle(Theme.Colors.warning)
                                .accessibilityIdentifier("verify.invalid")
                        case .unknownDevice:
                            Label("This phone hasn't met that device yet.", systemImage: "questionmark.circle").foregroundStyle(Theme.Colors.warning)
                        }
                    }
                }
                if trust.isVerified(peer) {
                    Section {
                        Button("Remove verification", role: .destructive) { trust.setVerified(peer, false) }
                    }
                }
            }
            .navigationTitle("Verify \(mesh.displayName(for: peer))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScannerView { code in
                    scanning = false
                    check(code)
                }
                .ignoresSafeArea()
            }
        }
    }

    private func check(_ code: String) {
        let outcome = TrustStore.check(code: code, expected: peer, known: mesh.peerInfo(peer))
        result = outcome
        if case .verified = outcome { trust.setVerified(peer, true) }
    }

    private func qrImage(_ string: String) -> UIImage? { QRCode.image(for: string) }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Live camera QR scanner (VisionKit). Only shown on devices that support it.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in items {
                if let value = code.payloadStringValue, value.hasPrefix("blemesh:") {
                    done = true
                    scanner.stopScanning()
                    onCode(value)
                    return
                }
            }
        }
    }
}

// MARK: - Medical ID

struct MedicalIDView: View {
    @EnvironmentObject private var trust: TrustStore
    @State private var draft = MedicalInfo()

    var body: some View {
        Form {
            Section {
                field("Blood type", "e.g. O+", \.bloodType, id: "medical.bloodType")
                field("Allergies", "e.g. penicillin, peanuts", \.allergies, id: "medical.allergies")
                field("Conditions", "e.g. asthma, diabetes", \.conditions, id: "medical.conditions")
                field("Medications", "e.g. insulin", \.medications, id: "medical.medications")
                field("Emergency contact", "Name and number", \.emergencyContact, id: "medical.contact")
            } footer: {
                Text("Stored only on this phone (Keychain). Attached to an SOS only when you choose — and then anyone nearby can read it.").foregroundStyle(Theme.Colors.secondaryText)
            }
            if !trust.medical.isEmpty {
                Section {
                    Button("Clear medical ID", role: .destructive) {
                        draft = MedicalInfo()
                        trust.medical = draft
                    }
                }
            }
        }
        .navigationTitle("Medical ID")
        .onAppear { draft = trust.medical }
        .onDisappear { trust.medical = draft }
    }

    private func field(_ title: String, _ prompt: String, _ keyPath: WritableKeyPath<MedicalInfo, String?>, id: String) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: Binding(
                get: { draft[keyPath: keyPath] ?? "" },
                set: {
                    draft[keyPath: keyPath] = $0.isEmpty ? nil : $0
                    trust.medical = draft
                }
            ))
            .multilineTextAlignment(.trailing)
            .accessibilityIdentifier(id)
        }
    }
}

// MARK: - Blocked devices

struct BlockedDevicesView: View {
    @EnvironmentObject private var mesh: MeshService
    @EnvironmentObject private var trust: TrustStore

    var body: some View {
        List {
            if trust.blocked.isEmpty {
                Text("You haven't blocked anyone.").foregroundStyle(Theme.Colors.secondaryText)
            }
            ForEach(Array(trust.blocked).sorted(), id: \.self) { peer in
                HStack {
                    VStack(alignment: .leading) {
                        Text(mesh.displayName(for: peer))
                        Text(trust.reported.contains(peer) ? "Reported" : "Blocked").font(.caption).foregroundStyle(Theme.Colors.secondaryText)
                    }
                    Spacer()
                    Button("Unblock") { trust.setBlocked(peer, false) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Blocked devices")
    }
}
