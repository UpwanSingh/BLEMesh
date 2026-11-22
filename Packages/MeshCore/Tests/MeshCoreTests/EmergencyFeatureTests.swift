import Foundation
import Testing
@testable import MeshCore
import MeshSimulator

@Suite("SOS status tracking")
struct SOSTrackerTests {
    let sos = UUID()
    let sender = MeshIdentity().peerID
    let r1 = MeshIdentity().peerID, r2 = MeshIdentity().peerID, r3 = MeshIdentity().peerID
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func u(_ from: PeerID, _ status: SOSStatus, _ dt: TimeInterval, note: String? = nil, sos: UUID? = nil) -> SOSTracker.Update {
        SOSTracker.Update(from: from, update: SOSUpdate(sosID: sos ?? self.sos, status: status, note: note), at: t0.addingTimeInterval(dt))
    }

    @Test func startsOpenAndFollowsResponders() {
        #expect(SOSTracker.state(sosID: sos, sender: sender, sentAt: t0, updates: []).status == .open)
        let s = SOSTracker.state(sosID: sos, sender: sender, sentAt: t0, updates: [
            u(r1, .acknowledged, 10), u(r2, .enRoute, 20, note: "5 min away"),
        ])
        #expect(s.status == .enRoute)
        #expect(s.responders.map(\.peer) == [r1, r2])
        #expect(s.responders.last?.note == "5 min away")
    }

    @Test func onlyTheSenderCanCloseAlone() {
        let claimed = SOSTracker.state(sosID: sos, sender: sender, sentAt: t0, updates: [u(r1, .resolved, 30)])
        #expect(claimed.status != .resolved)
        #expect(claimed.resolvedClaims == 1)
        let corroborated = SOSTracker.state(sosID: sos, sender: sender, sentAt: t0, updates: [u(r1, .resolved, 30), u(r2, .resolved, 40)])
        #expect(corroborated.status == .resolved)
        let bySender = SOSTracker.state(sosID: sos, sender: sender, sentAt: t0, updates: [u(r1, .enRoute, 10), u(sender, .resolved, 50)])
        #expect(bySender.status == .resolved)
        #expect(bySender.closedBySender)
        let cancelled = SOSTracker.state(sosID: sos, sender: sender, sentAt: t0, updates: [u(sender, .cancelled, 5)])
        #expect(cancelled.status == .cancelled)
    }

    @Test func latestUpdatePerResponderWinsAndForeignOrOldUpdatesAreIgnored() {
        let s = SOSTracker.state(sosID: sos, sender: sender, sentAt: t0, updates: [
            u(r1, .enRoute, 10), u(r1, .acknowledged, 5),     // out of order: latest (enRoute) wins
            u(r2, .enRoute, -60),                              // before the SOS was sent
            u(r3, .enRoute, 10, sos: UUID()),                  // about another SOS
            u(r3, .cancelled, 20),                             // a responder backing out
        ])
        #expect(s.responders.map(\.peer) == [r1])
        #expect(s.status == .enRoute)
    }
}

@Suite("Family locator")
struct FamilyLocatorTests {
    let a = MeshIdentity().peerID, b = MeshIdentity().peerID, c = MeshIdentity().peerID
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func latestCheckInPerMemberNeedsHelpFirst() {
        let entries = FamilyLocator.entries(members: [a, b, c], checkIns: [
            (a, CheckIn(status: .safe), now.addingTimeInterval(-600)),
            (b, CheckIn(status: .safe), now.addingTimeInterval(-300)),
            (b, CheckIn(status: .needHelp, note: "stuck"), now.addingTimeInterval(-60)),
            (MeshIdentity().peerID, CheckIn(status: .needHelp), now), // not in the family
        ], now: now)
        #expect(entries.map(\.member) == [b, c, a])
        #expect(entries[0].checkIn?.note == "stuck")
        #expect(entries[1].checkIn == nil && entries[1].isStale)
        #expect(entries[2].isStale == false)
    }

