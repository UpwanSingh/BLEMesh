import Foundation

/// Errors raised while decoding untrusted bytes from the network.
public enum WireError: Error, Equatable {
    case truncated
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case invalidField(String)
    case tooLarge
}

/// Append-only binary writer (big-endian).
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }

    mutating func u16(_ v: UInt16) {
        data.append(UInt8(v >> 8))
        data.append(UInt8(v & 0xff))
    }

    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((v >> UInt32(shift)) & 0xff)) }
    }

    mutating func u64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((v >> UInt64(shift)) & 0xff)) }
    }

    mutating func bytes(_ d: Data) { data.append(d) }

    mutating func uuid(_ u: UUID) {
        withUnsafeBytes(of: u.uuid) { data.append(contentsOf: $0) }
    }

    /// Length-prefixed (u16) blob.
    mutating func blob16(_ d: Data) throws {
        guard d.count <= Int(UInt16.max) else { throw WireError.tooLarge }
        u16(UInt16(d.count))
        data.append(d)
    }

    /// Length-prefixed (u8) UTF-8 string, truncated to 255 bytes on a character boundary.
    mutating func string8(_ s: String) {
        var utf8 = Data(s.utf8)
        if utf8.count > 255 {
            var truncated = s
            while Data(truncated.utf8).count > 255 { truncated.removeLast() }
            utf8 = Data(truncated.utf8)
        }
        u8(UInt8(utf8.count))
        data.append(utf8)
    }
}

/// Bounds-checked binary reader for untrusted input.
struct ByteReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = Data(data) // re-base indices to 0
        self.offset = 0
    }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset == data.count }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() throws -> UInt64 {
        let b = try bytes(8)
        return b.reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func rest() -> Data {
        defer { offset = data.count }
        return data.subdata(in: offset..<data.count)
    }

    mutating func uuid() throws -> UUID {
        let b = try bytes(16)
        let t = Array(b)
        return UUID(uuid: (t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7],
                           t[8], t[9], t[10], t[11], t[12], t[13], t[14], t[15]))
    }

    mutating func peerID() throws -> PeerID {
        PeerID(uncheckedBytes: try bytes(16))
    }

    mutating func blob16() throws -> Data {
        let length = try u16()
        return try bytes(Int(length))
    }

    mutating func string8() throws -> String {
        let length = try u8()
        let b = try bytes(Int(length))
        guard let s = String(data: b, encoding: .utf8) else { throw WireError.invalidField("utf8") }
        return s
    }
}
