import Foundation
import Testing
@testable import MeshCore

@Suite("Wire protocol")
struct ProtocolTests {
    let identity = MeshIdentity()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func peerIDDerivesFromSigningKeyAndRoundTripsHex() throws {
        let id = identity.peerID
        #expect(id == PeerID(signingKey: identity.publicIdentity.signingKey))
        #expect(PeerID(hex: id.hex) == id)
        #expect(id.hex.count == 32)
        #expect(!id.isBroadcast)
        #expect(PeerID.broadcast.isBroadcast)
        let json = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(PeerID.self, from: json) == id)
    }

    @Test func packetRoundTripsAndVerifies() throws {
        let packet = try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                                     payload: Data("hello".utf8), identity: identity, now: now)
        let decoded = try Packet.decode(packet.encode())
        #expect(decoded == packet)
        #expect(decoded.verify())
        #expect(decoded.origin == identity.peerID)
    }

    @Test func relayMutationsKeepSignatureValid() throws {
        var packet = try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                                     payload: Data("x".utf8), identity: identity, now: now)
        packet.ttl = 3
        packet.hops = 4
        #expect(try Packet.decode(packet.encode()).verify())
    }

    @Test func tamperingBreaksSignature() throws {
        let packet = try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                                     payload: Data("pay me".utf8), identity: identity, now: now)
        var tampered = packet
        tampered.payload = Data("pay you".utf8)
        #expect(!tampered.verify())

        var spoofedOrigin = packet
        spoofedOrigin.origin = MeshIdentity().peerID
        #expect(!spoofedOrigin.verify())

        var swappedKey = packet
        swappedKey.originSigningKey = MeshIdentity().publicIdentity.signingKey
        #expect(!swappedKey.verify())

        var flipped = packet
        flipped.flags = .directEncrypted
        #expect(!flipped.verify())
    }

    @Test func decodingRejectsGarbage() throws {
        let packet = try Packet.make(type: .ack, ttl: 7, destination: identity.peerID,
                                     payload: Data(repeating: 1, count: 33), identity: identity, now: now)
        let bytes = packet.encode()
        #expect(throws: WireError.truncated) { try Packet.decode(bytes.prefix(bytes.count - 1)) }
        #expect(throws: (any Error).self) { try Packet.decode(bytes + Data([0])) }
        var badVersion = bytes
        badVersion[0] = 99
        #expect(throws: WireError.unsupportedVersion(99)) { try Packet.decode(badVersion) }
        var badType = bytes
        badType[1] = 200
        #expect(throws: WireError.unknownType(200)) { try Packet.decode(badType) }
        #expect(throws: (any Error).self) { try Packet.decode(Data()) }
    }

    @Test func payloadSizeIsBounded() {
        #expect(throws: WireError.tooLarge) {
            try Packet.make(type: .message, ttl: 7, destination: .broadcast,
                            payload: Data(count: Packet.maxPayloadSize + 1), identity: identity, now: now)
        }
    }

    @Test func announceAndAckPayloadsRoundTrip() throws {
        let announce = AnnouncePayload(agreementKey: identity.publicIdentity.agreementKey,
                                       capabilities: [.onDeviceAI, .translation], nickname: "Asha’s iPhone 🚀")
        #expect(try AnnouncePayload.decode(announce.encode()) == announce)

        let ack = AckPayload(kind: .read, messageID: UUID(), ackedPacketID: UUID())
        #expect(try AckPayload.decode(ack.encode()) == ack)
    }

    @Test func longNicknamesAreTruncatedOnCharacterBoundary() throws {
        let long = String(repeating: "é", count: 300)
        let announce = AnnouncePayload(agreementKey: Data(count: 32), capabilities: [], nickname: long)
        let decoded = try AnnouncePayload.decode(announce.encode())
        #expect(Data(decoded.nickname.utf8).count <= 255)
        #expect(decoded.nickname.allSatisfy { $0 == "é" })
    }

    @Test func envelopeRoundTripsAllContentKinds() throws {
        let contents: [MeshContent] = [
            .text("hi"),
            .voice(VoiceNote(transcript: "on my way", languageCode: "en-US", durationSeconds: 2.5)),
            .sos(SOSReport(text: "help", location: GeoPoint(latitude: 28.6, longitude: 77.2), triage: HeuristicTriage.triage("fire"))),
            .groupInvite(GroupInvite(groupID: UUID(), name: "Family", members: [identity.peerID], key: MeshCrypto.makeGroupKey())),
            .groupLeave(groupID: UUID()),
            .aiQuery(AIQuery(prompt: "how to treat a burn?")),
            .aiResponse(AIResponse(queryID: UUID(), text: "cool water", answeredBy: "B")),
        ]
        for content in contents {
            let envelope = MessageEnvelope(sentAt: now, senderName: "A", content: content)
            #expect(try MessageEnvelope.decode(envelope.encode()) == envelope)
        }
    }

    @Test func fingerprintIsStableAndGrouped() {
        let fp = identity.publicIdentity.fingerprint
        #expect(fp == identity.publicIdentity.fingerprint)
        #expect(fp.split(separator: " ").count == 6)
    }
}

