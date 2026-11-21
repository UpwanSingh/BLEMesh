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

    public init(text: String, location: GeoPoint? = nil, triage: SOSTriage? = nil) {
        self.text = text
        self.location = location
        self.triage = triage
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
