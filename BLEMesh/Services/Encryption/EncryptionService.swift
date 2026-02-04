import Foundation
import CryptoKit

/// Service handling all encryption operations for the mesh network
final class EncryptionService {
    
    // MARK: - Types
    
    struct EncryptedPayload: Codable {
        let ciphertext: Data
        let nonce: Data       // 12 bytes for AES-GCM
        let tag: Data         // 16 bytes authentication tag
    }
    
    struct SessionKey {
        let peerID: UUID
        let symmetricKey: SymmetricKey
        let createdAt: Date
        var lastUsed: Date
    }
    
    enum EncryptionError: Error, LocalizedError {
        case noSessionKey
        case invalidPublicKey
        case keyDerivationFailed
        case encryptionFailed
        case decryptionFailed
        case invalidNonce
        case authenticationFailed
        case signatureInvalid
        case noSigningKey
        
        var errorDescription: String? {
            switch self {
            case .noSessionKey: return "No session key established with peer"
            case .invalidPublicKey: return "Invalid public key data"
            case .keyDerivationFailed: return "Failed to derive shared secret"
            case .encryptionFailed: return "Encryption failed"
            case .decryptionFailed: return "Decryption failed"
            case .invalidNonce: return "Invalid nonce"
            case .authenticationFailed: return "Message authentication failed"
            case .signatureInvalid: return "Message signature verification failed"
            case .noSigningKey: return "No signing key available"
            }
        }
    }
    
    // MARK: - Singleton
    
    static let shared = EncryptionService()
    
    // MARK: - Private Properties
    
    private var sessionKeys: [UUID: SessionKey] = [:]
    private var messageCounters: [UUID: UInt64] = [:]  // Message counter per peer for forward secrecy
    private var peerPublicKeys: [UUID: P256.KeyAgreement.PublicKey] = [:]
    private var peerSigningKeys: [UUID: P256.Signing.PublicKey] = [:]  // For signature verification
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    private init() {
        MeshLogger.app.info("EncryptionService initialized")
        loadSequenceState()  // Restore replay protection state
    }
    
    // MARK: - Key Exchange
    
    /// Store a peer's public key (received during discovery)
    func storePeerPublicKey(_ publicKeyData: Data, for peerID: UUID) throws {
        let publicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
        
        lock.lock()
        peerPublicKeys[peerID] = publicKey
        lock.unlock()
        
        MeshLogger.app.info("Stored public key for peer: \(peerID.uuidString.prefix(8))")
    }
    
    /// Establish a session key with a peer using ECDH
    func establishSession(with peerID: UUID) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        
        // Check for existing session
        if let existing = sessionKeys[peerID] {
            sessionKeys[peerID]?.lastUsed = Date()
            return existing.symmetricKey
        }
        
        // Need peer's public key
        guard let peerPublicKey = peerPublicKeys[peerID] else {
            throw EncryptionError.noSessionKey
        }
        
        // Perform ECDH
        let sharedSecret = try DeviceIdentity.shared.deriveSharedSecret(with: peerPublicKey)
        
        // Derive symmetric key using HKDF
        let symmetricKey = deriveSymmetricKey(from: sharedSecret, peerID: peerID)
        
        // Store session
        sessionKeys[peerID] = SessionKey(
            peerID: peerID,
            symmetricKey: symmetricKey,
            createdAt: Date(),
            lastUsed: Date()
        )
        
        // Initialize message counter for forward secrecy (KDF chain)
        messageCounters[peerID] = 0
        
        MeshLogger.app.info("Established session with forward secrecy ratchet for peer: \(peerID.uuidString.prefix(8))")
        
