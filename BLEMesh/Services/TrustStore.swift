import Foundation
import Security
import MeshCore

/// Local trust decisions about other devices: verified (QR / safety number), blocked, reported.
/// Also holds the user's medical ID (Keychain, this device only).
@MainActor
final class TrustStore: ObservableObject {
    @Published private(set) var verified: Set<PeerID> = []
    @Published private(set) var blocked: Set<PeerID> = []
    @Published private(set) var reported: Set<PeerID> = []
    @Published var medical: MedicalInfo {
        didSet { Self.saveMedical(medical, account: medicalAccount) }
    }

    private let defaults: UserDefaults
    private let medicalAccount: String
    private enum Keys {
        static let verified = "trust.verified"
        static let blocked = "trust.blocked"
        static let reported = "trust.reported"
    }

    init(defaults: UserDefaults = .standard, medicalAccount: String = "medical") {
        self.defaults = defaults
        self.medicalAccount = medicalAccount
        self.medical = Self.loadMedical(account: medicalAccount) ?? MedicalInfo()
        verified = Self.load(Keys.verified, from: defaults)
        blocked = Self.load(Keys.blocked, from: defaults)
        reported = Self.load(Keys.reported, from: defaults)
    }

    func isVerified(_ peer: PeerID) -> Bool { verified.contains(peer) }
    func isBlocked(_ peer: PeerID) -> Bool { blocked.contains(peer) }

    func setVerified(_ peer: PeerID, _ value: Bool) {
        if value { verified.insert(peer) } else { verified.remove(peer) }
        save(verified, Keys.verified)
    }

    func setBlocked(_ peer: PeerID, _ value: Bool) {
        if value { blocked.insert(peer) } else { blocked.remove(peer) }
        save(blocked, Keys.blocked)
    }

    /// Reporting also blocks: you never see that device again on this phone.
    func report(_ peer: PeerID) {
        reported.insert(peer)
        save(reported, Keys.reported)
        setBlocked(peer, true)
    }

    func wipe() {
        verified = []; blocked = []; reported = []
        for key in [Keys.verified, Keys.blocked, Keys.reported] { defaults.removeObject(forKey: key) }
        medical = MedicalInfo()
        SecItemDelete(Self.medicalQuery(medicalAccount) as CFDictionary)
    }

    // MARK: - QR verification

    /// Payload of the "verify me" QR code: scheme, version, mesh ID, and full safety-number hash.
    static func verificationCode(for identity: PublicIdentity) -> String {
        "blemesh:v1:\(identity.peerID.hex):\(identity.fingerprint.replacingOccurrences(of: " ", with: ""))"
    }

    enum VerificationResult: Equatable {
        case verified(PeerID)
        /// The code is valid but belongs to a different device than the one being verified.
        case mismatch
        /// The code's ID is right but its keys don't match what this phone knows (possible impersonation).
        case keyMismatch
        case invalid
        case unknownDevice
    }

    /// Check a scanned/entered code against what the mesh knows about `expected`.
    static func check(code: String, expected: PeerID, known: PeerInfo?) -> VerificationResult {
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        guard parts.count == 4, parts[0] == "blemesh", parts[1] == "v1", let peer = PeerID(hex: parts[2]) else { return .invalid }
        guard peer == expected else { return .mismatch }
        guard let known else { return .unknownDevice }
        let expectedPrint = known.identity.fingerprint.replacingOccurrences(of: " ", with: "")
        return parts[3].uppercased() == expectedPrint ? .verified(peer) : .keyMismatch
    }

    // MARK: - Persistence

    private func save(_ set: Set<PeerID>, _ key: String) {
        defaults.set(set.map(\.hex).sorted(), forKey: key)
    }

    private static func load(_ key: String, from defaults: UserDefaults) -> Set<PeerID> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(PeerID.init(hex:)))
    }

    private static func medicalQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.noxrail.blemesh.medical",
         kSecAttrAccount as String: account]
    }

    private static func loadMedical(account: String) -> MedicalInfo? {
        var query = medicalQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(MedicalInfo.self, from: data)
    }

    private static func saveMedical(_ info: MedicalInfo, account: String) {
        SecItemDelete(medicalQuery(account) as CFDictionary)
        guard !info.isEmpty, let data = try? JSONEncoder().encode(info) else { return }
        var query = medicalQuery(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}

extension MeshService {
    /// Name to show for a peer: their nickname, disambiguated with a short ID when another known
    /// device uses the same name, so nobody can pass as someone else just by copying a name.
    func uniqueName(for peer: PeerID) -> String {
        let name = displayName(for: peer)
        let clash = peers.contains { $0.peerID != peer && $0.nickname.caseInsensitiveCompare(name) == .orderedSame }
            || (peer != myPeerID && name.caseInsensitiveCompare(nickname) == .orderedSame)
        return clash ? "\(name) · \(peer.short.prefix(4))" : name
    }

    /// True when this unverified device uses the same name as a contact you've verified.
    func impersonatesVerifiedContact(_ peer: PeerID) -> Bool {
        guard !trust.isVerified(peer) else { return false }
        let name = displayName(for: peer)
        return trust.verified.contains { $0 != peer && displayName(for: $0).caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Brand-new identities (first seen minutes ago) — their SOS calls are flagged, since fake
    /// identities are free to create.
    func isNewDevice(_ peer: PeerID, now: Date = Date()) -> Bool {
        guard let firstSeen = peerInfo(peer)?.firstSeen else { return false }
        return now.timeIntervalSince(firstSeen) < 10 * 60
    }
}