@Suite("Crypto")
struct CryptoTests {
    @Test func directSealOpensOnlyForRecipient() throws {
        let alice = MeshIdentity(), bob = MeshIdentity(), eve = MeshIdentity()
        let secret = Data("meet at the north gate".utf8)
        let sealed = try MeshCrypto.sealDirect(secret, to: bob.publicIdentity.agreementKey)
        #expect(try MeshCrypto.openDirect(sealed, with: bob.agreementKey) == secret)
        #expect(throws: MeshCryptoError.decryptionFailed) { try MeshCrypto.openDirect(sealed, with: eve.agreementKey) }
        #expect(throws: MeshCryptoError.decryptionFailed) { try MeshCrypto.openDirect(sealed, with: alice.agreementKey) }
        // Fresh ephemeral key per message: same plaintext never yields the same ciphertext.
        #expect(try MeshCrypto.sealDirect(secret, to: bob.publicIdentity.agreementKey) != sealed)
    }

    @Test func directSealDetectsTampering() throws {
        let bob = MeshIdentity()
        var sealed = try MeshCrypto.sealDirect(Data("x".utf8), to: bob.publicIdentity.agreementKey)
        sealed[sealed.count - 1] ^= 0xFF
        #expect(throws: MeshCryptoError.decryptionFailed) { try MeshCrypto.openDirect(sealed, with: bob.agreementKey) }
        #expect(throws: MeshCryptoError.malformedCiphertext) { try MeshCrypto.openDirect(Data(count: 10), with: bob.agreementKey) }
        #expect(throws: MeshCryptoError.invalidKey) { try MeshCrypto.sealDirect(Data(), to: Data(count: 5)) }
    }

    @Test func groupSealRequiresKeyAndBindsGroupID() throws {
        let key = MeshCrypto.makeGroupKey()
        let groupID = UUID()
        let sealed = try MeshCrypto.sealGroup(Data("hello group".utf8), groupID: groupID, key: key)
        #expect(MeshCrypto.groupID(ofSealed: sealed) == groupID)
        #expect(try MeshCrypto.openGroup(sealed, key: key) == Data("hello group".utf8))
        #expect(throws: MeshCryptoError.decryptionFailed) { try MeshCrypto.openGroup(sealed, key: MeshCrypto.makeGroupKey()) }

        // Re-labelling the ciphertext with another group ID fails authentication.
        var relabelled = sealed
        relabelled[0] ^= 0x01
        #expect(throws: MeshCryptoError.decryptionFailed) { try MeshCrypto.openGroup(relabelled, key: key) }
    }

    @Test func identityPersistsThroughRawKeys() throws {
        let original = MeshIdentity()
        let restored = try MeshIdentity(signingKeyData: original.signingKeyData, agreementKeyData: original.agreementKeyData)
        #expect(restored.peerID == original.peerID)
        #expect(restored.publicIdentity == original.publicIdentity)
    }
}

