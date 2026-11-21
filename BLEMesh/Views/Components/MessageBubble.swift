import SwiftUI
import UIKit
import NaturalLanguage
import MeshCore
#if canImport(Translation)
import Translation
#endif

struct MessageBubble: View {
    @EnvironmentObject private var mesh: MeshService
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var settings: AppSettings
    let message: StoredMessage
    var showSender: Bool

    @State private var showTranslation = false
    @State private var translated: String?
    @State private var translationFailed = false

    private var content: MeshContent? { message.content }

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer(minLength: 48) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                if showSender && !message.isOutgoing {
                    Text(message.senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                bubble
                footer
            }
            if !message.isOutgoing { Spacer(minLength: 48) }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message.\(message.previewText)")
        .modifier(TranslationModifier(text: bodyText, enabled: showTranslation, target: settings.preferredLanguage,
                                      translated: $translated, failed: $translationFailed))
        .onAppear {
            if settings.autoTranslate, !message.isOutgoing, needsTranslation { showTranslation = true }
            if settings.autoPlayVoice, !message.isOutgoing, case .voice(let note)? = content,
               Date().timeIntervalSince(message.receivedAt) < 10 {
                speaker.speak(note.transcript, languageCode: note.languageCode, id: message.id)
            }
        }
    }

    @ViewBuilder private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch content {
            case .voice(let note):
                HStack(spacing: 8) {
                    Button {
                        speaker.speak(note.transcript, languageCode: note.languageCode, id: message.id)
                    } label: {
                        Image(systemName: speaker.speakingID == message.id ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(speaker.speakingID == message.id ? "Stop" : "Play voice note")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice note · \(Int(note.durationSeconds.rounded()))s")
                            .font(.caption2).opacity(0.8)
                        Text(note.transcript)
                    }
                }
            case .sos(let report):
                SOSCardContent(report: report)
            default:
                Text(bodyText)
            }
            if showTranslation {
                Divider().opacity(0.4)
                if let translated {
                    Label(translated, systemImage: "character.bubble")
                        .font(.callout)
                } else if translationFailed {
                    Text("Translation unavailable for this language pair").font(.caption)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: Theme.Corner.large, style: .continuous)
                .fill(bubbleColor)
        )
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(message.sentAt, style: .time)
            if message.hops > 0 {
                Text("· \(message.hops + 1) hops")
            }
            if message.isOutgoing && message.conversationKey.hasPrefix("dm:") {
                StatusIcon(status: message.status)
                    .accessibilityIdentifier("status.\(message.status)")
            }
            if message.isOutgoing && message.status == .failed {
                Button("Retry") { mesh.retry(message.id) }
                    .font(.caption2.weight(.semibold))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var menu: some View {
        Button {
            UIPasteboard.general.string = bodyText
        } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button {
            speaker.speak(bodyText, languageCode: voiceLanguage, id: message.id)
        } label: { Label("Read aloud", systemImage: "speaker.wave.2") }
        if #available(iOS 18.0, *) {
            Button {
                showTranslation.toggle()
            } label: { Label(showTranslation ? "Hide translation" : "Translate", systemImage: "translate") }
        }
    }

    private var bodyText: String {
        switch content {
        case .text(let text): return text
        case .voice(let note): return note.transcript
        case .sos(let report): return report.text
        case .aiQuery(let query): return query.prompt
        case .aiResponse(let response): return response.text
        default: return message.previewText
        }
    }

    private var voiceLanguage: String? {
        if case .voice(let note)? = content { return note.languageCode }
        return NLLanguageRecognizer.dominantLanguage(for: bodyText)?.rawValue
    }

    private var needsTranslation: Bool {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: bodyText) else { return false }
        return language.rawValue != settings.preferredLanguage && bodyText.count > 3
    }

    private var bubbleColor: Color {
        if case .sos? = content { return message.isOutgoing ? .red : Color.red.opacity(0.12) }
        return message.isOutgoing ? Theme.Colors.accent : Theme.Colors.card
    }
}

/// On-device translation (Translation framework, iOS 18+). No-op on older systems.
struct TranslationModifier: ViewModifier {
    let text: String
    let enabled: Bool
    let target: String
    @Binding var translated: String?
    @Binding var failed: Bool

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            content.translationTask(enabled ? TranslationSession.Configuration(target: Locale.Language(identifier: target)) : nil) { session in
                do {
                    let response = try await session.translate(text)
                    await MainActor.run { translated = response.targetText }
                } catch {
                    await MainActor.run { failed = true }
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct StatusIcon: View {
    let status: DeliveryStatus

    var body: some View {
        switch status {
        case .queued: Image(systemName: "clock").accessibilityLabel("Queued")
        case .sent: Image(systemName: "checkmark").accessibilityLabel("Sent")
        case .delivered: Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue).accessibilityLabel("Delivered")
        case .read: Image(systemName: "eye.fill").foregroundStyle(.blue).accessibilityLabel("Read")
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        }
    }
}

struct SOSCardContent: View {
    let report: SOSReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sos.circle.fill")
                if let triage = report.triage {
                    PriorityBadge(priority: triage.priority)
                    Text(triage.category.label).font(.caption.weight(.semibold))
                }
            }
            Text(report.text)
            if let location = report.location {
                if let url = location.mapsURL {
                    Link(destination: url) {
                        Label(location.formatted, systemImage: "location.fill").font(.caption)
                    }
                }
            }
        }
    }
}

struct PriorityBadge: View {
    let priority: SOSTriage.Priority

    var body: some View {
        Text(priority.label.uppercased())
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
            .foregroundStyle(.white)
            .accessibilityIdentifier("priority.\(priority.label)")
    }

    private var color: Color {
        switch priority {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow.opacity(0.9)
        case .low: return .gray
        }
    }
}

struct PeerAvatar: View {
    let name: String
    var size: CGFloat = 36
    var tint: Color = .blue

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
