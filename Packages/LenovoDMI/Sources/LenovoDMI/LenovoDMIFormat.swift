import Foundation
import Localization

/// The fixed numbers of the store, as `LenovoVariableDxe` hard-codes them.
///
/// Upstream's `Lenovo.hpp` is the source; the two places it is wrong — the
/// size of a log entry and how the year is stored — are corrected against real
/// dumps and say so where they are.
public enum LenovoDMIFormat {
    /// `LENV`, little-endian.
    public static let lenvSignature: [UInt8] = Array("LENV".utf8)
    /// `LDBG`, little-endian.
    public static let ldbgSignature: [UInt8] = Array("LDBG".utf8)

    /// The change log: two pages.
    public static let ldbgSize: UInt64 = 0x2000
    /// Each `LENV` block: one page.
    public static let lenvSize: UInt64 = 0x1000
    /// The whole area — the log and the two blocks, back to back.
    public static let areaSize: UInt64 = ldbgSize + 2 * lenvSize

    /// `LENV_HEADER`: signature, generation, entry count, access flag, XOR key,
    /// checksum. Never encoded.
    public static let lenvHeaderSize = 0x10
    /// What comes before an entry's data: the key (16), the data size (4), the
    /// flags (1) and two fields nobody has explained (1 + 2).
    public static let lenvEntryHeaderSize = 0x18

    /// `LDBG_HEADER`: signature, write offset, 24 bytes nobody has explained.
    /// Never encoded — the write offset reads in the clear on every dump
    /// looked at, while the entries after it do not.
    public static let ldbgHeaderSize = 0x20
    /// One `LDBG_ENTRY`. Upstream's comments put the size field at `+0x10`,
    /// which would make an entry 24 bytes; the structure itself is 32 — a
    /// 7-byte timestamp, the operation, the 16-byte key, the size and four
    /// bytes nobody has explained — and on real dumps the write offset is
    /// `0x20 + 32·n` exactly.
    public static let ldbgEntrySize = 0x20

    /// The namespace every SMBIOS entry is filed under.
    public static let smbiosNamespace: [UInt8] = [
        0x55, 0x57, 0x0E, 0xC2, 0x69, 0x11, 0x56, 0x4C,
        0xA4, 0x8A, 0x98, 0x24, 0xAB, 0x43
    ]
    public static let namespaceSize = 14
}

/// What the firmware files an entry under: a 14-byte namespace and a type
/// within it.
public struct LenovoDMIKey: Hashable, Sendable {
    public var namespace: [UInt8]
    public var type: UInt16

    public init(namespace: [UInt8], type: UInt16) {
        self.namespace = namespace
        self.type = type
    }

    public static func smbios(_ type: UInt16) -> LenovoDMIKey {
        LenovoDMIKey(namespace: LenovoDMIFormat.smbiosNamespace, type: type)
    }

    public var isSMBIOS: Bool { namespace == LenovoDMIFormat.smbiosNamespace }

    /// Reads the 16 bytes at `offset` of `bytes`.
    static func read(_ bytes: [UInt8], at offset: Int) -> LenovoDMIKey {
        LenovoDMIKey(
            namespace: Array(bytes[offset..<(offset + LenovoDMIFormat.namespaceSize)]),
            type: LE.u16(bytes, offset + LenovoDMIFormat.namespaceSize)
        )
    }

    /// The type as the panel writes it: four hex digits, the way upstream and
    /// the firmware's own constants write it.
    public var typeText: String { LE.hex(UInt64(type), digits: 4) }

    /// The namespace as hex bytes, for one nobody has named.
    public var namespaceText: String {
        namespace.map { LE.hex(UInt64($0), digits: 2, prefix: false) }.joined(separator: " ")
    }
}

/// The entry types whose meaning upstream established, and how their value
/// reads. A type not listed here is called unknown — in the panel and in the
/// help — since real dumps carry several more (`0x0000`, `0x0300`, `0x0700`, …) and
/// what they hold has not been documented.
public enum LenovoDMIKnownType: UInt16, CaseIterable, Sendable {
    case windowsKey = 0x0001
    case oa3KeyID = 0x000B
    case motherboardName = 0x0100
    case machineTypeModel = 0x0200
    case baseboardSerialNumber = 0x0400
    case systemUUID = 0x0500
    case baseboardPlatformID = 0x0F00
    case osPreloadSuffix = 0x1000

    public init?(_ key: LenovoDMIKey) {
        guard key.isSMBIOS else { return nil }
        self.init(rawValue: key.type)
    }

    public var name: String {
        switch self {
        case .windowsKey: return L("Windows key")
        case .oa3KeyID: return L("OA3 key ID")
        case .motherboardName: return L("Motherboard name")
        case .machineTypeModel: return L("Machine type/model")
        case .baseboardSerialNumber: return L("Baseboard serial number")
        case .systemUUID: return L("System UUID")
        case .baseboardPlatformID: return L("Baseboard platform ID")
        case .osPreloadSuffix: return L("OS preload suffix")
        }
    }

    /// How the value reads: a UUID, text, or bytes.
    public var reading: LenovoDMIValue.Reading {
        switch self {
        case .systemUUID: return .uuid
        case .windowsKey: return .windowsKey
        default: return .text
        }
    }
}

/// Little-endian reads and hex text, over a plain byte array.
enum LE {
    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    static func bytes16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    static func hex(_ value: UInt64, digits: Int, prefix: Bool = true) -> String {
        let text = String(value, radix: 16, uppercase: true)
        let padded = String(repeating: "0", count: max(0, digits - text.count)) + text
        return prefix ? "0x" + padded : padded
    }
}

extension Array where Element == UInt8 {
    /// Every byte XORed with `key` — both directions of the store's cipher.
    func xored(with key: UInt8) -> [UInt8] {
        key == 0 ? self : map { $0 ^ key }
    }

    /// The store's checksum: the bytes added up, kept to 16 bits.
    var sum16: UInt16 {
        var sum: UInt16 = 0
        for byte in self { sum = sum &+ UInt16(byte) }
        return sum
    }
}