@Suite("Framing")
struct FramingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func smallPacketIsOneFrame() throws {
        let data = Data("tiny".utf8)
        let frames = Framing.frames(for: data, maxFrameSize: 182)
        #expect(frames.count == 1)
        #expect(try Reassembler().accept(frames[0], from: LinkID("l"), now: now) == data)
    }

    @Test func largePacketFragmentsWithinMTUAndReassemblesOutOfOrder() throws {
        let data = Data((0..<5000).map { UInt8($0 % 251) })
        let frames = Framing.frames(for: data, maxFrameSize: 64)
        #expect(frames.count > 1)
        #expect(frames.allSatisfy { $0.count <= 64 })
        let reassembler = Reassembler()
        var result: Data?
        for frame in frames.reversed() {
            if let done = try reassembler.accept(frame, from: LinkID("l"), now: now) { result = done }
        }
        #expect(result == data)
        #expect(reassembler.pendingCount == 0)
    }

    @Test func duplicateFragmentsAreIgnored() throws {
        let data = Data(repeating: 7, count: 400)
        let frames = Framing.frames(for: data, maxFrameSize: 100)
        let reassembler = Reassembler()
        _ = try reassembler.accept(frames[0], from: LinkID("l"), now: now)
        _ = try reassembler.accept(frames[0], from: LinkID("l"), now: now)
        var result: Data?
        for frame in frames.dropFirst() {
            if let done = try reassembler.accept(frame, from: LinkID("l"), now: now) { result = done }
        }
        #expect(result == data)
    }

    @Test func fragmentsFromDifferentLinksNeverMix() throws {
        // Two different packets that happen to share a fragment group ID, on two links.
        let a = Data(repeating: 0xAA, count: 300)
        let b = Data(repeating: 0xBB, count: 300)
        let framesA = Framing.frames(for: a, maxFrameSize: 100, groupID: 7)
        let framesB = Framing.frames(for: b, maxFrameSize: 100, groupID: 7)
        let reassembler = Reassembler()
        var outA: Data?, outB: Data?
        for (fa, fb) in zip(framesA, framesB) {
            if let d = try reassembler.accept(fa, from: LinkID("link-1"), now: now) { outA = d }
            if let d = try reassembler.accept(fb, from: LinkID("link-2"), now: now) { outB = d }
        }
        #expect(outA == a)
        #expect(outB == b)
    }

    @Test func malformedFramesAreRejected() {
        let reassembler = Reassembler()
        #expect(throws: (any Error).self) { try reassembler.accept(Data([0x00, 1, 2]), from: LinkID("l"), now: now) }
        #expect(throws: (any Error).self) { try reassembler.accept(Data(), from: LinkID("l"), now: now) }
        // index >= count
        var w = ByteWriter()
        w.u8(0xA2); w.u32(1); w.u16(5); w.u16(2); w.bytes(Data([1]))
        #expect(throws: (any Error).self) { try reassembler.accept(w.data, from: LinkID("l"), now: now) }
    }

    @Test func stalePartialsArePurgedAndLinkResetClears() throws {
        let frames = Framing.frames(for: Data(repeating: 1, count: 500), maxFrameSize: 100)
        let reassembler = Reassembler(timeout: 10)
        _ = try reassembler.accept(frames[0], from: LinkID("a"), now: now)
        _ = try reassembler.accept(frames[0], from: LinkID("b"), now: now)
        #expect(reassembler.pendingCount == 2)
        reassembler.reset(link: LinkID("a"))
        #expect(reassembler.pendingCount == 1)
        reassembler.purge(now: now.addingTimeInterval(11))
        #expect(reassembler.pendingCount == 0)
    }
}

@Suite("Routing primitives")
struct RoutingPrimitiveTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let dest = MeshIdentity().peerID

    @Test func prefersFewerHopsAndExpires() {
        var table = RoutingTable(expiry: 60)
        let r1 = table.offer(dest, link: LinkID("x"), hops: 3, now: now); #expect(r1)
        let r2 = table.offer(dest, link: LinkID("y"), hops: 1, now: now); #expect(r2)
        #expect(table.route(to: dest, now: now)?.link == LinkID("y"))
        let r3 = table.offer(dest, link: LinkID("x"), hops: 2, now: now); #expect(!r3) // worse alternative rejected
        #expect(table.route(to: dest, now: now.addingTimeInterval(61)) == nil)
        table.purge(now: now.addingTimeInterval(61))
        #expect(table.count == 0)
    }

    @Test func removingLinkDropsItsRoutes() {
        var table = RoutingTable(expiry: 60)
        table.offer(dest, link: LinkID("y"), hops: 1, now: now)
        let r4 = table.removeRoutes(via: LinkID("y")); #expect(r4 == [dest])
        #expect(table.route(to: dest, now: now) == nil)
    }

    @Test func seenCacheIsBoundedAndExpires() {
        var cache = SeenCache<Int>(capacity: 3, lifetime: 10)
        let r5 = cache.insert(1, now: now); #expect(r5)
        let r6 = cache.insert(1, now: now); #expect(!r6)
        cache.insert(2, now: now); cache.insert(3, now: now); cache.insert(4, now: now)
        #expect(!cache.contains(1, now: now)) // evicted (capacity)
        #expect(!cache.contains(4, now: now.addingTimeInterval(11))) // expired
    }

    @Test func rateLimiterRefills() {
        var limiter = RateLimiter(burst: 2, refillPerSecond: 1)
        let r7 = limiter.allow(dest, now: now); #expect(r7)
        let r8 = limiter.allow(dest, now: now); #expect(r8)
        let r9 = limiter.allow(dest, now: now); #expect(!r9)
        let r10 = limiter.allow(dest, now: now.addingTimeInterval(1.1)); #expect(r10)
    }
}
