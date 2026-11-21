import Foundation
import CryptoKit

/// Public half of a device identity, as learned from announces.
public struct PublicIdentity: Equatable, Hashable, Sendable {
    /// Raw Ed25519 public key (32 bytes).
    public let signingKey: Data
    /// Raw X25519 public key (32 bytes).
    public let agreementKey: Data

    public init(signingKey: Data, agreementKey: Data) {
        self.signingKey = signingKey
        self.agreementKey = agreementKey
    }

    public var peerID: PeerID { PeerID(signingKey: signingKey) }

    /// Short fingerprint users can compare out of band ("safety number").
    public var fingerprint: String {
        let digest = SHA256.hash(data: signingKey + agreementKey)
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 24, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

/// This device's long-term keys. Persist `signingKeyData` / `agreementKeyData` in the Keychain.
public struct MeshIdentity: Sendable {
    public let signingKey: Curve25519.Signing.PrivateKey
    public let agreementKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        self.signingKey = Curve25519.Signing.PrivateKey()
        self.agreementKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(signingKeyData: Data, agreementKeyData: Data) throws {
        self.signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyData)
        self.agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementKeyData)
    }

    public var signingKeyData: Data { signingKey.rawRepresentation }
    public var agreementKeyData: Data { agreementKey.rawRepresentation }

    public var publicIdentity: PublicIdentity {
        PublicIdentity(
            signingKey: signingKey.publicKey.rawRepresentation,
            agreementKey: agreementKey.publicKey.rawRepresentation
        )
    }

    public var peerID: PeerID { publicIdentity.peerID }

    func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }
}
