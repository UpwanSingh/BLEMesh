import Foundation

/// The small dictionary protocol between the Watch app and the iPhone app (WatchConnectivity).
/// The watch can't run the Bluetooth mesh in the background, so the iPhone sends on its behalf.
enum WatchMessage {
    enum Action: String {
        /// Send an SOS from the watch (the iPhone adds its GPS fix).
        case sos
        /// "I'm safe" check-in to the user's groups.
        case safe
        /// Just report status.
        case status
    }

    enum Key {
        static let action = "action"
        static let text = "text"
        static let requestedAt = "requestedAt"
        // Replies and application context
        static let result = "result"
        static let peers = "peers"
        static let sosStatus = "sosStatus"
        static let sosResponders = "sosResponders"
        static let sosSentAt = "sosSentAt"
    }

    enum Result: String {
        case sent, noGroups, failed
    }

    static func request(_ action: Action, text: String? = nil, at date: Date = Date()) -> [String: Any] {
        var message: [String: Any] = [Key.action: action.rawValue, Key.requestedAt: date.timeIntervalSince1970]
        if let text { message[Key.text] = text }
        return message
    }

    /// Requests older than this are dropped by the iPhone (e.g. a queued SOS delivered hours later
    /// would mislead responders).
    static let maxRequestAge: TimeInterval = 30 * 60
}
