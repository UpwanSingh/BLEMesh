import Foundation
import SwiftData
import Testing
import UIKit
import MeshCore
@testable import BLEMesh

/// Phase 1 app features against the demo mesh: SOS status, check-ins, medical ID, trust
/// (verification, blocking, name spoofing), battery, and group admin.
@MainActor
@Suite("Phase 1 features (demo mesh)", .serialized)
struct Phase1ServiceTests {
    func makeService() -> MeshService {
        let suite = "tests.\(UUID().uuidString)"
        let trust = TrustStore(defaults: UserDefaults(suiteName: suite)!, medicalAccount: suite)
        return MeshService(mode: .demo, container: PersistenceController.makeContainer(inMemory: true),
                           settings: AppSettings(defaults: UserDefaults(suiteName: suite)!), trust: trust,
                           ai: MockAI(generative: false), persistSnapshot: false)
    }

    func eventually(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    func messages(_ service: MeshService, _ key: String) -> [StoredMessage] {
        let descriptor = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationKey == key }, sortBy: [SortDescriptor(\.sentAt)])
        return (try? service.context.fetch(descriptor)) ?? []
    }

    func peer(_ service: MeshService, _ name: String) -> PeerInfo? {
        service.peers.first { $0.nickname == name && $0.isReachable }
    }

    // MARK: SOS status

    @Test func myOwnSOSGetsARespondersStatusAndICanCloseIt() async throws {
        let service = makeService()
        #expect(await eventually { peer(service, "Asha") != nil })
        _ = await service.sendSOS(text: "Stuck in the lift", location: nil)
        let sos = try #require(messages(service, ConversationKey.nearby).last { if case .sos = $0.content { return true }; return false })
        #expect(service.sosState(for: sos).status == .open)
        #expect(await eventually { service.sosState(for: sos).status == .enRoute })
        let state = service.sosState(for: sos)
        #expect(state.responders.first.map { service.displayName(for: $0.peer) } == "Asha")
        #expect(state.responders.first?.note == "Coming from the market")
        service.sendSOSUpdate(sosID: sos.id, status: .resolved)
        #expect(service.sosState(for: sos).status == .resolved)
        #expect(service.sosState(for: sos).closedBySender)
    }

    @Test func respondingToSomeoneElsesSOS() async throws {
        let service = makeService()
        // Meera's scripted SOS arrives at ~14 s.
        #expect(await eventually(30) { messages(service, ConversationKey.nearby).contains { if case .sos = $0.content { return !$0.isOutgoing }; return false } })
        let sos = try #require(messages(service, ConversationKey.nearby).first { if case .sos = $0.content { return !$0.isOutgoing }; return false })
        #expect(service.sendSOSUpdate(sosID: sos.id, status: .enRoute, note: "on my way"))
        let state = service.sosState(for: sos)
        #expect(state.status == .enRoute)
        #expect(state.responders.contains { $0.peer == service.myPeerID })
        // Someone else's "resolved" alone doesn't close it.
        service.sendSOSUpdate(sosID: sos.id, status: .resolved)
        #expect(service.sosState(for: sos).status != .resolved)
    }

    @Test func medicalIDIsAttachedOnlyWhenChosen() async throws {
        let service = makeService()
        service.trust.medical = MedicalInfo(bloodType: "O+", allergies: "penicillin")
        _ = await service.sendSOS(text: "first", location: nil)
        _ = await service.sendSOS(text: "second", location: nil, includeMedical: true)
        let reports = messages(service, ConversationKey.nearby).compactMap { m -> SOSReport? in
            if case .sos(let r)? = m.content { return r }
            return nil
        }
        #expect(reports.first { $0.text == "first" }?.medical == nil)
        #expect(reports.first { $0.text == "second" }?.medical?.bloodType == "O+")
    }

    // MARK: Check-ins & family

    @Test func askingAreYouSafeFillsTheFamilyLocator() async throws {
        let service = makeService()
        #expect(await eventually { peer(service, "Asha") != nil && peer(service, "Meera") != nil })
        let key = try #require(service.createGroup(name: "Family", members: [peer(service, "Asha")!.peerID, peer(service, "Meera")!.peerID]))
        #expect(await eventually { messages(service, key).contains { $0.senderName == "Meera" } })
        #expect(service.askAreYouSafe(groupKey: key))
        #expect(await eventually {
            let entries = service.familyEntries(groupKey: key)
            return entries.filter { $0.checkIn != nil }.count == 2
        })
        let entries = service.familyEntries(groupKey: key)
        #expect(entries.first.map { service.displayName(for: $0.member) } == "Meera") // needs help sorts first
        #expect(entries.first?.checkIn?.status == .needHelp)
        #expect(entries.first?.checkIn?.batteryPercent == 12)
        #expect(entries.contains { service.displayName(for: $0.member) == "Asha" && $0.checkIn?.status == .safe })

        // My own check-in reaches the group and shows up for me too.
        #expect(service.sendCheckIn(.safe, note: "home") == 1)
        #expect(service.familyEntries(groupKey: key).contains { $0.member == service.myPeerID && $0.checkIn?.note == "home" })
    }

    @Test func checkInWithNoGroupsSendsNothing() {
        let service = makeService()
        #expect(service.sendCheckIn(.safe) == 0)
    }

    // MARK: Trust

    @Test func verificationCodesMatchOnlyTheRightDeviceAndKeys() async throws {
        let service = makeService()
        #expect(await eventually { peer(service, "Asha") != nil })
        let asha = try #require(peer(service, "Asha"))
        let code = TrustStore.verificationCode(for: asha.identity)
        #expect(TrustStore.check(code: code, expected: asha.peerID, known: asha) == .verified(asha.peerID))
        #expect(TrustStore.check(code: TrustStore.verificationCode(for: service.node.identity.publicIdentity),
                                 expected: asha.peerID, known: asha) == .mismatch)
        let tampered = code.dropLast(4) + "0000"
        #expect(TrustStore.check(code: String(tampered), expected: asha.peerID, known: asha) == .keyMismatch)
        #expect(TrustStore.check(code: "hello", expected: asha.peerID, known: asha) == .invalid)
        #expect(TrustStore.check(code: code, expected: asha.peerID, known: nil) == .unknownDevice)
    }

    @Test func blockedDevicesAreInvisible() async throws {
        let service = makeService()
        #expect(await eventually { peer(service, "Asha") != nil })
        let asha = try #require(peer(service, "Asha"))
        service.trust.setBlocked(asha.peerID, true)
        let key = service.startDirectConversation(with: asha)
        service.sendText("hello?", to: key)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(!messages(service, key).contains { !$0.isOutgoing })
        service.trust.report(asha.peerID)
        #expect(service.trust.reported.contains(asha.peerID))
        service.trust.setBlocked(asha.peerID, false)
        service.sendText("back?", to: key)
        #expect(await eventually { messages(service, key).contains { !$0.isOutgoing } })
    }

    @Test func lookalikeNamesAreDisambiguatedAndFlagged() async throws {
        let service = makeService()
        #expect(await eventually { peer(service, "Asha") != nil })
        let realAsha = try #require(peer(service, "Asha"))
        // An impostor using the same display name.
        let impostor = MeshIdentity().publicIdentity
        service.node.restore(MeshNodeSnapshot(outgoing: [], groups: [], peers: [
            .init(signingKey: impostor.signingKey, agreementKey: impostor.agreementKey, nickname: "Asha", capabilities: 0, lastSeen: Date())
        ], leftGroups: nil))
        service.refreshPeers()
        #expect(service.uniqueName(for: realAsha.peerID).hasPrefix("Asha · "))
        #expect(service.uniqueName(for: impostor.peerID).hasPrefix("Asha · "))
        #expect(service.uniqueName(for: realAsha.peerID) != service.uniqueName(for: impostor.peerID))
        #expect(!service.impersonatesVerifiedContact(impostor.peerID))
        service.trust.setVerified(realAsha.peerID, true)
        #expect(service.impersonatesVerifiedContact(impostor.peerID))
        #expect(!service.impersonatesVerifiedContact(realAsha.peerID))
        #expect(service.uniqueName(for: peer(service, "Kabir")!.peerID) == "Kabir")
    }

    @Test func brandNewIdentitiesAreFlagged() async throws {
        let service = makeService()
        #expect(await eventually { peer(service, "Asha") != nil })
        let asha = try #require(peer(service, "Asha"))
        #expect(service.isNewDevice(asha.peerID))
        #expect(!service.isNewDevice(asha.peerID, now: Date().addingTimeInterval(11 * 60)))
    }

    // MARK: Battery

    @Test func batteryLevelDrivesRelayPowerState() {
        let service = makeService()
        service.updatePowerState(level: 0.8, state: .unplugged)
        #expect(service.node.powerState == .normal)
        service.updatePowerState(level: 0.15, state: .unplugged)
        #expect(service.node.powerState == .low)
        #expect(service.batteryPercent == 15)
        service.updatePowerState(level: 0.05, state: .unplugged)
        #expect(service.node.powerState == .critical)
        service.updatePowerState(level: 0.05, state: .charging)
        #expect(service.node.powerState == .normal)
        service.updatePowerState(level: -1, state: .unknown)
        #expect(service.node.powerState == .normal)
    }

    // MARK: Group admin

    @Test func adminRemovesAMemberAndTheKeyChanges() async throws {
        let service = makeService()
        #expect(await eventually { peer(service, "Asha") != nil && peer(service, "Kabir") != nil })
        let asha = try #require(peer(service, "Asha")), kabir = try #require(peer(service, "Kabir"))
        let key = try #require(service.createGroup(name: "Team", members: [asha.peerID, kabir.peerID]))
        #expect(service.isGroupAdmin(groupKey: key))
        let before = service.group(for: key)?.key
        service.removeMember(asha.peerID, groupKey: key)
        #expect(service.group(for: key)?.members.contains(asha.peerID) == false)
        #expect(service.group(for: key)?.key != before)
        #expect(messages(service, key).contains { $0.previewText.contains("You removed Asha") })
    }

    @Test func panicWipeAlsoClearsTrustAndMedicalID() {
        let service = makeService()
        service.trust.medical = MedicalInfo(bloodType: "A+")
        service.trust.setVerified(MeshIdentity().peerID, true)
        service.panicWipe()
        #expect(service.trust.medical.isEmpty)
        #expect(service.trust.verified.isEmpty)
    }
}
