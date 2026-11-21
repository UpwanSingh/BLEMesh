import SwiftUI
import MeshCore

struct SettingsView: View {
    @EnvironmentObject private var mesh: MeshService
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmWipe = false
    @State private var confirmReset = false
    @State private var showOnboarding = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Your name", text: $name)
                        .onSubmit { mesh.rename(to: name) }
                        .accessibilityIdentifier("settings.name")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your safety number").font(.caption).foregroundStyle(.secondary)
                        Text(mesh.myFingerprint).font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("settings.safetyNumber")
                    }
                }

                Section {
                    Toggle("Answer questions for people nearby", isOn: $settings.helpOthersWithAI)
                        .disabled(!mesh.ai.hasGenerativeModel)
                        .onChange(of: settings.helpOthersWithAI) { _, _ in mesh.applySettingsChange() }
                    Picker("My language", selection: $settings.preferredLanguage) {
                        ForEach(AppSettings.supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    Toggle("Auto-translate incoming messages", isOn: $settings.autoTranslate)
                    Toggle("Read voice notes aloud on arrival", isOn: $settings.autoPlayVoice)
                } header: {
                    Text("On-device AI")
                } footer: {
                    Text(mesh.ai.statusDescription + ". Voice, translation, triage and answers never leave your phone.")
                }

                Section("Notifications") {
                    Toggle("Message & SOS alerts", isOn: $settings.notificationsEnabled)
                        .onChange(of: settings.notificationsEnabled) { _, enabled in
                            if enabled { MeshService.requestNotificationPermission() }
                        }
                }

                Section {
                    Picker("Keep messages", selection: $settings.retentionDays) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("Forever").tag(0)
                    }
                    .onChange(of: settings.retentionDays) { _, _ in mesh.purgeExpiredMessages() }
                } header: {
                    Text("Storage")
                }

                if mesh.mode == .demo {
                    Section {
                        Button("Walk out of range") { mesh.setDemoLinks(enabled: false) }
                            .accessibilityIdentifier("demo.leave")
                        Button("Walk back into range") { mesh.setDemoLinks(enabled: true) }
                            .accessibilityIdentifier("demo.return")
                    } header: {
                        Text("Demo mesh")
                    } footer: {
                        Text("Simulated devices: Asha, Kabir (nearby), Ravi (2 hops, has on-device AI), Meera (3 hops).")
                    }
                }

                Section {
                    Button("Replay introduction") { showOnboarding = true }
                    Button("Reset settings") { confirmReset = true }
                    Button("Erase everything (panic wipe)", role: .destructive) { confirmWipe = true }
                        .accessibilityIdentifier("settings.panicWipe")
                } footer: {
                    Text("Panic wipe deletes all messages, groups, contacts and your keys immediately, and gives this phone a new identity.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    LabeledContent("Protocol", value: "BLEMesh v\(Packet.currentVersion)")
                    LabeledContent("Encryption", value: "X25519 · ChaCha20-Poly1305 · Ed25519")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        mesh.rename(to: name)
                        dismiss()
                    }
                    .accessibilityIdentifier("settings.done")
                }
            }
            .onAppear { name = mesh.nickname }
            .sheet(isPresented: $showOnboarding) { OnboardingReplayView() }
            .confirmationDialog("Erase everything?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Erase now", role: .destructive) {
                    mesh.panicWipe()
                    dismiss()
                }
                .accessibilityIdentifier("settings.confirmWipe")
            } message: {
                Text("This can't be undone.")
            }
            .confirmationDialog("Reset all settings to defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    settings.resetToDefaults()
                    mesh.applySettingsChange()
                }
            }
        }
    }
}
