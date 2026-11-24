import Foundation

/// Looks up a string that comes from MeshCore or other runtime data (priority, category, SOS status,
/// credibility labels) in the app's string catalog. Unknown keys fall back to the English text.
func L(_ key: String) -> String {
    String(localized: String.LocalizationValue(key))
}
