import Foundation

/// An AMD microcode patch's header (`UEFI_IMAGE_FORMAT.md` §7.2), as the
/// reference reads it (`amd_microcode.h`, `amdMicrocodeHeaderValid`).
///
/// It has no signature: a patch is a header whose every field is one AMD
/// writes — a BCD date, a loader id of `0x80xx`, AMD's PCI vendor id or none
/// — and whose size follows from the processor family, which the header does
/// not state either. On an AMD board the PSP's BIOS directory names each patch
/// (entry type `0x66`), and the sizes in it agree with this table on every
/// dump at hand. Reading the directory is a piece of work of its own.
public struct AMDMicrocodeHeader: Equatable, Sendable {
    public static let size: UInt64 = 0x20
    /// What the reference wants after the header before it calls a patch one:
    /// `0x44` more bytes, the dword at `0x40` not zero.
    static let minimumSize: UInt64 = 0x20 + 0x44

    public var offset: UInt64
    public var year: UInt16
    public var month: UInt8
    public var day: UInt8
    public var updateRevision: UInt32
    public var loaderID: UInt16
    public var dataChecksum: UInt32
    public var northBridgeVendor: UInt16
    public var northBridgeDevice: UInt16
    public var southBridgeVendor: UInt16
    public var southBridgeDevice: UInt16
    /// The two bytes AMD keeps of the CPUID: the extended family and model
    /// above, the stepping below (`cpuID` spells them out).
    public var processorSignature: UInt16
    public var northBridgeRevision: UInt8
    public var southBridgeRevision: UInt8
    public var biosAPIRevision: UInt8
    public var loadControl: UInt8
    /// The patch's length, header included.
    public var length: UInt64

    /// The CPUID the patch is for, the way AMD's file names write it:
    /// `00A50F00` for `0xA500`.
    public var cpuID: UInt32 {
        Self.cpuID(processorSignature)
    }

    static func cpuID(_ signature: UInt16) -> UInt32 {
        UInt32(signature >> 8) << 16 | 0x0F00 | UInt32(signature & 0xFF)
    }

    /// The date as written, `YYYY-MM-DD`: the fields are BCD, so their hex is
    /// their decimal.
    public var date: String {
        String(format: "%04X-%02X-%02X", year, month, day)
    }

    public var range: Range<UInt64> { offset..<(offset + length) }

    /// The patch at `offset`, when its header is one and the whole of it fits
    /// before `limit`; nil otherwise, saying nothing — a header with no
    /// signature turns up in any data, and turning one down is no defect.
    public static func read(at offset: UInt64, limit: UInt64, in reader: ImageReader) -> AMDMicrocodeHeader? {
        guard offset + minimumSize <= limit,
              let bytes = reader.bytes(at: offset, count: size),
              let after = reader.uint32(at: offset + 0x40), after != 0
        else { return nil }
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }

        let signature = u16(0x18)
        let revision = u32(0x04)
        let cpu = cpuID(signature)
        var year = u16(0x00)
        var day = bytes[0x02]
        var month = bytes[0x03]
        // Three patches AMD shipped with a date that is not one, put right
        // the way the reference puts them right.
        if cpu == 0x0080_0F11, revision == 0x0800_1105, year == 0x2016 { year = 0x2017 }
        if cpu == 0x0030_0F10, revision == 0x0300_0027, month == 0x13 { month = 0x12 }
        if cpu == 0x0073_0F01, revision == 0x0703_0106 {
            if month == 0x09 { month = 0x02 }
            if day == 0x02 { day = 0x09 }
        }
        let yearInCentury = UInt8(truncatingIfNeeded: year)
        guard isBCD(day, in: 0x01...0x31), isBCD(month, in: 0x01...0x12),
              year >> 8 == 0x20, isBCD(yearInCentury, in: 0x01...0x29)
        else { return nil }

        let loader = u16(0x08)
        let data = loader >= 0x8005
            ? (UInt64(bytes[0x0B]) << 8 | UInt64(bytes[0x0A])) * 0x10
            : UInt64(bytes[0x0A])
        guard cpu != 0x0F00 || data == 0x10 || data == 0x20,
              loader >> 8 == 0x80,
              [0x0000, 0x1022].contains(u16(0x10)), [0x0000, 0x1022].contains(u16(0x14)),
              bytes[0x1C] <= 0x01,
              bytes[0x1D] <= 0x0F || bytes[0x1D] == 0xAA
        else { return nil }

