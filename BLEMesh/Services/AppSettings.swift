import Foundation

/// User preferences (all wired to behaviour — nothing decorative).
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var helpOthersWithAI: Bool { didSet { defaults.set(helpOthersWithAI, forKey: Keys.helpAI) } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) } }
    /// Messages older than this are deleted automatically (0 = keep forever).
    @Published var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: Keys.retention) } }
    /// Show incoming messages translated into `translationTarget` automatically.
    @Published var autoTranslate: Bool { didSet { defaults.set(autoTranslate, forKey: Keys.autoTranslate) } }
    /// BCP-47 language for translations and speech input, e.g. "en", "hi".
    @Published var preferredLanguage: String { didSet { defaults.set(preferredLanguage, forKey: Keys.language) } }
    /// Speak incoming voice notes automatically.
    @Published var autoPlayVoice: Bool { didSet { defaults.set(autoPlayVoice, forKey: Keys.autoPlay) } }
    /// Declared responder roles (advertised so people with emergencies can find you).
    @Published var isMedic: Bool { didSet { defaults.set(isMedic, forKey: Keys.medic) } }
    @Published var isRescuer: Bool { didSet { defaults.set(isRescuer, forKey: Keys.rescuer) } }
    /// Auto-reply (facts only) to "are you safe?" when you haven't answered in 5 minutes.
    @Published var autoReplySafetyChecks: Bool { didSet { defaults.set(autoReplySafetyChecks, forKey: Keys.autoReply) } }

    private enum Keys {
        static let helpAI = "settings.helpOthersWithAI"
        static let notifications = "settings.notifications"
        static let retention = "settings.retentionDays"
        static let autoTranslate = "settings.autoTranslate"
        static let language = "settings.language"
        static let autoPlay = "settings.autoPlayVoice"
        static let medic = "settings.isMedic"
        static let rescuer = "settings.isRescuer"
        static let autoReply = "settings.autoReplySafetyChecks"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.helpAI: true,
            Keys.notifications: true,
            Keys.retention: 30,
            Keys.autoTranslate: false,
            Keys.language: Locale.current.language.languageCode?.identifier ?? "en",
            Keys.autoPlay: false,
            Keys.medic: false,
            Keys.rescuer: false,
            Keys.autoReply: true,
        ])
        helpOthersWithAI = defaults.bool(forKey: Keys.helpAI)
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)
        retentionDays = defaults.integer(forKey: Keys.retention)
        autoTranslate = defaults.bool(forKey: Keys.autoTranslate)
        preferredLanguage = defaults.string(forKey: Keys.language) ?? "en"
        autoPlayVoice = defaults.bool(forKey: Keys.autoPlay)
        isMedic = defaults.bool(forKey: Keys.medic)
        isRescuer = defaults.bool(forKey: Keys.rescuer)
        autoReplySafetyChecks = defaults.bool(forKey: Keys.autoReply)
    }

    func resetToDefaults() {
        helpOthersWithAI = true
        notificationsEnabled = true
        retentionDays = 30
        autoTranslate = false
        preferredLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        autoPlayVoice = false
        isMedic = false
        isRescuer = false
        autoReplySafetyChecks = true
    }

    static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("hi", "हिन्दी (Hindi)"), ("es", "Español"), ("ar", "العربية"),
        ("fr", "Français"), ("de", "Deutsch"), ("pt", "Português"), ("zh", "中文"),
        ("ja", "日本語"), ("ko", "한국어"), ("ru", "Русский"), ("tr", "Türkçe"),
        ("uk", "Українська"), ("id", "Bahasa Indonesia"), ("vi", "Tiếng Việt"), ("it", "Italiano"),
    ]
}