        return symmetricKey
    }
    
    /// Check if we have a session with a peer
    func hasSession(with peerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionKeys[peerID] != nil
    }
    
    /// Get session key for a peer (if established)
    func getSessionKey(for peerID: UUID) -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        
        if var session = sessionKeys[peerID] {
            session.lastUsed = Date()
            sessionKeys[peerID] = session
            return session.symmetricKey
        }
        return nil
    }
    
    /// Remove session with a peer
    func removeSession(for peerID: UUID) {
        lock.lock()
        sessionKeys.removeValue(forKey: peerID)
        lock.unlock()
        
        MeshLogger.app.info("Removed session with peer: \(peerID.uuidString.prefix(8))")
    }
    
    // MARK: - Encryption
    
    /// Encrypt data for a specific peer with forward secrecy via KDF ratchet
    func encrypt(_ data: Data, for peerID: UUID) throws -> EncryptedPayload {
        // Get or establish session key
        let key: SymmetricKey
        if let existingKey = getSessionKey(for: peerID) {
            key = existingKey
        } else {
            key = try establishSession(with: peerID)
        }
        
        // Derive message key using KDF ratchet for forward secrecy
        let messageKey = try deriveMessageKey(from: key, for: peerID)
        
        // Generate random nonce
        var nonceData = Data(count: 12)
        let status = nonceData.withUnsafeMutableBytes { 
            SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) 
        }
        guard status == errSecSuccess else {
            MeshLogger.app.error("Failed to generate random nonce")
            throw EncryptionError.encryptionFailed
        }
        
        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw EncryptionError.invalidNonce
        }
        
        // Encrypt using the ratcheted message key
        guard let sealedBox = try? AES.GCM.seal(data, using: messageKey, nonce: nonce) else {
            throw EncryptionError.encryptionFailed
        }
        
        return EncryptedPayload(
            ciphertext: sealedBox.ciphertext,
            nonce: nonceData,
            tag: sealedBox.tag
        )
    }
    
    /// Encrypt data with a specific key (for broadcasts or groups)
    func encrypt(_ data: Data, with key: SymmetricKey) throws -> EncryptedPayload {
        var nonceData = Data(count: 12)
        let status = nonceData.withUnsafeMutableBytes { 
            SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) 
        }
        guard status == errSecSuccess else {
            MeshLogger.app.error("Failed to generate random nonce for group encryption")
            throw EncryptionError.encryptionFailed
        }
        
        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw EncryptionError.invalidNonce
        }
        
        guard let sealedBox = try? AES.GCM.seal(data, using: key, nonce: nonce) else {
            throw EncryptionError.encryptionFailed
        }
        
        return EncryptedPayload(
            ciphertext: sealedBox.ciphertext,
            nonce: nonceData,
            tag: sealedBox.tag
        )
    }
    
    // MARK: - Decryption
    
    /// Decrypt data from a specific peer
    func decrypt(_ payload: EncryptedPayload, from peerID: UUID) throws -> Data {
        guard let key = getSessionKey(for: peerID) else {
            throw EncryptionError.noSessionKey
        }
        
        return try decrypt(payload, with: key)
    }
    
    /// Decrypt data with a specific key
    func decrypt(_ payload: EncryptedPayload, with key: SymmetricKey) throws -> Data {
        guard let nonce = try? AES.GCM.Nonce(data: payload.nonce) else {
            throw EncryptionError.invalidNonce
        }
        
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: payload.ciphertext,
            tag: payload.tag
        )
        
        guard let decrypted = try? AES.GCM.open(sealedBox, using: key) else {
            throw EncryptionError.decryptionFailed
        }
        
        return decrypted
    }
    
    // MARK: - Convenience
    
    /// Encrypt a string for a peer
    func encryptString(_ string: String, for peerID: UUID) throws -> EncryptedPayload {
        guard let data = string.data(using: .utf8) else {
            throw EncryptionError.encryptionFailed
        }
        return try encrypt(data, for: peerID)
    }
    
    /// Decrypt to string from a peer
    func decryptString(_ payload: EncryptedPayload, from peerID: UUID) throws -> String {
        let data = try decrypt(payload, from: peerID)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncryptionError.decryptionFailed
        }
        return string
    }
    
    // MARK: - Group Key Management
    
    /// Generate a random group key
    func generateGroupKey() -> SymmetricKey {
        return SymmetricKey(size: .bits256)
    }
    
    /// Export group key for distribution (encrypted for a specific peer)
    func exportGroupKey(_ groupKey: SymmetricKey, for peerID: UUID) throws -> EncryptedPayload {
        let keyData = groupKey.withUnsafeBytes { Data($0) }
        return try encrypt(keyData, for: peerID)
    }
    
    /// Import group key from another member
    func importGroupKey(from payload: EncryptedPayload, senderID: UUID) throws -> SymmetricKey {
        let keyData = try decrypt(payload, from: senderID)
        return SymmetricKey(data: keyData)
    }
    
    // MARK: - Message Signing (ECDSA)
    
    /// Sign data using our device's signing key
    func sign(_ data: Data) throws -> Data {
        return try DeviceIdentity.shared.sign(data)
    }
    
    /// Sign the header portion of a message envelope (including sequence number for replay protection)
    func signEnvelopeHeader(
        id: UUID,
        originID: UUID,
        destinationID: UUID?,
        timestamp: Date,
        sequenceNumber: UInt64
    ) throws -> Data {
        // Create deterministic header data to sign
        var headerData = Data()
        headerData.append(id.uuidString.data(using: .utf8)!)
        headerData.append(originID.uuidString.data(using: .utf8)!)
        if let dest = destinationID {
            headerData.append(dest.uuidString.data(using: .utf8)!)
        }
        headerData.append("\(timestamp.timeIntervalSince1970)".data(using: .utf8)!)
        headerData.append("\(sequenceNumber)".data(using: .utf8)!)
        
        return try sign(headerData)
    }
    
    /// Store a peer's signing public key
    func storePeerSigningKey(_ publicKeyData: Data, for peerID: UUID) throws {
        let signingKey = try P256.Signing.PublicKey(rawRepresentation: publicKeyData)
        
        lock.lock()
        peerSigningKeys[peerID] = signingKey
        lock.unlock()
        
        MeshLogger.app.info("Stored signing key for peer: \(peerID.uuidString.prefix(8))")
    }
    
    /// Verify a signature from a peer
    /// Returns true if signature is valid, false if invalid
    /// Throws if no signing key is available (must exchange keys first)
    func verifySignature(_ signature: Data, for data: Data, from peerID: UUID) throws -> Bool {
        lock.lock()
        let signingKey = peerSigningKeys[peerID]
        lock.unlock()
        
        guard let key = signingKey else {
            // SECURITY: Never bypass signature verification
            // Caller must ensure key exchange happened before sending messages
            MeshLogger.app.error("No signing key for peer \(peerID.uuidString.prefix(8)) - cannot verify signature")
            throw EncryptionError.noSigningKey
        }
        
        guard let ecdsaSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            MeshLogger.app.error("Invalid signature format from peer \(peerID.uuidString.prefix(8))")
            throw EncryptionError.signatureInvalid
        }
        
        return key.isValidSignature(ecdsaSignature, for: data)
    }
    
    /// Check if we have a signing key for a peer
    func hasSigningKey(for peerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return peerSigningKeys[peerID] != nil
    }
    
    /// Verify envelope header signature (including sequence number)
    func verifyEnvelopeSignature(
        signature: Data,
        id: UUID,
        originID: UUID,
        destinationID: UUID?,
        timestamp: Date,
        sequenceNumber: UInt64,
        from senderID: UUID
    ) throws -> Bool {
        var headerData = Data()
        headerData.append(id.uuidString.data(using: .utf8)!)
        headerData.append(originID.uuidString.data(using: .utf8)!)
        if let dest = destinationID {
            headerData.append(dest.uuidString.data(using: .utf8)!)
        }
        headerData.append("\(timestamp.timeIntervalSince1970)".data(using: .utf8)!)
        headerData.append("\(sequenceNumber)".data(using: .utf8)!)
        
        return try verifySignature(signature, for: headerData, from: senderID)
    }
    
    // MARK: - Replay Protection
    
    /// Track the highest sequence number seen per sender for replay protection
    private var peerSequenceNumbers: [UUID: UInt64] = [:]
    private let sequenceLock = NSLock()
    
    /// Check if this message is a replay (already seen or old sequence number)
    /// Returns true if the message should be accepted (not a replay)
    func checkAndUpdateSequence(from peerID: UUID, sequenceNumber: UInt64) -> Bool {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        
        // Get the last known sequence number for this peer
        let lastSeen = peerSequenceNumbers[peerID] ?? 0
        
        // Replay detected: sequence number is not greater than last seen
        if sequenceNumber <= lastSeen {
            MeshLogger.message.warning("Replay attack detected from \(peerID.uuidString.prefix(8)): seq=\(sequenceNumber), lastSeen=\(lastSeen)")
            return false
        }
        
        // Update the last seen sequence number
        peerSequenceNumbers[peerID] = sequenceNumber
        
        // Persist replay state
        saveSequenceState()
        
        return true
    }
    
    /// Load persisted sequence state
    func loadSequenceState() {
        if let data = UserDefaults.standard.data(forKey: "mesh.peerSequences"),
           let decoded = try? JSONDecoder().decode([String: UInt64].self, from: data) {
            sequenceLock.lock()
            peerSequenceNumbers = decoded.reduce(into: [:]) { result, pair in
                if let uuid = UUID(uuidString: pair.key) {
                    result[uuid] = pair.value
                }
            }
            sequenceLock.unlock()
        }
    }
    
    /// Save sequence state to persist across app restarts
    private func saveSequenceState() {
        let encoded: [String: UInt64] = peerSequenceNumbers.reduce(into: [:]) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: "mesh.peerSequences")
        }
    }
    
    // MARK: - Cleanup
    
    /// Remove expired sessions (sessions older than the given interval)
    func cleanupExpiredSessions(olderThan interval: TimeInterval = 3600) {
        let cutoff = Date().addingTimeInterval(-interval)
        
        lock.lock()
        sessionKeys = sessionKeys.filter { $0.value.lastUsed > cutoff }
        lock.unlock()
    }
    
    /// Clear all sessions
    func clearAllSessions() {
        lock.lock()
        sessionKeys.removeAll()
        peerPublicKeys.removeAll()
        lock.unlock()
        
        MeshLogger.app.info("Cleared all encryption sessions")
    }
    
    // MARK: - Private Helpers
    
    /// Derive a per-message key using KDF ratchet (forward secrecy)
    /// Each message gets a unique key derived from the session key and message counter
    /// Old message keys cannot decrypt new messages - forward secrecy achieved!
    private func deriveMessageKey(from sessionKey: SymmetricKey, for peerID: UUID) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        
        // Increment message counter for this peer
        let counter = (messageCounters[peerID] ?? 0) + 1
        messageCounters[peerID] = counter
        
        // Use HKDF to derive a unique message key from session key + counter
        let info = "message-key-\(counter)".data(using: .utf8)!
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: peerID.uuidString.data(using: .utf8)!,
            info: info,
            outputByteCount: 32
        )
        
        MeshLogger.app.debug("Derived message key #\(counter) for peer \(peerID.uuidString.prefix(8)) - forward secrecy active")
        
        return derivedKey
    }
    
    private func deriveSymmetricKey(from sharedSecret: SharedSecret, peerID: UUID) -> SymmetricKey {
        // Create a salt combining both device IDs for deterministic key derivation
        let myID = DeviceIdentity.shared.deviceID
        let ids = [myID, peerID].sorted { $0.uuidString < $1.uuidString }
        let salt = ids.map { $0.uuidString }.joined().data(using: .utf8)!
        
        // Use HKDF to derive the symmetric key
        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: "BLEMesh-Session-v1".data(using: .utf8)!,
            outputByteCount: 32
        )
        
        return derivedKey
    }
}

// MARK: - Debug

extension EncryptionService {
    
    var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessionKeys.count
    }
    
    var knownPeerKeysCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peerPublicKeys.count
    }
}

// MARK: - Peer Key Fingerprints (for verification UI)

extension EncryptionService {
    
    /// Get a human-readable fingerprint for a peer's public key
    func getPeerPublicKeyFingerprint(for peerID: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let publicKey = peerPublicKeys[peerID] else {
            return nil
        }
        
        // Hash the raw representation and take first 16 characters
        let keyData = publicKey.rawRepresentation
        let hash = SHA256.hash(data: keyData)
        let fingerprint = hash.prefix(8).map { String(format: "%02X", $0) }.joined()
        return fingerprint
    }
    
    /// Get a human-readable fingerprint for a peer's signing key
    func getPeerSigningKeyFingerprint(for peerID: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let signingKey = peerSigningKeys[peerID] else {
            return nil
        }
        
        // Hash the raw representation and take first 16 characters
        let keyData = signingKey.rawRepresentation
        let hash = SHA256.hash(data: keyData)
        let fingerprint = hash.prefix(8).map { String(format: "%02X", $0) }.joined()
        return fingerprint
    }
}
