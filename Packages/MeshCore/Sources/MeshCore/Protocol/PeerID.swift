import Foundation
import CryptoKit

/// Stable 16-byte mesh identity of a device.
///
/// A PeerID is derived from the device's Ed25519 signing key (first 16 bytes of SHA-256),
/// so any packet carrying the origin's public key can be checked against its claimed origin.
/// This is the only device identifier used above the transport layer — transport link IDs
/// (e.g. CoreBluetooth identifiers) never leak into routing or the UI.
public struct PeerID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let bytes: Data

    public static let broadcast = PeerID(uncheckedBytes: Data(count: 16))

    public init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        self.bytes = Data(bytes)
    }

    init(uncheckedBytes: Data) {
        self.bytes = Data(uncheckedBytes)
    }

    /// Derive the PeerID for a raw Ed25519 public key.
    public init(signingKey: Data) {
        let digest = SHA256.hash(data: signingKey)
        self.bytes = Data(digest.prefix(16))
    }

    public init?(hex: String) {
        guard hex.count == 32 else { return nil }
        var data = Data(capacity: 16)
        var index = hex.startIndex
        for _ in 0..<16 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self.bytes = data
    }

    public var isBroadcast: Bool { self == .broadcast }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Short human-friendly form for UI and logs.
    public var short: String { String(hex.prefix(8)) }

    public var description: String { short }

    public static func < (lhs: PeerID, rhs: PeerID) -> Bool { lhs.hex < rhs.hex }

    // Codable as hex string keeps persisted JSON readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let id = PeerID(hex: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid PeerID hex")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Opaque identifier of one transport link (one BLE connection, one simulated link, ...).
/// The same physical neighbor may be reachable over more than one link.
public struct LinkID: Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}
