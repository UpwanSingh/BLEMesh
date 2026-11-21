import Foundation
import CryptoKit

/// Mesh packet types (wire byte).
public enum PacketType: UInt8, Sendable {
    /// Presence + public keys + capabilities. Flooded with limited TTL.
    case announce = 1
    /// User content (public broadcast, E2E direct, or group).
    case message = 2
    /// End-to-end delivery / read acknowledgement, routed back to the message origin.
    case ack = 3
}

/// Packet flag bits.
public struct PacketFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Payload is sealed for the destination peer.
    public static let directEncrypted = PacketFlags(rawValue: 1 << 0)
    /// Payload is sealed with a group key.
    public static let groupEncrypted = PacketFlags(rawValue: 1 << 1)
}

/// A signed mesh packet.
///
/// Wire layout (v1, big-endian):
/// ```
/// version u8 | type u8 | flags u8 | ttl u8 | hops u8
/// packetID 16 | origin 16 | destination 16 | timestampMs u64
/// originSigningKey 32 | payloadLength u16 | payload | signature 64
/// ```
/// `ttl` and `hops` are mutated by relays and therefore excluded from the signature.
/// The origin PeerID must equal `PeerID(signingKey: originSigningKey)`, which makes every
/// packet self-verifying without any prior key exchange.
public struct Packet: Equatable, Sendable {
    public static let currentVersion: UInt8 = 1
    public static let headerSize = 5 + 16 + 16 + 16 + 8 + 32 + 2
    public static let signatureSize = 64
    public static let maxPayloadSize = 16 * 1024

    public var version: UInt8
    public var type: PacketType
    public var flags: PacketFlags
    public var ttl: UInt8
    public var hops: UInt8
    public var packetID: UUID
    public var origin: PeerID
    public var destination: PeerID
    public var timestampMs: UInt64
    public var originSigningKey: Data
    public var payload: Data
    public var signature: Data

    public var isBroadcast: Bool { destination.isBroadcast }
    public var timestamp: Date { Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000) }

    /// Build and sign a new packet originating at `identity`.
    public static func make(
        type: PacketType,
        flags: PacketFlags = [],
        ttl: UInt8,
        destination: PeerID,
        payload: Data,
        identity: MeshIdentity,
        now: Date,
        packetID: UUID = UUID()
    ) throws -> Packet {
        guard payload.count <= maxPayloadSize else { throw WireError.tooLarge }
        var packet = Packet(
            version: currentVersion,
            type: type,
            flags: flags,
            ttl: ttl,
            hops: 0,
            packetID: packetID,
            origin: identity.peerID,
            destination: destination,
            timestampMs: UInt64(max(0, now.timeIntervalSince1970 * 1000)),
            originSigningKey: identity.publicIdentity.signingKey,
            payload: payload,
            signature: Data()
        )
        packet.signature = try identity.sign(packet.signedBytes())
        return packet
    }

    /// Bytes covered by the signature (everything except ttl, hops and the signature itself).
    func signedBytes() -> Data {
        var w = ByteWriter()
        w.u8(version)
        w.u8(type.rawValue)
        w.u8(flags.rawValue)
        w.uuid(packetID)
        w.bytes(origin.bytes)
        w.bytes(destination.bytes)
        w.u64(timestampMs)
        w.bytes(originSigningKey)
        w.u16(UInt16(payload.count))
        w.bytes(payload)
        return w.data
    }

    /// Check origin/key binding and the Ed25519 signature.
    public func verify() -> Bool {
        guard originSigningKey.count == 32,
              signature.count == Packet.signatureSize,
              PeerID(signingKey: originSigningKey) == origin,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: originSigningKey)
        else { return false }
        return key.isValidSignature(signature, for: signedBytes())
    }

    public func encode() -> Data {
        var w = ByteWriter()
        w.u8(version)
        w.u8(type.rawValue)
        w.u8(flags.rawValue)
        w.u8(ttl)
        w.u8(hops)
        w.uuid(packetID)
        w.bytes(origin.bytes)
        w.bytes(destination.bytes)
        w.u64(timestampMs)
        w.bytes(originSigningKey)
        w.u16(UInt16(payload.count))
        w.bytes(payload)
        w.bytes(signature)
        return w.data
    }

    public static func decode(_ data: Data) throws -> Packet {
        var r = ByteReader(data)
        let version = try r.u8()
        guard version == currentVersion else { throw WireError.unsupportedVersion(version) }
        let rawType = try r.u8()
        guard let type = PacketType(rawValue: rawType) else { throw WireError.unknownType(rawType) }
        let flags = PacketFlags(rawValue: try r.u8())
        let ttl = try r.u8()
        let hops = try r.u8()
        let packetID = try r.uuid()
        let origin = try r.peerID()
        let destination = try r.peerID()
        let timestampMs = try r.u64()
        let originKey = try r.bytes(32)
        let length = Int(try r.u16())
        guard length <= maxPayloadSize else { throw WireError.tooLarge }
        let payload = try r.bytes(length)
        let signature = try r.bytes(signatureSize)
        guard r.isAtEnd else { throw WireError.invalidField("trailing bytes") }
        return Packet(
            version: version, type: type, flags: flags, ttl: ttl, hops: hops,
            packetID: packetID, origin: origin, destination: destination,
            timestampMs: timestampMs, originSigningKey: originKey,
            payload: payload, signature: signature
        )
    }
}

// MARK: - Control payloads

/// Capabilities advertised in announces.
public struct PeerCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Device can run an on-device language model and answer "Ask the mesh" queries.
    public static let onDeviceAI = PeerCapabilities(rawValue: 1 << 0)
    /// Device can translate text on-device.
    public static let translation = PeerCapabilities(rawValue: 1 << 1)
}

/// Announce payload: agreementKey(32) | capabilities u8 | nickname string8
public struct AnnouncePayload: Equatable, Sendable {
    public var agreementKey: Data
    public var capabilities: PeerCapabilities
    public var nickname: String

    public init(agreementKey: Data, capabilities: PeerCapabilities, nickname: String) {
        self.agreementKey = agreementKey
        self.capabilities = capabilities
        self.nickname = nickname
    }

    public func encode() -> Data {
        var w = ByteWriter()
        w.bytes(agreementKey)
        w.u8(capabilities.rawValue)
        w.string8(nickname)
        return w.data
    }

    public static func decode(_ data: Data) throws -> AnnouncePayload {
        var r = ByteReader(data)
        let key = try r.bytes(32)
        let caps = PeerCapabilities(rawValue: try r.u8())
        let nickname = try r.string8()
        return AnnouncePayload(agreementKey: key, capabilities: caps, nickname: nickname)
    }
}

/// Acknowledgement kinds.
public enum AckKind: UInt8, Sendable {
    case delivered = 1
    case read = 2
}

/// Ack payload: kind u8 | messageID 16 | ackedPacketID 16
public struct AckPayload: Equatable, Sendable {
    public var kind: AckKind
    /// Application-level message ID (stable across retries).
    public var messageID: UUID
    /// The specific packet (transmission) being acknowledged; lets carriers drop it.
    public var ackedPacketID: UUID

    public func encode() -> Data {
        var w = ByteWriter()
        w.u8(kind.rawValue)
        w.uuid(messageID)
        w.uuid(ackedPacketID)
        return w.data
    }

    public static func decode(_ data: Data) throws -> AckPayload {
        var r = ByteReader(data)
        let raw = try r.u8()
        guard let kind = AckKind(rawValue: raw) else { throw WireError.invalidField("ack kind") }
        return AckPayload(kind: kind, messageID: try r.uuid(), ackedPacketID: try r.uuid())
    }
}
