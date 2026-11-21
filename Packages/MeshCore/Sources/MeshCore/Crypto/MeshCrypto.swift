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
/// ECDH with the recipient's static key, HKDF-SHA256, ChaCha20-Poly1305. Relays only ever see
/// ciphertext. Sender authenticity comes from the Ed25519 signature on the outer packet.
/// Group messages use a shared 256-bit group key distributed through direct (sealed) invites.
public enum MeshCrypto {
    static let directInfo = Data("BLEMesh-DM-v1".utf8)

    /// Encrypt `plaintext` so only the holder of `recipientAgreementKey`'s private key can read it.
    /// Output: ephemeralPublicKey(32) || nonce(12) || ciphertext || tag(16)
    public static func sealDirect(_ plaintext: Data, to recipientAgreementKey: Data) throws -> Data {
        guard let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientAgreementKey) else {
            throw MeshCryptoError.invalidKey
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let salt = ephemeral.publicKey.rawRepresentation + recipientAgreementKey
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: directInfo, outputByteCount: 32)
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return ephemeral.publicKey.rawRepresentation + box.combined
    }

    public static func openDirect(_ sealed: Data, with agreementKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard sealed.count > 32 + 12 + 16 else { throw MeshCryptoError.malformedCiphertext }
        let ephemeralData = sealed.prefix(32)
        guard let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralData) else {
            throw MeshCryptoError.malformedCiphertext
        }
        let shared = try agreementKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let salt = Data(ephemeralData) + agreementKey.publicKey.rawRepresentation
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: directInfo, outputByteCount: 32)
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed.dropFirst(32))
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw MeshCryptoError.decryptionFailed
        }
    }

    /// Encrypt for a group. The group ID is bound as associated data.
    /// Output: groupID(16) || nonce(12) || ciphertext || tag(16)
    public static func sealGroup(_ plaintext: Data, groupID: UUID, key: Data) throws -> Data {
        guard key.count == 32 else { throw MeshCryptoError.invalidKey }
        var writer = ByteWriter()
        writer.uuid(groupID)
        let aad = writer.data
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad)
        return aad + box.combined
    }

    /// Peek the group ID of a group ciphertext without decrypting.
    public static func groupID(ofSealed sealed: Data) -> UUID? {
        var reader = ByteReader(sealed)
        return try? reader.uuid()
    }

    public static func openGroup(_ sealed: Data, key: Data) throws -> Data {
        guard key.count == 32, sealed.count > 16 + 12 + 16 else { throw MeshCryptoError.malformedCiphertext }
        let aad = sealed.prefix(16)
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed.dropFirst(16))
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw MeshCryptoError.decryptionFailed
        }
    }

    public static func makeGroupKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
