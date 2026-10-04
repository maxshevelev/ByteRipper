import Foundation

/// A UEFI device path in the text form of UEFI §10.6 —
/// `PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x0,0xFFFF,0x0)/HD(1,GPT,…)/\EFI\BOOT\BOOTX64.EFI`.
///
/// The nodes a boot entry or a console variable is built from are spelled
/// out; any other node reads as `Path(type,subtype)`, which names it without
/// claiming to know its fields.
public enum DevicePath {
    /// The path `bytes` hold, exactly: nodes that fit one after another and
    /// end in an end-of-path node at the last byte, at least one node before
    /// it. Nil otherwise — which is what lets a value be told for a path by
    /// its bytes alone.
    public static func text(_ bytes: [UInt8]) -> String? {
        var instances: [[String]] = [[]]
        var at = 0
        while at + 4 <= bytes.count {
            let type = bytes[at], subtype = bytes[at + 1]
            let length = Int(bytes[at + 2]) | Int(bytes[at + 3]) << 8
            guard length >= 4, at + length <= bytes.count, (1...5).contains(type) || type == 0x7F else { return nil }
            let node = Array(bytes[at..<(at + length)])
            at += length
            if type == 0x7F {
                switch subtype {
                case 0xFF:
                    guard at == bytes.count, instances.allSatisfy({ !$0.isEmpty }) else { return nil }
                    return instances.map { $0.joined(separator: "/") }.joined(separator: ",")
                case 0x01:
                    instances.append([])
                default:
                    return nil
                }
            } else {
                instances[instances.count - 1].append(nodeText(type, subtype, node))
            }
        }
        return nil
    }

    // MARK: - Nodes

    private static func nodeText(_ type: UInt8, _ subtype: UInt8, _ node: [UInt8]) -> String {
        let fields = Fields(node)
        switch (type, subtype) {
        // Hardware.
        case (1, 1) where node.count >= 6:
            return "Pci(\(hex(node[5])),\(hex(node[4])))"
        case (1, 2) where node.count >= 5:
            return "PcCard(\(hex(node[4])))"
        case (1, 3) where node.count >= 24:
            return "MemoryMapped(\(hex(fields.u32(4))),\(hex(fields.u64(8))),\(hex(fields.u64(16))))"
        case (1, 4) where node.count >= 20:
            return "VenHw(\(fields.guid(4)))"
        case (1, 5) where node.count >= 8:
            return "Ctrl(\(hex(fields.u32(4))))"
        // ACPI.
        case (2, 1) where node.count >= 12:
            return acpiText(hid: fields.u32(4), uid: fields.u32(8))
        case (2, 3) where node.count >= 8:
            return "AcpiAdr(\(hex(fields.u32(4))))"
        // Messaging.
        case (3, 1) where node.count >= 8:
            return "Ata(\(node[4]),\(node[5]),\(fields.u16(6)))"
        case (3, 2) where node.count >= 8:
            return "Scsi(\(hex(fields.u16(4))),\(hex(fields.u16(6))))"
        case (3, 5) where node.count >= 6:
            return "USB(\(hex(node[4])),\(hex(node[5])))"
        case (3, 10) where node.count >= 20:
            return "VenMsg(\(fields.guid(4)))"
        case (3, 11) where node.count >= 37:
            let address = node[4..<10].map { String(format: "%02X", $0) }.joined()
            return "MAC(\(address),\(hex(node[36])))"
        case (3, 12) where node.count >= 12:
            return "IPv4(\(node[8...11].map(String.init).joined(separator: ".")))"
        case (3, 13):
            return "IPv6()"
        case (3, 15) where node.count >= 11:
            return "UsbClass(\(hex(fields.u16(4))),\(hex(fields.u16(6))),\(hex(node[8])),\(hex(node[9])),\(hex(node[10])))"
        case (3, 18) where node.count >= 10:
            return "Sata(\(hex(fields.u16(4))),\(hex(fields.u16(6))),\(hex(fields.u16(8))))"
        case (3, 23) where node.count >= 16:
            let eui = node[8..<16].reversed().map { String(format: "%02X", $0) }.joined(separator: "-")
            return "NVMe(\(hex(fields.u32(4))),\(eui))"
        case (3, 24):
            return "Uri(\(String(decoding: node.dropFirst(4), as: UTF8.self)))"
        case (3, 26) where node.count >= 5:
            return "SD(\(hex(node[4])))"
        case (3, 29) where node.count >= 5:
            return "eMMC(\(hex(node[4])))"
        // Media.
        case (4, 1) where node.count >= 42:
            return hardDriveText(fields, node)
        case (4, 2) where node.count >= 24:
            return "CDROM(\(hex(fields.u32(4))),\(hex(fields.u64(8))),\(hex(fields.u64(16))))"
        case (4, 3) where node.count >= 20:
            return "VenMedia(\(fields.guid(4)))"
        case (4, 4):
            let units = stride(from: 4, to: node.count - 1, by: 2).map { UInt16(node[$0]) | UInt16(node[$0 + 1]) << 8 }
            return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
        case (4, 5) where node.count >= 20:
            return "Media(\(fields.guid(4)))"
        case (4, 6) where node.count >= 20:
            return "FvFile(\(fields.guid(4)))"
        case (4, 7) where node.count >= 20:
            return "Fv(\(fields.guid(4)))"
        case (4, 8) where node.count >= 24:
            return "Offset(\(hex(fields.u64(8))),\(hex(fields.u64(16))))"
        // BIOS boot specification.
        case (5, 1) where node.count >= 8:
            let types: [UInt16: String] = [1: "Floppy", 2: "HD", 3: "CDROM", 4: "PCMCIA", 5: "USB", 6: "Network"]
            let device = fields.u16(4)
            let description = String(decoding: node.dropFirst(8).prefix { $0 != 0 }, as: UTF8.self)
            return "BBS(\(types[device] ?? hex(device)),\(description),\(hex(fields.u16(6))))"
        default:
            return "Path(\(type),\(subtype))"
        }
    }

