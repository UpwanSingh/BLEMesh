import Foundation

/// Small, offline, vetted emergency-guidance library.
///
/// Used two ways: (1) answered directly when no on-device model is available, and
/// (2) retrieved and injected as grounding context for the on-device model so its answers
/// stay anchored to known-safe guidance. Content is deliberately conservative general first-aid
/// guidance and always points to professional help.
public enum EmergencyKnowledge {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let keywords: [String]
        public let steps: [String]
        /// "first-aid" or "disaster".
        public var category: String = "first-aid"
        /// Signs that mean "get professional help now" for this topic.
        public var redFlags: [String] = []

        /// Where the guidance comes from. These are paraphrases of widely published general
        /// guidance and still need review by a clinician before shipping.
        public var source: String {
            category == "disaster" ? "General disaster-preparedness guidance (summary; not official advice)"
                                   : "General first-aid guidance (summary; not reviewed by a clinician)"
        }

        public var text: String {
            var lines = "\(title):\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            if !redFlags.isEmpty { lines += "\nGet help immediately if: " + redFlags.joined(separator: "; ") + "." }
            return lines
        }
    }

    public static let disclaimer = "General guidance only — get professional medical help as soon as you can."

    public static let entries: [Entry] = coreEntries + EmergencyLibrary.extended

    static let coreEntries: [Entry] = [
        Entry(id: "bleeding", title: "Severe bleeding",
              keywords: ["bleed", "bleeding", "blood", "cut", "wound", "laceration"],
              steps: ["Press firmly on the wound with a clean cloth or your hand and keep pressing.",
                      "If blood soaks through, add more cloth on top — do not remove the first layer.",
                      "Keep the person lying down and warm.",
                      "For life-threatening limb bleeding that pressure can't stop, a tourniquet above the wound may be used by someone trained."]),
        Entry(id: "cpr", title: "Not breathing / CPR",
              keywords: ["cpr", "not breathing", "no pulse", "unresponsive", "unconscious", "cardiac", "heart attack", "collapsed"],
              steps: ["Check for response and normal breathing (no more than 10 seconds).",
                      "Shout for help and ask someone to get emergency help and an AED if available.",
                      "Push hard and fast in the centre of the chest: about 100–120 compressions per minute, 5–6 cm deep.",
                      "Keep going until help arrives or the person starts breathing normally."]),
        Entry(id: "burns", title: "Burns",
              keywords: ["burn", "burns", "burned", "burnt", "scald"],
              steps: ["Cool the burn under cool running water for 20 minutes.",
                      "Remove jewellery or tight clothing near the burn unless stuck to it.",
                      "Cover loosely with cling film or a clean non-fluffy cloth.",
                      "Do not use ice, butter or creams. Seek help for large, deep, face, hand or genital burns."]),
        Entry(id: "choking", title: "Choking (adult)",
              keywords: ["choke", "choking", "can't breathe", "cannot breathe", "swallowed"],
              steps: ["Encourage them to cough.",
                      "If coughing fails, give up to 5 firm back blows between the shoulder blades.",
                      "Then give up to 5 abdominal thrusts (pull inwards and upwards above the navel).",
                      "Alternate back blows and thrusts; if they become unresponsive, start CPR."]),
        Entry(id: "fracture", title: "Suspected broken bone",
              keywords: ["broken", "fracture", "bone", "fell", "fall", "can't move", "cannot move", "sprain"],
              steps: ["Keep the injured part still in the position found.",
                      "Support it with padding or a sling; don't try to straighten it.",
                      "If the neck or back may be injured, do not move the person unless they are in danger.",
                      "Watch for shock: pale, cold, clammy skin — keep them warm and lying down."]),
        Entry(id: "heat", title: "Heatstroke",
              keywords: ["heat", "heatstroke", "sunstroke", "overheated", "hot", "dehydrated", "dehydration"],
              steps: ["Move the person somewhere cool and shaded.",
                      "Cool them quickly: wet the skin, fan them, apply cold packs to neck, armpits and groin.",
                      "Give sips of water if they are fully awake.",
                      "Confusion or collapse is an emergency — get help."]),
        Entry(id: "cold", title: "Hypothermia",
              keywords: ["cold", "hypothermia", "freezing", "shivering", "wet and cold"],
              steps: ["Move them out of the cold and remove wet clothing.",
                      "Warm the body core gradually with blankets and skin-to-skin contact.",
                      "Give warm sweet drinks if fully awake — no alcohol.",
                      "Don't rub limbs or use very hot water."]),
        Entry(id: "snake", title: "Snake bite",
              keywords: ["snake", "bite", "bitten", "venom"],
              steps: ["Keep the person calm and still; movement spreads venom.",
                      "Keep the bitten limb at or below heart level and remove rings or tight items.",
                      "Do not cut, suck, or apply ice or a tourniquet.",
                      "Get to medical care for anti-venom as soon as possible; note the time of the bite."]),
        Entry(id: "earthquake", title: "Earthquake",
              keywords: ["earthquake", "quake", "tremor", "aftershock", "shaking"],
              steps: ["Drop, cover and hold on under sturdy furniture during shaking.",
                      "Stay away from windows and outside walls; don't run outside while shaking.",
                      "After shaking stops, leave damaged buildings carefully and expect aftershocks.",
                      "If trapped, tap on pipes or walls and use a whistle instead of shouting to save energy."], category: "disaster"),
        Entry(id: "flood", title: "Flood",
              keywords: ["flood", "flooding", "water rising", "river", "drowning"],
              steps: ["Move to higher ground immediately.",
                      "Never walk or drive through moving water — 15 cm can knock you down.",
                      "Avoid touching electrical equipment if you are wet or standing in water.",
                      "Signal from a high point if trapped and conserve phone battery."], category: "disaster"),
        Entry(id: "fire", title: "Fire / smoke",
              keywords: ["fire", "smoke", "flames", "burning building"],
              steps: ["Get out and stay out; alert others on the way.",
                      "Stay low under smoke and cover your nose and mouth.",
                      "Feel doors with the back of your hand — don't open hot doors.",
                      "If clothes catch fire: stop, drop and roll."], category: "disaster"),
        Entry(id: "shock", title: "Shock",
              keywords: ["shock", "pale", "clammy", "faint", "fainted", "dizzy"],
              steps: ["Lay the person down and raise their legs if no injury prevents it.",
                      "Keep them warm and reassure them.",
                      "Don't give food or drink.",
                      "Monitor breathing; start CPR if it stops."]),
    ]

    /// Entries ranked by keyword overlap with `query`.
    public static func search(_ query: String, limit: Int = 2) -> [Entry] {
        let lower = query.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init))
        // Single-word keywords match as substrings ("bleeding" ⊃ "bleed"); multi-word keywords
        // match when all their words appear anywhere ("water is rising" ⊇ "water rising").
        func matches(_ keyword: String) -> Bool {
            let parts = keyword.split(separator: " ").map(String.init)
            return parts.count == 1 ? lower.contains(keyword) : parts.allSatisfy(words.contains)
        }
        let scored = entries.compactMap { entry -> (Entry, Int)? in
            let score = entry.keywords.reduce(0) { $0 + (matches($1) ? ($1.contains(" ") ? 3 : 2) : 0) }
                + (lower.contains(entry.title.lowercased()) ? 3 : 0)
            return score > 0 ? (entry, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Answer directly from the library, or nil when nothing relevant is known.
    public static func answer(_ query: String) -> String? {
        guard let best = search(query, limit: 1).first else { return nil }
        return best.text + "\n\n" + disclaimer
    }
}
