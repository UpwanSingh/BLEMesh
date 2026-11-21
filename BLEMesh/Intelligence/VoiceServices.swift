import Foundation
import AVFoundation
import Speech

/// Records speech and transcribes it entirely on-device, so a voice note crosses the mesh as a
/// few hundred bytes of text instead of audio (Bluetooth can't carry audio efficiently).
@MainActor
final class VoiceRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript: String = ""
    @Published private(set) var level: Float = 0

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var startedAt: Date?
    private(set) var locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    var languageCode: String { locale.identifier(.bcp47) }

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func setLocale(_ locale: Locale) { self.locale = locale }

    func start() async {
        guard state != .recording else { return }
        guard await Self.requestPermissions() else {
            state = .unavailable("Microphone or speech permission denied")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            state = .unavailable("Speech recognition isn't available for \(locale.identifier)")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            state = .unavailable("Offline speech isn't supported for \(locale.identifier) on this phone")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            self.request = request
            transcript = ""

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let level = Self.rms(buffer)
                Task { @MainActor in self?.level = level }
            }
            audioEngine.prepare()
            try audioEngine.start()
            startedAt = Date()
            state = .recording

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = error != nil || (result?.isFinal ?? false)
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if finished { self.finishAudio() }
                }
            }
        } catch {
            state = .unavailable("Couldn't start recording: \(error.localizedDescription)")
            finishAudio()
        }
    }

    /// Stop and return (transcript, duration).
    func stop() -> (String, Double) {
        request?.endAudio()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        finishAudio()
        return (transcript.trimmingCharacters(in: .whitespacesAndNewlines), duration)
    }

    func cancel() {
        task?.cancel()
        finishAudio()
        transcript = ""
    }

    private func finishAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        task = nil
        request = nil
        startedAt = nil
        level = 0
        if state == .recording { state = .idle }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
    }
}

/// Re-speaks voice notes (and any message) with the on-device voice for its language.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speakingID: UUID?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, languageCode: String?, id: UUID) {
        if speakingID == id {
            stop()
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = languageCode.flatMap(AVSpeechSynthesisVoice.init(language:)) ?? AVSpeechSynthesisVoice(language: nil)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingID = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil }
    }
}
