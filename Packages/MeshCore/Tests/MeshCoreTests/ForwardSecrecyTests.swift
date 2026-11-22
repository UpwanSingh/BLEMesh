import Foundation
import Testing
import CryptoKit
@testable import MeshCore
import MeshSimulator

@Suite("Forward secrecy (rotating prekeys)")
struct ForwardSecrecyTests {
    /// Captures the raw direct-message packets a node sends.
    final class Tap: MeshTransport {
        var packets: [Packet] = []
        func send(frames: [Data], over link: LinkID, priority: TrafficPriority) -> Bool {
            for frame in frames where frame.first == 0xA1 {
                if let packet = try? Packet.decode(frame.dropFirst()) { packets.append(packet) }
            }
            return true
        }
        func maximumFrameSize(for link: LinkID) -> Int { 4096 }
    }

    @Test func cryptoRoundTripAndModes() throws {
        let recipient = MeshIdentity(), sender = MeshIdentity().publicIdentity.signingKey
        let prekey = Curve25519.KeyAgreement.PrivateKey()
        let pub = PublicPrekey(id: 42, key: prekey.publicKey.rawRepresentation)
        let message = Data("forward secret".utf8)

        let sealed = try MeshCrypto.sealDirectMessage(message, to: recipient.publicIdentity.agreementKey, prekey: pub, from: sender)
        #expect(sealed.first == 2)
        #expect(try MeshCrypto.openDirectMessage(sealed, staticKey: recipient.agreementKey,
                                                 prekeyFor: { $0 == 42 ? prekey : nil }, from: sender) == message)
        // Without the prekey (deleted), the static key alone can't open it.
        #expect(throws: MeshCryptoError.decryptionFailed) {
            try MeshCrypto.openDirectMessage(sealed, staticKey: recipient.agreementKey, prekeyFor: { _ in nil }, from: sender)
        }
        // Without the static key, the prekey alone can't open it either.
        #expect(throws: MeshCryptoError.decryptionFailed) {
            try MeshCrypto.openDirectMessage(sealed, staticKey: MeshIdentity().agreementKey, prekeyFor: { _ in prekey }, from: sender)
        }
        // Bound to the sender.
        #expect(throws: MeshCryptoError.decryptionFailed) {
            try MeshCrypto.openDirectMessage(sealed, staticKey: recipient.agreementKey, prekeyFor: { _ in prekey },
                                             from: MeshIdentity().publicIdentity.signingKey)
        }
        // Fallback mode still works when no prekey is known.
        let fallback = try MeshCrypto.sealDirectMessage(message, to: recipient.publicIdentity.agreementKey, prekey: nil, from: sender)
        #expect(fallback.first == 1)
        #expect(try MeshCrypto.openDirectMessage(fallback, staticKey: recipient.agreementKey, prekeyFor: { _ in nil }, from: sender) == message)
        #expect(throws: MeshCryptoError.malformedCiphertext) {
            try MeshCrypto.openDirectMessage(Data([9, 1, 2]), staticKey: recipient.agreementKey, prekeyFor: { _ in nil }, from: sender)
        }
    }

    @Test func announcesCarryPrekeysAndOldAnnouncesStillDecode() throws {
        let identity = MeshIdentity()
        let withPrekey = AnnouncePayload(agreementKey: identity.publicIdentity.agreementKey, capabilities: [.onDeviceAI],
                                         nickname: "A", prekey: PublicPrekey(id: 7, key: Data(repeating: 3, count: 32)))
        #expect(try AnnouncePayload.decode(withPrekey.encode()) == withPrekey)
        let legacy = AnnouncePayload(agreementKey: identity.publicIdentity.agreementKey, capabilities: [], nickname: "B")
        #expect(try AnnouncePayload.decode(legacy.encode()).prekey == nil)
    }

    @Test func messagesUseThePrekeyAndBecomeUnreadableAfterItExpires() throws {
        var config = MeshConfig()
        config.prekeyRotation = 3600
        config.prekeyRetention = 2 * 3600
        let mesh = SimulatedMesh()
        mesh.addNode("A", config: config); mesh.addNode("B", config: config)
        mesh.connect("A", "B")
        mesh.run(for: 3)
        let a = mesh.node("A"), b = mesh.node("B")
        #expect(a.peer(b.peerID)?.prekey?.id == b.livePrekeyIDs.last)

        // Capture what A sends, as an eavesdropper on the radio would.
        let tap = Tap()
        let real = a.transport
        a.transport = tap
        _ = try a.sendDirect(.text("secret plan"), to: b.peerID)
        a.transport = real
        let captured = try #require(tap.packets.first { $0.type == .message })
        #expect(captured.payload.first == 2) // prekeyed mode

        // Right now B can read it.
        let openNow = try? MeshCrypto.openDirectMessage(captured.payload, staticKey: b.identity.agreementKey,
                                                        prekeyFor: { id in b.livePrekeyIDs.contains(id) ? Self.privatePrekey(of: b, id: id) : nil },
                                                        from: captured.originSigningKey)
        #expect(openNow != nil)

        // Hours later the prekey rotates out and is deleted. Even with *every* key B still has
        // (a full device compromise), the captured message stays unreadable.
        mesh.run(for: 3 * 3600)
        let usedID = captured.payload.dropFirst().prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(!b.livePrekeyIDs.contains(usedID))
        let snapshot = b.snapshot()
        let stolenKeys = (snapshot.ownPrekeys ?? []).compactMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0.privateKey) }
        for key in stolenKeys {
            #expect(throws: MeshCryptoError.decryptionFailed) {
                try MeshCrypto.openDirectMessage(captured.payload, staticKey: b.identity.agreementKey,
                                                 prekeyFor: { _ in key }, from: captured.originSigningKey)
            }
        }
    }

    @Test func messagesInFlightAcrossARotationStillArrive() throws {
        var config = MeshConfig()
        config.prekeyRotation = 600
        config.prekeyRetention = 7200
        let mesh = SimulatedMesh()
        for n in ["A", "M", "B"] { mesh.addNode(n, config: config) }
        mesh.chain(["A", "M", "B"])
        mesh.run(for: 8)
        let b = mesh.node("B")
        mesh.disconnect("M", "B")
        mesh.run(for: 100)
        let id = try mesh.node("A").sendDirect(.text("sent before rotation"), to: b.peerID)
        mesh.run(for: 1200) // B rotates (twice) while the message is carried
        #expect(b.livePrekeyIDs.count >= 2)
        mesh.connect("M", "B")
        #expect(mesh.run(until: { mesh.recorder("B").texts().contains("sent before rotation") }, timeout: 30))
        #expect(mesh.run(until: { mesh.node("A").outgoingStatus(id) == .delivered }, timeout: 30))
    }

    @Test func prekeysSurviveRestartSoQueuedMessagesStillOpen() throws {
        let mesh = SimulatedMesh()
        mesh.addNode("A"); mesh.addNode("B")
        mesh.connect("A", "B")
        mesh.run(for: 3)
        let b = mesh.node("B")
        let saved = try JSONEncoder().encode(b.snapshot())
        mesh.disconnect("A", "B")
        let id = try mesh.node("A").sendDirect(.text("to the old prekey"), to: b.peerID)

        // B restarts (same identity, restored state) and comes back.
        let b2 = mesh.addNode("B2", identity: b.identity)
        b2.restore(try JSONDecoder().decode(MeshNodeSnapshot.self, from: saved))
        #expect(b2.livePrekeyIDs.contains(b.livePrekeyIDs.last!))
        mesh.connect("A", "B2")
        #expect(mesh.run(until: { mesh.recorder("B2").texts().contains("to the old prekey") }, timeout: 20))
        #expect(mesh.run(until: { mesh.node("A").outgoingStatus(id) == .delivered }, timeout: 20))
    }

    @Test func unknownPrekeyFallsBackToStaticKey() throws {
        let mesh = SimulatedMesh()
        mesh.addNode("A"); mesh.addNode("B")
        let b = mesh.node("B")
        // A knows B only from an old contact record without a prekey.
        let pub = b.identity.publicIdentity
        mesh.node("A").restore(MeshNodeSnapshot(outgoing: [], groups: [], peers: [
            .init(signingKey: pub.signingKey, agreementKey: pub.agreementKey, nickname: "B", capabilities: 0, lastSeen: mesh.now)
        ], leftGroups: nil))
        let tap = Tap()
        mesh.node("A").transport = tap
        mesh.node("A").linkDidConnect(LinkID("A->X"))
        _ = try mesh.node("A").sendDirect(.text("hello"), to: b.peerID)
        #expect(tap.packets.first { $0.type == .message }?.payload.first == 1)
    }

    static func privatePrekey(of node: MeshNode, id: UInt32) -> Curve25519.KeyAgreement.PrivateKey? {
        node.snapshot().ownPrekeys?.first { $0.id == id }.flatMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0.privateKey) }
    }
}
