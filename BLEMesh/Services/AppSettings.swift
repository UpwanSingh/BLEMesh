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

    private enum Keys {
        static let helpAI = "settings.helpOthersWithAI"
        static let notifications = "settings.notifications"
        static let retention = "settings.retentionDays"
        static let autoTranslate = "settings.autoTranslate"
        static let language = "settings.language"
        static let autoPlay = "settings.autoPlayVoice"
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
        ])
        helpOthersWithAI = defaults.bool(forKey: Keys.helpAI)
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)
        retentionDays = defaults.integer(forKey: Keys.retention)
        autoTranslate = defaults.bool(forKey: Keys.autoTranslate)
        preferredLanguage = defaults.string(forKey: Keys.language) ?? "en"
        autoPlayVoice = defaults.bool(forKey: Keys.autoPlay)
    }

    func resetToDefaults() {
        helpOthersWithAI = true
        notificationsEnabled = true
        retentionDays = 30
        autoTranslate = false
        preferredLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        autoPlayVoice = false
    }

    static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("hi", "हिन्दी (Hindi)"), ("es", "Español"), ("ar", "العربية"),
        ("fr", "Français"), ("de", "Deutsch"), ("pt", "Português"), ("zh", "中文"),
        ("ja", "日本語"), ("ko", "한국어"), ("ru", "Русский"), ("tr", "Türkçe"),
        ("uk", "Українська"), ("id", "Bahasa Indonesia"), ("vi", "Tiếng Việt"), ("it", "Italiano"),
    ]
}