        let length = patchLength(dataLength: data, family: UInt8(signature >> 8))
        guard length != 0, offset + length <= limit else { return nil }
        return AMDMicrocodeHeader(
            offset: offset, year: year, month: month, day: day, updateRevision: revision,
            loaderID: loader, dataChecksum: u32(0x0C),
            northBridgeVendor: u16(0x10), northBridgeDevice: u16(0x12),
            southBridgeVendor: u16(0x14), southBridgeDevice: u16(0x16),
            processorSignature: signature,
            northBridgeRevision: bytes[0x1A], southBridgeRevision: bytes[0x1B],
            biosAPIRevision: bytes[0x1C], loadControl: bytes[0x1D], length: length
        )
    }

    /// A BCD byte within `range`: each nibble a decimal digit.
    private static func isBCD(_ value: UInt8, in range: ClosedRange<UInt8>) -> Bool {
        value & 0x0F <= 9 && value >> 4 <= 9 && range.contains(value)
    }

    /// How long a patch is (`amdMicrocodeGetSize`): the header says it for the
    /// old families, and for the new ones only the family does — the
    /// reference's table, by the CPUID's extended family and model byte.
    static func patchLength(dataLength: UInt64, family: UInt8) -> UInt64 {
        switch dataLength {
        case 0x20: return 0x3C0
        case 0x10: return 0x200
        case 0: break
        default: return dataLength
        }
        switch family {
        case 0x50: return 0x620
        case 0x58: return 0x567
        case 0x60...0x67: return 0xA20
        case 0x68, 0x69: return 0x980
        case 0x70, 0x73: return 0xD60
        case 0x80...0x83, 0x85...0x8A: return 0xC80
        case 0xA0...0xA7, 0xAA: return 0x15C0
        case 0xB4: return 0x3820
        default: return 0
        }
    }
}

extension Parser {
    /// `nodes` with the AMD microcode in their padding read out as rows: in
    /// padding the scan left, and in the map regions and padding rows already
    /// read into it — on the Lenovo AMD board the patch sits in an Insyde map
    /// region, which the reference, knowing no regions, would not look in.
    /// Each stretch keeps its place, range and name, as it does for every
    /// structure read out of padding (§9).
    func readingAMDMicrocode(_ nodes: [UEFINode], emptyByte: UInt8) -> [UEFINode] {
        nodes.map { node in
            guard node.kind == .padding || node.kind == .flashDeviceMapRegion,
                  !ECImage.isECFirmwarePadding(node)
            else { return node }
            var read = node
            if !node.children.isEmpty {
                read.children = readingAMDMicrocode(node.children, emptyByte: emptyByte)
                return read
            }
            guard !node.isErased else { return node }
            let patches = amdMicrocode(in: node.body)
            guard !patches.isEmpty else { return node }
            var rows: [UEFINode] = []
            var claimed = node.body.lowerBound
            for patch in patches {
                rows += padding(from: claimed, to: patch.range.lowerBound, emptyByte: emptyByte)
                rows.append(amdMicrocodeNode(patch))
                claimed = patch.range.upperBound
            }
            read.children = rows + padding(from: claimed, to: node.body.upperBound, emptyByte: emptyByte)
            return read
        }
    }

    /// Every patch in `range`, one after another: byte by byte, as the
    /// reference looks, with the loader id's high byte — `0x80` on every
    /// patch — as the cheap first test.
    private func amdMicrocode(in range: Range<UInt64>) -> [AMDMicrocodeHeader] {
        guard range.count >= AMDMicrocodeHeader.minimumSize, let bytes = reader.bytes(range) else { return [] }
        var found: [AMDMicrocodeHeader] = []
        var index = 0
        let last = bytes.count - Int(AMDMicrocodeHeader.minimumSize)
        while index <= last {
            if bytes[index + 9] == 0x80,
               let patch = AMDMicrocodeHeader.read(at: range.lowerBound + UInt64(index),
                                                   limit: range.upperBound, in: reader) {
                found.append(patch)
                index += Int(patch.length)
            } else {
                index += 1
            }
        }
        return found
    }

    private func amdMicrocodeNode(_ patch: AMDMicrocodeHeader) -> UEFINode {
        UEFINode(
            kind: .amdMicrocode,
            name: String(format: "AMD microcode %X, revision %X", patch.cpuID, patch.updateRevision),
            header: patch.offset..<(patch.offset + AMDMicrocodeHeader.size),
            body: (patch.offset + AMDMicrocodeHeader.size)..<patch.range.upperBound,
            // The PSP's directory points at it, as the FIT points at Intel's.
            isFixed: true
        )
    }
}
