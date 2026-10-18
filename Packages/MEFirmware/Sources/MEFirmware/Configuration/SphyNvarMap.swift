import Foundation

/// The SPHY OEM configuration nvar — `phy_oem_cfg` (`/home/bup/phy_oem_cfg`,
/// FileID 0x1001F200) — the PHY tuning block a CSME 18 image keeps in its FITC
/// partition.
///
/// MFIT 18 lays it out as its `SphyNvar` document: a `serialized_item` per
/// field, `offset*8 + bitfield_low … + bitfield_high` (`ValidByte` and
/// `EnableBit` take the byte at `offset`). The layout is emitted by
/// `Skills/me-eom-structures/scripts/sphy18_map.py`.
///
/// **The package carries more than one SPHY layout** and the nvar's header does
/// not say which one an image was built with. The map therefore states
/// **anchors** — the common header and the one field the 522- and 542-field
/// layouts disagree about (`Sub_Section_Entry2_Header_8`, 0x5 against 0x19) —
/// and the reader answers nothing for an nvar whose anchors do not hold. The
/// layout emitted is the one the CSME 18 dump verifies: all 522 of its
/// constant values read exactly in the image.
public struct SphyNvarMap: Sendable {
    public struct Field: Sendable, Equatable {
        public var name: String
        public var bitOffset: Int
        public var count: Int

        public init(name: String, bitOffset: Int, count: Int) {
            self.name = name
            self.bitOffset = bitOffset
            self.count = count
        }
    }

    /// A field whose documented value must read exactly so the nvar is this
    /// layout.
    public struct Anchor: Sendable, Equatable {
        public var name: String
        public var bitOffset: Int
        public var count: Int
        public var value: Int

        public init(name: String, bitOffset: Int, count: Int, value: Int) {
            self.name = name
            self.bitOffset = bitOffset
            self.count = count
            self.value = value
        }
    }

    public var name: String
    public var anchors: [Anchor]
    public var fields: [Field]

    public init(name: String, anchors: [Anchor], fields: [Field]) {
        self.name = name
        self.anchors = anchors
        self.fields = fields
    }

    /// The layout for a generation, or nil where none has been emitted.
    public static func forME(major: Int) -> SphyNvarMap? {
        major == 18 ? .csme18 : nil
    }

    public static var all: [SphyNvarMap] { [.csme18] }
}

public enum SphyNvarReader {
    /// The nvar's file IDs, as the file table states `/home/bup/phy_oem_cfg`
    /// (the second is the other half's).
    public static let fileIDs: Set<Int> = [0x1001_F200, 0x1201_F200]

    /// The values of the nvar's fields, or nil where the FITC payload carries
    /// no such record or its anchors are another SPHY layout's.
    public static func readings(in payload: Data, map: SphyNvarMap) -> [MIPStrapReading]? {
        guard let record = record(in: payload), record.count >= 12 else { return nil }
        func value(bitOffset: Int, count: Int) -> Int? {
            guard count > 0, count <= 32, bitOffset >= 0 else { return nil }
            let byte = bitOffset / 8
            let shift = bitOffset % 8
            let needed = (shift + count + 7) / 8
            guard needed <= 8, byte + needed <= record.count else { return nil }
            var word: UInt64 = 0
            for index in 0..<needed {
                word |= UInt64(record[byte + index]) << (8 * index)
            }
            let mask: UInt64 = count == 64 ? .max : (1 << UInt64(count)) - 1
            return Int(word >> UInt64(shift) & mask)
        }
        for anchor in map.anchors {
            guard value(bitOffset: anchor.bitOffset, count: anchor.count)
                    == anchor.value else { return nil }
        }
        var readings: [MIPStrapReading] = []
        for field in map.fields {
            guard let value = value(bitOffset: field.bitOffset, count: field.count)
            else { continue }
            readings.append(MIPStrapReading(name: field.name, value: value))
        }
        return readings.isEmpty ? nil : readings
    }

    /// The record whose File ID is the nvar's, as its value bytes.
    private static func record(in payload: Data) -> Data? {
        guard payload.count >= 4 else { return nil }
        let count = Int(readUInt32(payload, at: 0))
        guard count > 0, count <= 4096, 4 + count * 12 <= payload.count else { return nil }
        for index in 0..<count {
            let entry = 4 + index * 12
            let fileID = Int(readUInt32(payload, at: entry)) & 0xFFFF_FFFF
            guard fileIDs.contains(fileID) else { continue }
            let offset = Int(readUInt32(payload, at: entry + 4))
            let size = Int(readUInt16(payload, at: entry + 8))
            guard offset >= 0, size > 0, offset + size <= payload.count else { continue }
            return payload.subdata(in: offset..<(offset + size))
        }
        return nil
    }

    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(data[index])
            | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16
            | UInt32(data[index + 3]) << 24
    }
}
