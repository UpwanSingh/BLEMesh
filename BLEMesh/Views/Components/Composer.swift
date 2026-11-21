import SwiftUI
import MeshCore

/// Text + voice composer. Hold the mic to record; the transcript (not audio) is what gets sent.
struct Composer: View {
    @EnvironmentObject private var mesh: MeshService
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var recorder = VoiceRecorder()
    let conversationKey: String
    var placeholder = "Message"
    var allowVoice = true

    @State private var text = ""
    @State private var holding = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            if recorder.state == .recording {
                HStack {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: true)
                        .foregroundStyle(.red)
                    Text(recorder.transcript.isEmpty ? "Listening… release to send" : recorder.transcript)
                        .font(.callout)
                        .lineLimit(3)
                    Spacer()
                }
                .padding(.horizontal)
                .accessibilityIdentifier("composer.liveTranscript")
            }
            if case .unavailable(let reason) = recorder.state {
                Text(reason).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            HStack(spacing: 10) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityIdentifier("composer.text")

                if text.isEmpty && allowVoice {
                    micButton
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("composer.send")
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var micButton: some View {
        Image(systemName: recorder.state == .recording ? "mic.circle.fill" : "mic.circle")
            .font(.system(size: 30))
            .foregroundStyle(recorder.state == .recording ? Color.red : Color.accentColor)
            .accessibilityLabel("Hold to record a voice note")
            .accessibilityIdentifier("composer.mic")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding else { return }
                        holding = true
                        recorder.setLocale(Locale(identifier: settings.preferredLanguage))
                        Task {
                            await recorder.start()
                            // Released while permissions/audio were still starting up.
                            if !holding { finishVoiceNote() }
                        }
                    }
                    .onEnded { _ in
                        holding = false
                        finishVoiceNote()
                    }
            )
    }

    private func finishVoiceNote() {
        guard recorder.state == .recording else { return }
        let (transcript, duration) = recorder.stop()
        guard !transcript.isEmpty else { return }
        mesh.send(.voice(VoiceNote(transcript: transcript, languageCode: recorder.languageCode,
                                   durationSeconds: duration)), to: conversationKey)
    }

    private func send() {
        let value = text
        text = ""
        mesh.sendText(value, to: conversationKey)
    }
}