    /// The ACPI node, by the device its EISA id names where the spec gives
    /// it a word of its own.
    private static func acpiText(hid: UInt32, uid: UInt32) -> String {
        guard hid & 0xFFFF == 0x41D0 else { return "Acpi(\(hex(hid)),\(hex(uid)))" }
        let pnp = hid >> 16
        switch pnp {
        case 0x0A03: return "PciRoot(\(hex(uid)))"
        case 0x0A08: return "PcieRoot(\(hex(uid)))"
        case 0x0604: return "Floppy(\(hex(uid)))"
        case 0x0301: return "Keyboard(\(hex(uid)))"
        case 0x0501: return "Serial(\(hex(uid)))"
        case 0x0401: return "ParallelPort(\(hex(uid)))"
        default: return "Acpi(PNP\(String(format: "%04X", pnp)),\(hex(uid)))"
        }
    }

    /// A partition: its number, the table it is in, its signature, where it
    /// starts and how long it is, in sectors.
    private static func hardDriveText(_ fields: Fields, _ node: [UInt8]) -> String {
        let number = fields.u32(4), start = hex(fields.u64(8)), size = hex(fields.u64(16))
        switch node[41] {
        case 1: return "HD(\(number),MBR,\(String(format: "0x%08X", fields.u32(24))),\(start),\(size))"
        case 2: return "HD(\(number),GPT,\(fields.guid(24)),\(start),\(size))"
        default: return "HD(\(number),\(hex(node[41])),0,\(start),\(size))"
        }
    }

    private struct Fields {
        let bytes: [UInt8]
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
        func guid(_ at: Int) -> String { EFIGUID(bytes: Array(bytes[at..<(at + 16)])).description }
    }

    private static func hex<T: BinaryInteger>(_ value: T) -> String {
        "0x" + String(UInt64(truncatingIfNeeded: value), radix: 16, uppercase: true)
    }
}
