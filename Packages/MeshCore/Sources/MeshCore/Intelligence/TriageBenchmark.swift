import Foundation

/// Labelled SOS triage examples (English, Hindi, Hinglish) used to tune, train and measure triage.
/// - `tuning`: used to write the keyword rules.
/// - `heldOutV1`: written separately; later also used for vocabulary expansion (so no longer blind).
/// - `heldOutV2`: never used for tuning or training — the honest accuracy estimate.
/// Hand-written starting data; extend with real anonymised field messages.
public enum TriageBenchmark {
    public typealias C = SOSTriage.Category
    public typealias P = SOSTriage.Priority
    public typealias Example = (text: String, category: C, minPriority: P, lifeThreatening: Bool)

    public static let tuning: [Example] = [
        // Medical — life threatening
        ("My father collapsed and is not breathing", .medical, .critical, true),
        ("Woman unconscious near the bus stop, please hurry", .medical, .critical, true),
        ("He is having a seizure and won't stop shaking", .medical, .critical, true),
        ("Heavy bleeding from his leg after the accident", .medical, .critical, true),
        ("Grandmother has chest pain, think it's a heart attack", .medical, .critical, true),
        ("Child can't breathe after eating peanuts, face swelling", .medical, .critical, true),
        ("Man stabbed, bleeding heavily outside the station", .violence, .critical, true),
        ("Baby is not breathing please help", .medical, .critical, true),
        ("Pregnant woman in labour, bleeding a lot", .medical, .critical, true),
        ("Old man collapsed in the heat, unconscious", .medical, .critical, true),
        ("papa behosh ho gaye hain, saans nahi le rahe", .medical, .critical, true),
        ("bachche ko saans nahi aa rahi", .medical, .critical, true),
        // Medical — serious
        ("I fell and think my leg is broken, can't move", .medical, .high, false),
        ("Friend twisted her ankle badly and can't walk", .medical, .high, false),
        ("Diabetic friend feeling faint and shaky", .medical, .high, false),
        ("Deep cut on my hand, bleeding through the cloth", .medical, .high, false),
        ("Elderly woman fell down the stairs, in pain", .medical, .high, false),
        ("Kid has a high fever and is vomiting", .medical, .medium, false),
        ("Need a doctor for my mother, she is very weak", .medical, .high, false),
        ("Burn on my arm from boiling water", .medical, .medium, false),
        ("Asthma attack, inhaler is empty", .medical, .high, false),
        ("mujhe chot lagi hai, pair toot gaya lagta hai", .medical, .high, false),
        ("Someone fainted in the queue", .medical, .high, false),
        ("Allergic reaction, hands are swelling", .medical, .high, false),
        // Fire
        ("Fire in the building on 3rd floor, smoke everywhere", .fire, .critical, true),
        ("Kitchen fire spreading to the next house", .fire, .critical, true),
        ("Thick smoke coming from the market stalls", .fire, .critical, true),
        ("Car on fire near the petrol pump", .fire, .critical, true),
        ("Flames in the forest near the camp", .fire, .critical, true),
        ("aag lagi hai, jaldi aao", .fire, .critical, true),
        ("दुकान में आग लग गई है", .fire, .critical, true),
        // Flood
        ("Water rising fast in our street, we're on the roof", .flood, .high, false),
        ("Flood water entered the ground floor, old people inside", .flood, .high, false),
        ("Someone is drowning in the river!", .flood, .critical, true),
        ("Car stuck in flood water with people inside", .flood, .high, false),
        ("बाढ़ का पानी घर में आ गया है", .flood, .high, false),
        ("baadh aa gayi hai, madad chahiye", .flood, .high, false),
        ("Village is submerged, need boats", .flood, .high, false),
        // Trapped
        ("Two people trapped under rubble after the building collapsed", .trapped, .critical, true),
        ("We are stuck in the lift, it's been an hour", .trapped, .critical, true),
        ("Man buried under debris, we can hear him", .trapped, .critical, true),
        ("Family trapped on the second floor, stairs collapsed", .trapped, .critical, true),
        ("Kids stuck in the school after the earthquake", .trapped, .critical, true),
        ("hum malbe mein fase hain", .trapped, .critical, true),
        ("Cannot get out, the door is jammed and there's smoke", .trapped, .critical, true),
        // Violence
        ("Men with knives attacking people near the gate", .violence, .critical, true),
        ("Shooting heard near the temple, people running", .violence, .critical, true),
        ("A group is beating someone at the corner", .violence, .high, false),
        ("Someone is following and threatening me", .violence, .high, false),
        ("Assault in progress behind the mall", .violence, .high, false),
        // Missing
        ("Lost child, 5 years old, red shirt, near the fountain", .missingPerson, .high, false),
        ("My grandfather is missing since morning, has dementia", .missingPerson, .high, false),
        ("Can't find my daughter in the crowd", .missingPerson, .high, false),
        ("मेरा बेटा लापता है", .missingPerson, .high, false),
        ("Missing: elderly woman with walking stick", .missingPerson, .high, false),
        // Supplies
        ("We need drinking water and food at the shelter", .supplies, .low, false),
        ("Need blankets for 20 people tonight", .supplies, .low, false),
        ("Our phones are dying, anyone have a charger or power bank?", .supplies, .low, false),
        ("Running out of baby food", .supplies, .low, false),
        ("pani aur khana chahiye", .supplies, .low, false),
        ("Need medicine for my diabetic mother, insulin running out", .medical, .medium, false),
        ("Shelter needed for 5 families", .supplies, .low, false),
        // Not emergencies
        ("Anyone up for tea later?", .other, .low, false),
        ("Is the network back yet?", .other, .low, false),
        ("Thanks everyone for helping today", .other, .low, false),
        ("Which way to the main road?", .other, .low, false),
    ]