    @Test func oldCheckInsAreStale() {
        let entries = FamilyLocator.entries(members: [a], checkIns: [(a, CheckIn(status: .safe), now.addingTimeInterval(-7 * 3600))], now: now)
        #expect(entries[0].isStale)
    }
}

@Suite("Emergency content over the mesh")
struct EmergencyContentTests {
    @Test func checkInsAndSafetyChecksTravelInGroupsAndSOSCarriesMedicalInfo() throws {
        let mesh = SimulatedMesh()
        var config = MeshConfig()
        config.urgentWorkBits = 8
        for n in ["Mum", "Dad", "Kid"] { mesh.addNode(n, config: config) }
        mesh.chain(["Mum", "Dad", "Kid"])
        mesh.run(for: 6)
        let family = try mesh.node("Mum").createGroup(name: "Family", members: [mesh.node("Dad").peerID, mesh.node("Kid").peerID])
        _ = mesh.run(until: { mesh.node("Kid").groups[family.id] != nil }, timeout: 10)

        let check = SafetyCheck(note: "earthquake")
        _ = try mesh.node("Mum").sendGroup(.safetyCheck(check), groupID: family.id)
        mesh.run(for: 2)
        #expect(mesh.recorder("Kid").received.contains { $0.envelope.content == .safetyCheck(check) })

        let answer = CheckIn(status: .safe, location: GeoPoint(latitude: 1, longitude: 2), batteryPercent: 40, inReplyTo: check.requestID)
        _ = try mesh.node("Kid").sendGroup(.checkIn(answer), groupID: family.id)
        mesh.run(for: 2)
        #expect(mesh.recorder("Mum").received.contains { $0.envelope.content == .checkIn(answer) && $0.scope == .group(family.id) })

        let medical = MedicalInfo(bloodType: "O+", allergies: "penicillin")
        let sosID = try mesh.node("Kid").sendBroadcast(.sos(SOSReport(text: "fell down", medical: medical)))
        mesh.run(for: 2)
        let got = mesh.recorder("Mum").received.first { $0.envelope.messageID == sosID }
        guard case .sos(let report)? = got?.envelope.content else {
            Issue.record("SOS missing")
            return
        }
        #expect(report.medical == medical)

        _ = try mesh.node("Dad").sendBroadcast(.sosUpdate(SOSUpdate(sosID: sosID, status: .enRoute, note: "coming")))
        mesh.run(for: 2)
        #expect(mesh.recorder("Kid").received.contains { if case .sosUpdate(let u) = $0.envelope.content { return u.sosID == sosID }; return false })
    }

    @Test func medicalInfoHelpers() {
        #expect(MedicalInfo().isEmpty)
        #expect(MedicalInfo(bloodType: "  ").isEmpty)
        let info = MedicalInfo(bloodType: "AB-", medications: "insulin")
        #expect(!info.isEmpty)
        #expect(info.summaryLines == ["Blood type: AB-", "Medications: insulin"])
    }

    @Test func newContentKindsRoundTrip() throws {
        let contents: [MeshContent] = [
            .sosUpdate(SOSUpdate(sosID: UUID(), status: .resolved, note: "safe now")),
            .checkIn(CheckIn(status: .needHelp, location: GeoPoint(latitude: 3, longitude: 4), batteryPercent: 9, note: "hurt", inReplyTo: UUID())),
            .safetyCheck(SafetyCheck(note: "flood warning")),
            .sos(SOSReport(text: "x", medical: MedicalInfo(bloodType: "B+"))),
        ]
        for content in contents {
            let envelope = MessageEnvelope(sentAt: Date(timeIntervalSince1970: 1), senderName: "A", content: content)
            #expect(try MessageEnvelope.decode(envelope.encode()) == envelope)
            #expect(!content.previewText.isEmpty)
        }
    }
}
