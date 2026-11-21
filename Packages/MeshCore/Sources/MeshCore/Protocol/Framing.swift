import Foundation

/// Link-level framing. A packet is sent either whole or split into fragments that fit the
/// link's maximum frame size. Reassembly is keyed per link, so copies of the same packet
/// arriving over different links can never be mixed together.
///
/// Frame layouts:
/// ```
/// 0xA1 | packet bytes                                   (whole packet)
/// 0xA2 | groupID u32 | index u16 | count u16 | chunk   (fragment)
/// ```
public enum Framing {
    static let wholeMarker: UInt8 = 0xA1
    static let fragmentMarker: UInt8 = 0xA2
    static let fragmentHeaderSize = 1 + 4 + 2 + 2
    public static let minimumFrameSize = fragmentHeaderSize + 8
    public static let maxFragments = 512

    /// Split `packet` into frames no larger than `maxFrameSize`.
    public static func frames(for packet: Data, maxFrameSize: Int, groupID: UInt32 = UInt32.random(in: 1...UInt32.max)) -> [Data] {
        let frameSize = max(maxFrameSize, minimumFrameSize)
        if packet.count + 1 <= frameSize {
            var frame = Data([wholeMarker])
            frame.append(packet)
            return [frame]
        }
        let chunkSize = frameSize - fragmentHeaderSize
        let count = (packet.count + chunkSize - 1) / chunkSize
        guard count <= maxFragments else { return [] }
        var frames: [Data] = []
        frames.reserveCapacity(count)
        let base = Data(packet)
        for index in 0..<count {
            let start = index * chunkSize
            let end = min(start + chunkSize, base.count)
            var w = ByteWriter()
            w.u8(fragmentMarker)
            w.u32(groupID)
            w.u16(UInt16(index))
            w.u16(UInt16(count))
            w.bytes(base.subdata(in: start..<end))
            frames.append(w.data)
        }
        return frames
    }
}

/// Reassembles fragments per (link, group). Bounded in memory and time.
public final class Reassembler {
    private struct Key: Hashable {
        let link: LinkID
        let group: UInt32
    }

    private struct Pending {
        var count: Int
        var chunks: [Int: Data]
        var bytes: Int
        var startedAt: Date
    }

    private var pending: [Key: Pending] = [:]
    private let timeout: TimeInterval
    private let maxPendingGroups: Int
    private let maxPacketBytes: Int

    public init(timeout: TimeInterval = 30, maxPendingGroups: Int = 128, maxPacketBytes: Int = Packet.maxPayloadSize + 512) {
        self.timeout = timeout
        self.maxPendingGroups = maxPendingGroups
        self.maxPacketBytes = maxPacketBytes
    }

    public var pendingCount: Int { pending.count }

    /// Feed one frame. Returns a complete packet's bytes when available.
    public func accept(_ frame: Data, from link: LinkID, now: Date) throws -> Data? {
        var r = ByteReader(frame)
        let marker = try r.u8()
        switch marker {
        case Framing.wholeMarker:
            return r.rest()
        case Framing.fragmentMarker:
            let group = try r.u32()
            let index = Int(try r.u16())
            let count = Int(try r.u16())
            let chunk = r.rest()
            guard count > 0, count <= Framing.maxFragments, index < count else {
                throw WireError.invalidField("fragment index")
            }
            let key = Key(link: link, group: group)
            var entry = pending[key] ?? Pending(count: count, chunks: [:], bytes: 0, startedAt: now)
            guard entry.count == count else { throw WireError.invalidField("fragment count mismatch") }
            if entry.chunks[index] == nil {
                entry.chunks[index] = chunk
                entry.bytes += chunk.count
            }
            guard entry.bytes <= maxPacketBytes else {
                pending[key] = nil
                throw WireError.tooLarge
            }
            if entry.chunks.count == count {
                pending[key] = nil
                var packet = Data(capacity: entry.bytes)
                for i in 0..<count { packet.append(entry.chunks[i]!) }
                return packet
            }
            if pending[key] == nil && pending.count >= maxPendingGroups {
                evictOldest()
            }
            pending[key] = entry
            return nil
        default:
            throw WireError.invalidField("frame marker")
        }
    }

    /// Drop all partial packets from a link (e.g. on disconnect).
    public func reset(link: LinkID) {
        pending = pending.filter { $0.key.link != link }
    }

    public func purge(now: Date) {
        pending = pending.filter { now.timeIntervalSince($0.value.startedAt) < timeout }
    }

    private func evictOldest() {
        if let oldest = pending.min(by: { $0.value.startedAt < $1.value.startedAt })?.key {
            pending[oldest] = nil
        }
    }
}