    public static let heldOutV1: [Example] = [
        ("my husband just passed out and isn't responding", .medical, .critical, true),
        ("there's a guy lying on the road, not moving, blood everywhere", .medical, .critical, true),
        ("my son swallowed something and is choking", .medical, .critical, true),
        ("she can barely breathe, lips going blue", .medical, .critical, true),
        ("motorbike accident, rider has a bad head wound", .medical, .high, false),
        ("I think my wrist is fractured", .medical, .high, false),
        ("got burnt while cooking, big blisters", .medical, .medium, false),
        ("dadi ko chakkar aa raha hai aur ulti ho rahi hai", .medical, .medium, false),
        ("the hostel is on fire!!", .fire, .critical, true),
        ("electrical short, sparks and smoke from the meter box", .fire, .critical, true),
        ("godown mein aag", .fire, .critical, true),
        ("water is up to our knees inside the house", .flood, .high, false),
        ("the bridge road is flooded, a bus is stuck in water", .flood, .high, false),
        ("my cousin fell into the canal and went under", .flood, .critical, true),
        ("wall fell on two workers, they're pinned", .trapped, .critical, true),
        ("people stuck inside the collapsed shop", .trapped, .critical, true),
        ("lift band ho gayi, andar fase hain", .trapped, .critical, true),
        ("someone has a gun at the station entrance", .violence, .critical, true),
        ("a mob is attacking cars on the highway", .violence, .high, false),
        ("woman being harassed and hit near the park", .violence, .high, false),
        ("my 8 year old wandered off, blue cap, last seen at gate 2", .missingPerson, .high, false),
        ("haven't heard from my brother since the quake, he's missing", .missingPerson, .high, false),
        ("we have 30 people here with no food since yesterday", .supplies, .medium, false),
        ("need tarpaulins and dry clothes for the camp", .supplies, .low, false),
        ("can someone share a power bank near the stage?", .supplies, .low, false),
        ("good morning everyone, network is still down", .other, .low, false),
        ("which shelter has space for pets?", .other, .low, false),
    ]

    public static let heldOutV2: [Example] = [
        ("old lady slipped in the bathroom and hit her head, she's confused", .medical, .high, false),
        ("he took too many sleeping pills, very drowsy", .medical, .critical, true),
        ("my friend got bitten by a snake on the farm", .medical, .high, false),
        ("toddler fell from the balcony", .medical, .critical, true),
        ("sugar patient sweating and talking nonsense", .medical, .high, false),
        ("pet dog bit my neighbour's kid, deep marks", .medical, .high, false),
        ("someone collapsed during the marathon, no pulse", .medical, .critical, true),
        ("my wife's water broke, baby is coming", .medical, .high, false),
        ("short circuit started a fire in the slum", .fire, .critical, true),
        ("gas cylinder exploded, houses burning", .fire, .critical, true),
        ("bus caught fire on the expressway", .fire, .critical, true),
        ("river overflowed, our village is cut off", .flood, .high, false),
        ("kids playing in the drain got washed away", .flood, .critical, true),
        ("basement flooded with people inside", .flood, .critical, true),
        ("landslide hit the road, car buried under mud with people", .trapped, .critical, true),
        ("worker trapped in a well", .trapped, .critical, true),
        ("people locked inside the burning factory", .trapped, .critical, true),
        ("a man is waving a sword at people in the market", .violence, .critical, true),
        ("gang fight with sticks outside the college", .violence, .high, false),
        ("my phone was snatched and the guy punched me", .violence, .high, false),
        ("grandpa with alzheimer's left home this morning, not back", .missingPerson, .high, false),
        ("lost my 3 year old at the railway station", .missingPerson, .high, false),
        ("we need sanitary pads and diapers at the relief camp", .supplies, .low, false),
        ("no drinking water for 2 days, 50 families", .supplies, .medium, false),
        ("can anyone lend a torch and batteries?", .supplies, .low, false),
        ("hello, testing if this app works", .other, .low, false),
        ("what time does the relief truck come?", .other, .low, false),
        ("mera bhai pani mein doob raha hai", .flood, .critical, true),
        ("bijli ka taar gira hai, ek aadmi ko current laga", .medical, .critical, true),
        ("bachcha kho gaya mela mein", .missingPerson, .high, false),
    ]

    /// Examples the embedding classifier may learn from (never includes `heldOutV2`).
    public static var training: [Example] { tuning + heldOutV1 }

    public struct Score: Sendable {
        public var categoryAccuracy: Double
        public var priorityAccuracy: Double
        public var criticalRecall: Double
    }

    public static func score(_ examples: [Example], with triage: (String) -> SOSTriage) -> Score {
        var category = 0, priority = 0, crit = 0, critTotal = 0
        for example in examples {
            let t = triage(example.text)
            if t.category == example.category { category += 1 }
            if t.priority >= example.minPriority { priority += 1 }
            if example.lifeThreatening { critTotal += 1; if t.priority == .critical { crit += 1 } }
        }
        let n = Double(max(1, examples.count))
        return Score(categoryAccuracy: Double(category) / n, priorityAccuracy: Double(priority) / n,
                     criticalRecall: Double(crit) / Double(max(1, critTotal)))
    }
}
