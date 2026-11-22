import Foundation

/// Application content carried inside `.message` packets (after decryption).
public enum MeshContent: Codable, Equatable, Sendable {
    case text(String)
    /// Voice note sent as an on-device transcript; the receiver re-speaks it.
    case voice(VoiceNote)
    /// Emergency request with optional location and sender-side triage.
    case sos(SOSReport)
    case groupInvite(GroupInvite)
    case groupLeave(groupID: UUID)
    /// "Ask the mesh": question for a peer with an on-device model.
    case aiQuery(AIQuery)
    case aiResponse(AIResponse)
    /// Responder / sender update on an SOS (acknowledged, en route, resolved, cancelled).
    case sosUpdate(SOSUpdate)
    /// "I'm safe" / "I need help" check-in, optionally answering an "Are you safe?" request.
    case checkIn(CheckIn)
    /// "Are you safe?" request to a group (e.g. family).
    case safetyCheck(SafetyCheck)

    /// Text shown in message lists / notifications.
    public var previewText: String {
        switch self {
        case .text(let text): return text
        case .voice(let note): return "🎙 \(note.transcript)"
        case .sos(let report): return "🆘 \(report.text)"
        case .groupInvite(let invite): return "Added you to “\(invite.name)”"
        case .groupLeave: return "Left the group"
        case .aiQuery(let query): return "🤖 Asked: \(query.prompt)"
        case .aiResponse(let response): return "🤖 \(response.text)"
        case .sosUpdate(let update): return "🆘 \(update.status.label)" + (update.note.map { ": \($0)" } ?? "")
        case .checkIn(let checkIn): return checkIn.status == .safe ? "✅ I'm safe" + (checkIn.note.map { " — \($0)" } ?? "")
                                                                   : "⚠️ I need help" + (checkIn.note.map { " — \($0)" } ?? "")
        case .safetyCheck(let check): return "❓ Are you safe?" + (check.note.map { " — \($0)" } ?? "")
        }
    }
}

public struct VoiceNote: Codable, Equatable, Sendable {
    public var transcript: String
    /// BCP-47 language of the transcript (e.g. "en-US", "hi-IN").
    public var languageCode: String
    public var durationSeconds: Double

    public init(transcript: String, languageCode: String, durationSeconds: Double) {
        self.transcript = transcript
        self.languageCode = languageCode
        self.durationSeconds = durationSeconds
    }
}

public struct GeoPoint: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Double?

    public init(latitude: Double, longitude: Double, accuracyMeters: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
    }
}

public struct SOSReport: Codable, Equatable, Sendable {
    public var text: String
    public var location: GeoPoint?
    public var triage: SOSTriage?
    /// Optional medical profile the sender chose to attach (public: SOS is readable by everyone nearby).
    public var medical: MedicalInfo?

    public init(text: String, location: GeoPoint? = nil, triage: SOSTriage? = nil, medical: MedicalInfo? = nil) {
        self.text = text
        self.location = location
        self.triage = triage
        self.medical = medical
    }
}

/// Medical details responders need first. Every field is optional and user-entered.
public struct MedicalInfo: Codable, Equatable, Sendable {
    public var bloodType: String?
    public var allergies: String?
    public var conditions: String?
    public var medications: String?
    public var emergencyContact: String?

    public init(bloodType: String? = nil, allergies: String? = nil, conditions: String? = nil,
                medications: String? = nil, emergencyContact: String? = nil) {
        self.bloodType = bloodType
        self.allergies = allergies
        self.conditions = conditions
        self.medications = medications
        self.emergencyContact = emergencyContact
    }

    public var isEmpty: Bool {
        [bloodType, allergies, conditions, medications, emergencyContact].allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Lines for display, skipping empty fields.
    public var summaryLines: [String] {
        [("Blood type", bloodType), ("Allergies", allergies), ("Conditions", conditions),
         ("Medications", medications), ("Emergency contact", emergencyContact)]
            .compactMap { label, value in
                guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
                return "\(label): \(value)"
            }
    }
}

public enum SOSStatus: Int, Codable, Sendable, Comparable, CaseIterable {
    case open = 0, acknowledged = 1, enRoute = 2, resolved = 3, cancelled = 4

    public static func < (lhs: SOSStatus, rhs: SOSStatus) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .open: return "Open"
        case .acknowledged: return "Acknowledged"
        case .enRoute: return "Help on the way"
        case .resolved: return "Resolved"
        case .cancelled: return "Cancelled"
        }
    }
}

public struct SOSUpdate: Codable, Equatable, Sendable {
    /// Message ID of the SOS this refers to.
    public var sosID: UUID
    public var status: SOSStatus
    public var note: String?

    public init(sosID: UUID, status: SOSStatus, note: String? = nil) {
        self.sosID = sosID
        self.status = status
        self.note = note
    }
}

public struct CheckIn: Codable, Equatable, Sendable {
    public enum Status: Int, Codable, Sendable { case safe = 0, needHelp = 1 }
    public var status: Status
    public var location: GeoPoint?
    /// Battery percentage 0–100, if shared.
    public var batteryPercent: Int?
    public var note: String?
    /// The "Are you safe?" request this answers, if any.
    public var inReplyTo: UUID?

    public init(status: Status, location: GeoPoint? = nil, batteryPercent: Int? = nil, note: String? = nil, inReplyTo: UUID? = nil) {
        self.status = status
        self.location = location
        self.batteryPercent = batteryPercent
        self.note = note
        self.inReplyTo = inReplyTo
    }
}

public struct SafetyCheck: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var note: String?

    public init(requestID: UUID = UUID(), note: String? = nil) {
        self.requestID = requestID
        self.note = note
    }
}

public struct GroupInvite: Codable, Equatable, Sendable {
    public var groupID: UUID
    public var name: String
    public var members: [PeerID]
    /// 32-byte group key. Only ever transmitted inside an E2E-sealed direct message.
    public var key: Data

    public init(groupID: UUID, name: String, members: [PeerID], key: Data) {
        self.groupID = groupID
        self.name = name
        self.members = members
        self.key = key
    }
}

public struct AIQuery: Codable, Equatable, Sendable {
    public var queryID: UUID
    public var prompt: String

    public init(queryID: UUID = UUID(), prompt: String) {
        self.queryID = queryID
        self.prompt = prompt
    }
}

public struct AIResponse: Codable, Equatable, Sendable {
    public var queryID: UUID
    public var text: String
    public var answeredBy: String

    public init(queryID: UUID, text: String, answeredBy: String) {
        self.queryID = queryID
        self.text = text
        self.answeredBy = answeredBy
    }
}

/// Plaintext envelope inside a message packet payload (before encryption).
public struct MessageEnvelope: Codable, Equatable, Sendable {
    /// Stable application message ID (same across retransmissions).
    public var messageID: UUID
    public var sentAt: Date
    public var senderName: String
    /// Set for group messages.
    public var groupID: UUID?
    public var content: MeshContent

    public init(messageID: UUID = UUID(), sentAt: Date, senderName: String, groupID: UUID? = nil, content: MeshContent) {
        self.messageID = messageID
        self.sentAt = sentAt
        self.senderName = senderName
        self.groupID = groupID
        self.content = content
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public func encode() throws -> Data { try Self.encoder.encode(self) }
    public static func decode(_ data: Data) throws -> MessageEnvelope { try decoder.decode(MessageEnvelope.self, from: data) }
}
