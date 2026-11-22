import Foundation
import CryptoKit

public enum MeshCryptoError: Error, Equatable {
    case invalidKey
    case malformedCiphertext
    case decryptionFailed
}

/// End-to-end encryption primitives.
///
/// Direct messages use a sealed-box construction: a fresh ephemeral X25519 key per message,
/// ECDH with the recipient's static key, HKDF-SHA256, ChaCha20-Poly1305. The sender's Ed25519
/// public key is bound into the key derivation, so a ciphertext only opens when it arrives in a
/// packet signed by its real author — a relay can't re-sign someone else's message as its own.
/// Group messages use a shared 256-bit group key distributed through direct (sealed) invites,
/// with the group ID and sender key as associated data.
public enum MeshCrypto {
    static let directInfo = Data("BLEMesh-DM-v1".utf8)

    /// Encrypt `plaintext` so only the holder of `recipientAgreementKey`'s private key can read it.
    /// Output: ephemeralPublicKey(32) || nonce(12) || ciphertext || tag(16)
    public static func sealDirect(_ plaintext: Data, to recipientAgreementKey: Data, from senderSigningKey: Data) throws -> Data {
        guard let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientAgreementKey) else {
            throw MeshCryptoError.invalidKey
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let salt = ephemeral.publicKey.rawRepresentation + recipientAgreementKey
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: directInfo + senderSigningKey,
                                                 outputByteCount: 32)
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return ephemeral.publicKey.rawRepresentation + box.combined
    }

    public static func openDirect(_ sealed: Data, with agreementKey: Curve25519.KeyAgreement.PrivateKey,
                                  from senderSigningKey: Data) throws -> Data {
        guard sealed.count > 32 + 12 + 16 else { throw MeshCryptoError.malformedCiphertext }
        let ephemeralData = sealed.prefix(32)
        guard let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralData) else {
            throw MeshCryptoError.malformedCiphertext
        }
        let shared = try agreementKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let salt = Data(ephemeralData) + agreementKey.publicKey.rawRepresentation
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: directInfo + senderSigningKey,
                                                 outputByteCount: 32)
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed.dropFirst(32))
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw MeshCryptoError.decryptionFailed
        }
    }

    /// Encrypt for a group. The group ID and the sender's signing key are bound as associated data.
    /// Output: groupID(16) || nonce(12) || ciphertext || tag(16)
    public static func sealGroup(_ plaintext: Data, groupID: UUID, key: Data, from senderSigningKey: Data) throws -> Data {
        guard key.count == 32 else { throw MeshCryptoError.invalidKey }
        var writer = ByteWriter()
        writer.uuid(groupID)
        let header = writer.data
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), authenticating: header + senderSigningKey)
        return header + box.combined
    }

    /// Peek the group ID of a group ciphertext without decrypting.
    public static func groupID(ofSealed sealed: Data) -> UUID? {
        var reader = ByteReader(sealed)
        return try? reader.uuid()
    }

    public static func openGroup(_ sealed: Data, key: Data, from senderSigningKey: Data) throws -> Data {
        guard key.count == 32, sealed.count > 16 + 12 + 16 else { throw MeshCryptoError.malformedCiphertext }
        let header = Data(sealed.prefix(16))
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed.dropFirst(16))
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: header + senderSigningKey)
        } catch {
            throw MeshCryptoError.decryptionFailed
        }
    }

    // MARK: - Forward-secret direct messages

    /// Direct-message wire modes (first payload byte).
    enum DirectMode: UInt8 {
        /// Ephemeral ↔ recipient static key only (fallback when no prekey is known).
        case staticOnly = 1
        /// Ephemeral ↔ recipient prekey AND ephemeral ↔ recipient static key. Once the recipient
        /// deletes the prekey, nobody — including someone who later steals the device — can
        /// recompute the key: forward secrecy with a window equal to the prekey lifetime.
        case prekeyed = 2
    }

    static let prekeyedInfo = Data("BLEMesh-DM-PK-v1".utf8)

    /// Seal a direct message, using the recipient's prekey when one is known.
    /// Output: mode u8 | (prekeyed: prekeyID u32) | ephemeralPublicKey(32) | nonce | ciphertext | tag
    public static func sealDirectMessage(_ plaintext: Data, to recipientStaticKey: Data, prekey: PublicPrekey?,
                                         from senderSigningKey: Data) throws -> Data {
        guard let prekey else {
            return Data([DirectMode.staticOnly.rawValue]) + (try sealDirect(plaintext, to: recipientStaticKey, from: senderSigningKey))
        }
        guard let recipientStatic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientStaticKey),
              let recipientPrekey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: prekey.key) else {
            throw MeshCryptoError.invalidKey
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let dh1 = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPrekey)
        let dh2 = try ephemeral.sharedSecretFromKeyAgreement(with: recipientStatic)
        let key = prekeyedKey(dh1, dh2, ephemeral: ephemeral.publicKey.rawRepresentation,
                              prekey: prekey.key, recipientStatic: recipientStaticKey, sender: senderSigningKey)
        var w = ByteWriter()
        w.u8(DirectMode.prekeyed.rawValue)
        w.u32(prekey.id)
        return w.data + ephemeral.publicKey.rawRepresentation + (try ChaChaPoly.seal(plaintext, using: key)).combined
    }

    /// Open a direct message. `prekeyFor` returns our private prekey for an ID, or nil if it has
    /// been deleted (then the message is permanently unreadable — by design).
    public static func openDirectMessage(_ sealed: Data, staticKey: Curve25519.KeyAgreement.PrivateKey,
                                         prekeyFor: (UInt32) -> Curve25519.KeyAgreement.PrivateKey?,
                                         from senderSigningKey: Data) throws -> Data {
        guard let rawMode = sealed.first, let mode = DirectMode(rawValue: rawMode) else {
            throw MeshCryptoError.malformedCiphertext
        }
        let body = Data(sealed.dropFirst())
        switch mode {
        case .staticOnly:
            return try openDirect(body, with: staticKey, from: senderSigningKey)
        case .prekeyed:
            var r = ByteReader(body)
            guard let prekeyID = try? r.u32(), let ephemeralData = try? r.bytes(32), r.remaining > 12 + 16,
                  let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralData) else {
                throw MeshCryptoError.malformedCiphertext
            }
            guard let prekey = prekeyFor(prekeyID) else { throw MeshCryptoError.decryptionFailed }
            let dh1 = try prekey.sharedSecretFromKeyAgreement(with: ephemeral)
            let dh2 = try staticKey.sharedSecretFromKeyAgreement(with: ephemeral)
            let key = prekeyedKey(dh1, dh2, ephemeral: ephemeralData, prekey: prekey.publicKey.rawRepresentation,
                                  recipientStatic: staticKey.publicKey.rawRepresentation, sender: senderSigningKey)
            do {
                return try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: r.rest()), using: key)
            } catch {
                throw MeshCryptoError.decryptionFailed
            }
        }
    }

    private static func prekeyedKey(_ dh1: SharedSecret, _ dh2: SharedSecret, ephemeral: Data, prekey: Data,
                                    recipientStatic: Data, sender: Data) -> SymmetricKey {
        let ikm = dh1.withUnsafeBytes { Data($0) } + dh2.withUnsafeBytes { Data($0) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                      salt: ephemeral + prekey + recipientStatic,
                                      info: prekeyedInfo + sender, outputByteCount: 32)
    }

    public static func makeGroupKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
