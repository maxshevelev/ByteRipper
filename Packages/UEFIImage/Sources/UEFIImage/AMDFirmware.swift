import Foundation
import Localization

/// The map the AMD Platform Security Processor reads the flash by
/// (`UEFI_IMAGE_FORMAT.md` §9): the Embedded Firmware Structure, the
/// directories it points at, and every blob those directories list.
///
/// On an AMD board the first megabytes of the flash are the PSP's — its
/// boot loader, the SMU firmware, the memory training (ABL, APCB, PMU), the
/// microcode — and nothing in them is an FFS volume. The PSP finds them
/// through the EFS, a table at one of a few fixed offsets that starts with
/// `0x55AA55AA`, and the directories it points at:
///
/// - **PSP directories**, `$PSP` and the second level `$PL2`: 16-byte
///   entries — type, subprogram, flags (ROM id, writable, instance), size,
///   location.
/// - **BIOS directories**, `$BHD` and `$BL2`: 24-byte entries — type, region
///   type, flags (reset, copy, read-only, compressed, instance, subprogram,
///   ROM id, writable), size, source, destination in memory.
/// - **Combo directories**, `2PSP` and `2BHD`: one directory per CPU family
///   the flash serves, chosen by PSP id.
/// - **Image slot headers**, which a PSP directory's slot A and B entries
///   (`0x48`, `0x4A`) point at on Zen 4 and later: the slot's priority and
///   its second-level directory.
///
/// A directory's header is its signature, a Fletcher-32 checksum of the rest,
/// the number of entries and a word whose address mode says how its entries'
/// locations read: a memory-mapped address, an offset in the flash, or an
/// offset from the directory itself.
///
/// The walk starts at the EFS and follows pointers. A scan for the
/// signatures would find more — directory headers turn up copied inside
/// blobs — and they are not the ones the PSP reads. The layout and the type
/// names follow AMD's public BIOS and kernel-driver documentation as coreboot's
/// `amdfwtool` and PSPTool implement them; PSPTool is the reference this
/// reading is checked against.
public struct AMDFirmware: Equatable, Sendable {
    /// The EFS signature, `AA 55 AA 55` in the bytes.
    public static let efsSignature: UInt32 = 0x55AA_55AA
    /// What the EFS is taken to span: the coreboot structure's length.
    public static let efsLength: UInt64 = 0x50
    /// Where the EFS may be, from the start of the flash, in the order they
    /// are tried — the PSP's own order on the boards PSPTool traced.
    public static let efsOffsets: [UInt64] = [0x02_0000, 0xFA_0000, 0xF2_0000, 0xE2_0000, 0xC2_0000, 0x82_0000, 0x12_0000]

    public enum DirectoryKind: UInt8, Sendable, CaseIterable {
        case psp = 1
        case pspLevel2
        case bios
        case biosLevel2
        case pspCombo
        case biosCombo
        case slotHeader

        /// The four bytes it starts with; none for a slot header.
        public var signature: String? {
            switch self {
            case .psp: return "$PSP"
            case .pspLevel2: return "$PL2"
            case .bios: return "$BHD"
            case .biosLevel2: return "$BL2"
            case .pspCombo: return "2PSP"
            case .biosCombo: return "2BHD"
            case .slotHeader: return nil
            }
        }

        public var isBIOS: Bool { self == .bios || self == .biosLevel2 }
        public var isCombo: Bool { self == .pspCombo || self == .biosCombo }

        /// The header's length: a combo directory has sixteen more bytes.
        var headerSize: UInt64 {
            switch self {
            case .pspCombo, .biosCombo: return 0x20
            case .slotHeader: return 0x20
            default: return 0x10
            }
        }

        var entrySize: UInt64 {
            switch self {
            case .bios, .biosLevel2: return 24
            case .slotHeader: return 0
            default: return 16
            }
        }

        static func kind(signature: [UInt8]) -> DirectoryKind? {
            allCases.first { $0.signature.map { Array($0.utf8) } == signature }
        }
    }

    /// How a location in an entry reads.
    public enum AddressMode: UInt8, Sendable {
        /// The address the x86 cores see the flash at, `0xFFxxxxxx`.
        case physical = 0
        /// An offset from the start of the flash.
        case flashOffset = 1
        /// An offset from the directory's own header.
        case directoryRelative = 2
        /// An offset from the start of the slot the directory is in.
        case slotRelative = 3
    }

    /// One entry of a PSP or BIOS directory.
    public struct Entry: Equatable, Sendable {
        public var index: Int
        public var type: UInt8
        /// A PSP entry's subprogram; a BIOS entry's region type.
        public var subtype: UInt8
        /// The two flag bytes, as they are.
        public var flags: UInt16
        public var size: UInt32
        /// The location field, address-mode bits included.
        public var location: UInt64
        /// A BIOS entry's destination in memory; nil for a PSP entry.
        public var destination: UInt64?
        public var isBIOS: Bool
        /// Where the blob lies in the file; nil for an entry with no blob —
        /// a value, a size of zero — and for one that points outside the image.
        public var range: Range<UInt64>?
        /// The flash offset the location resolves to, in the image or not.
        public var resolvedOffset: UInt64?
        /// A compressed BIOS image that is there as AMD stores one: the
        /// 0x100-byte header and a zlib stream (`compressedLength`).
        public var isStoredCompressed = false

        /// The soft-fuse chain and its kin keep a value where the location
        /// would be, and no size.
        public var isValue: Bool { !isBIOS && size == 0xFFFF_FFFF }

        public var instance: UInt8 {
            isBIOS ? UInt8((flags >> 4) & 0xF) : UInt8((flags >> 3) & 0xF)
        }

        /// A BIOS entry's subprogram, which sits in its flags.
        public var subprogram: UInt8 { isBIOS ? UInt8((flags >> 8) & 0x7) : subtype }

        public var isCompressed: Bool { isBIOS && flags & 0x08 != 0 }
        public var isReset: Bool { isBIOS && flags & 0x01 != 0 }
        public var isCopy: Bool { isBIOS && flags & 0x02 != 0 }
        public var isReadOnly: Bool { isBIOS && flags & 0x04 != 0 }
        public var isWritable: Bool { isBIOS ? flags & 0x2000 != 0 : flags & 0x04 != 0 }

        /// The type's name, AMD's word for it.
        public var typeName: String { AMDFirmware.typeName(type, inBIOSDirectory: isBIOS) }

        /// Whether the entry points at another directory rather than at a blob.
        public var pointsAtDirectory: Bool {
            isBIOS ? type == 0x70 : [0x40, 0x48, 0x49, 0x4A].contains(type)
        }
    }

    /// One entry of a combo directory: the directory for one PSP id.
    public struct ComboEntry: Equatable, Sendable {
        /// 0: the id is a PSP id; 1: a chip family id.
        public var selector: UInt32
        public var id: UInt32
        public var location: UInt64
        public var resolvedOffset: UInt64?
    }

    public struct Directory: Equatable, Sendable {
        public var kind: DirectoryKind
        public var offset: UInt64
        /// The header and the entries.
        public var length: UInt64
        public var entries: [Entry]
        public var comboEntries: [ComboEntry]
        /// The header's fourth word: the directory's size, the SPI block
        /// size, a base address and the address mode.
        public var info: UInt32
        public var storedChecksum: UInt32?
        public var computedChecksum: UInt32?
        /// The PSP id a combo directory or a slot header names it for.
        public var pspID: UInt32?
        /// A slot header's slot — `A` or `B` — and its priority.
        public var slot: String?
        public var priority: UInt32?
        /// A slot header's second-level directory.
        public var slotTarget: UInt64?

        public var range: Range<UInt64> { offset..<(offset + length) }

        public var checksumMatches: Bool {
            storedChecksum == nil || storedChecksum == computedChecksum
        }

        /// How the entries' locations read (`AddressMode`), from `info`: bits
        /// 24–25 when bit 31 marks the newer layout, bits 29–30 otherwise.
        public var addressMode: AddressMode {
            guard !kind.isCombo, kind != .slotHeader else { return .physical }
            let mode = info & 0x8000_0000 != 0 ? (info >> 24) & 3 : (info >> 29) & 3
            return AddressMode(rawValue: UInt8(mode)) ?? .physical
        }
    }

    /// One word of the EFS that points at a directory.
    public struct Pointer: Equatable, Sendable {
        /// Where in the EFS the word is.
        public var field: UInt64
        public var value: UInt32
        public var target: UInt64
    }

    public var efsOffset: UInt64
    /// The EFS's words that lead to a directory, in their order.
    public var pointers: [Pointer]
    /// Every directory the walk reached, in the order it reached them.
    public var directories: [Directory]
    /// The flash the addresses are mapped over: 8, 16 or 32 MiB.
    public var romSize: UInt64

    public var efsRange: Range<UInt64> { efsOffset..<(efsOffset + Self.efsLength) }

    /// Every entry with a blob in the image, each blob once, with the
    /// directory it is in. Two entries that name one start are one blob, at
    /// the smaller of their sizes: a first-level directory gives the PSP's
    /// boot loader the room it may take, the second level its length, and
    /// the room runs over the blobs after it.
    public var blobs: [(entry: Entry, directory: Directory)] {
        var byStart: [UInt64: (entry: Entry, directory: Directory)] = [:]
        var order: [UInt64] = []
        for directory in directories {
            for entry in directory.entries where !entry.pointsAtDirectory {
                guard let range = entry.range else { continue }
                if let kept = byStart[range.lowerBound] {
                    if let keptRange = kept.entry.range, range.count < keptRange.count {
                        byStart[range.lowerBound] = (entry, directory)
                    }
                } else {
                    byStart[range.lowerBound] = (entry, directory)
                    order.append(range.lowerBound)
                }
            }
        }
        return order.compactMap { byStart[$0] }
    }

    // MARK: - Reading

    /// The map in `reader`, or nil when there is no EFS that leads to a
    /// directory.
    public static func read(_ reader: ImageReader) -> AMDFirmware? {
        guard reader.count >= 0x80_0000 else { return nil }
        let romSize = romSize(forFileSize: reader.count)
        for offset in efsOffsets where offset + efsLength <= reader.count {
            guard reader.uint32(at: offset) == efsSignature else { continue }
            var walk = Walk(reader: reader, romSize: romSize)
            var pointers: [Pointer] = []
            var field: UInt64 = 4
            while field < efsLength, let value = reader.uint32(at: offset + field) {
                defer { field += 4 }
                guard value != 0, value != 0xFFFF_FFFF, value != 0xFFFF_FFFE else { continue }
                let target = walk.physical(UInt64(value))
                guard walk.visit(target, cameFrom: .efs) else { continue }
                pointers.append(Pointer(field: field, value: value, target: target))
            }
            guard !pointers.isEmpty else { continue }
            return AMDFirmware(efsOffset: offset, pointers: pointers, directories: walk.directories, romSize: romSize)
        }
        return nil
    }

    /// The flash the image is taken to be: the largest of 32, 16 and 8 MiB
    /// that the file holds — a dump with bytes appended is still its chip.
    static func romSize(forFileSize size: UInt64) -> UInt64 {
        for mebibytes: UInt64 in [32, 16, 8] where mebibytes << 20 <= size { return mebibytes << 20 }
        return size
    }

    /// The directories as the pointers lead to them, each read once.
    private struct Walk {
        enum Origin { case efs, combo, entry, slot }

        let reader: ImageReader
        let romSize: UInt64
        var directories: [Directory] = []
        var visited = Set<UInt64>()

        /// A memory-mapped address — or an offset already — as a flash offset.
        /// Past 16 MiB only the first 16 are mapped.
        func physical(_ address: UInt64) -> UInt64 {
            if address > 0xFF00_0000, romSize > 0x100_0000 { return address & 0xFF_FFFF }
            return address & (romSize - 1)
        }

        /// Reads the directory at `offset` and everything it leads to. False
        /// when there is none there.
        mutating func visit(_ offset: UInt64, cameFrom origin: Origin, slot: String? = nil) -> Bool {
            if visited.contains(offset) { return true }
            guard offset + 0x10 <= reader.count, let signature = reader.bytes(at: offset, count: 4) else {
                return false
            }
            if let kind = DirectoryKind.kind(signature: signature) {
                // The EFS points at first-level and combo directories only.
                if origin == .efs, kind == .pspLevel2 || kind == .biosLevel2 { return false }
                visited.insert(offset)
                if kind.isCombo { return readCombo(kind, at: offset) }
                return readDirectory(kind, at: offset)
            }
            // A slot pointer leads to a slot header — or, on some boards,
            // straight to the directory.
            guard origin == .slot, let slot else { return false }
            return readSlotHeader(at: offset, slot: slot)
        }

        private mutating func readDirectory(_ kind: DirectoryKind, at offset: UInt64) -> Bool {
            guard let count = reader.uint32(at: offset + 8), count > 0, count <= 0x200,
                  let info = reader.uint32(at: offset + 12)
            else { return false }
            let length = kind.headerSize + UInt64(count) * kind.entrySize
            guard offset + length <= reader.count else { return false }
            var directory = Directory(
                kind: kind, offset: offset, length: length, entries: [], comboEntries: [], info: info,
                storedChecksum: reader.uint32(at: offset + 4),
                computedChecksum: reader.bytes((offset + 8)..<(offset + length)).map(AMDFirmware.fletcher32)
            )
            for index in 0..<Int(count) {
                let at = offset + kind.headerSize + UInt64(index) * kind.entrySize
                guard let type = reader.uint8(at: at), let subtype = reader.uint8(at: at + 1),
                      let flags = reader.uint16(at: at + 2), let size = reader.uint32(at: at + 4),
                      let location = reader.uint64(at: at + 8)
                else { break }
                var entry = Entry(
                    index: index, type: type, subtype: subtype, flags: flags, size: size, location: location,
                    destination: kind.isBIOS ? reader.uint64(at: at + 16) : nil,
                    isBIOS: kind.isBIOS, range: nil, resolvedOffset: nil
                )
                if !entry.isValue, location != 0 {
                    let resolved = resolve(location, in: directory)
                    entry.resolvedOffset = resolved
                    // A compressed BIOS image's size is what it inflates to;
                    // what the flash holds is AMD's header and the stream.
                    let stored = entry.isCompressed
                        ? AMDFirmware.compressedLength(at: resolved, in: reader) : nil
                    entry.isStoredCompressed = stored != nil
                    let length = stored ?? UInt64(size)
                    if length > 0, resolved < reader.count, resolved + length <= reader.count {
                        entry.range = resolved..<(resolved + length)
                    }
                }
                directory.entries.append(entry)
            }
            directories.append(directory)
            for entry in directory.entries where entry.pointsAtDirectory {
                guard let target = entry.resolvedOffset else { continue }
                switch (entry.isBIOS, entry.type) {
                case (false, 0x48): _ = visit(target, cameFrom: .slot, slot: "A")
                case (false, 0x4A): _ = visit(target, cameFrom: .slot, slot: "B")
                default: _ = visit(target, cameFrom: .entry)
                }
            }
            return true
        }

        private mutating func readCombo(_ kind: DirectoryKind, at offset: UInt64) -> Bool {
            guard let count = reader.uint32(at: offset + 8), count > 0, count <= 0x40,
                  let info = reader.uint32(at: offset + 12)
            else { return false }
            let length = kind.headerSize + UInt64(count) * kind.entrySize
            guard offset + length <= reader.count else { return false }
            var directory = Directory(
                kind: kind, offset: offset, length: length, entries: [], comboEntries: [], info: info,
                storedChecksum: reader.uint32(at: offset + 4),
                computedChecksum: reader.bytes((offset + 8)..<(offset + length)).map(AMDFirmware.fletcher32)
            )
            for index in 0..<Int(count) {
                let at = offset + kind.headerSize + UInt64(index) * 16
                guard let selector = reader.uint32(at: at), let id = reader.uint32(at: at + 4),
                      let location = reader.uint64(at: at + 8)
                else { break }
                let low = location & 0xFFFF_FFFF
                let resolved = low == 0 || low == 0xFFFF_FFFF ? nil : physical(low)
                directory.comboEntries.append(ComboEntry(selector: selector, id: id, location: location,
                                                         resolvedOffset: resolved))
            }
            directories.append(directory)
            for entry in directory.comboEntries {
                guard let target = entry.resolvedOffset else { continue }
                let before = directories.count
                _ = visit(target, cameFrom: .combo)
                // The directory a combo entry chose is the one for its id.
                if directories.count > before, directories[before].pspID == nil {
                    directories[before].pspID = entry.id
                }
            }
            return true
        }

        private mutating func readSlotHeader(at offset: UInt64, slot: String) -> Bool {
            guard offset + 0x20 <= reader.count,
                  let priority = reader.uint32(at: offset + 4),
                  let target = reader.uint32(at: offset + 0x10),
                  let pspID = reader.uint32(at: offset + 0x14)
            else { return false }
            let resolved = physical(UInt64(target))
            // Only a header whose second level is there is one.
            guard resolved + 4 <= reader.count, let signature = reader.bytes(at: resolved, count: 4),
                  let kind = DirectoryKind.kind(signature: signature), kind == .pspLevel2 || kind == .psp
            else { return false }
            visited.insert(offset)
            directories.append(Directory(
                kind: .slotHeader, offset: offset, length: 0x20, entries: [], comboEntries: [], info: 0,
                storedChecksum: nil, computedChecksum: nil, pspID: pspID, slot: slot, priority: priority,
                slotTarget: resolved
            ))
            let before = directories.count
            _ = visit(resolved, cameFrom: .entry)
            if directories.count > before, directories[before].pspID == nil {
                directories[before].pspID = pspID
            }
            return true
        }

        /// An entry's location as a flash offset, by the directory's address
        /// mode — or the entry's own, where the directory says entries carry
        /// one — the way PSPTool reads them.
        func resolve(_ location: UInt64, in directory: Directory) -> UInt64 {
            let value = location & 0xFFFF_FFFF
            let entryMode = AddressMode(rawValue: UInt8((location >> 62) & 3)) ?? .physical
            var mode = directory.addressMode
            if mode == .directoryRelative || mode == .slotRelative {
                mode = entryMode
            } else if mode == .flashOffset, entryMode == .physical, value >= 0xFF00_0000 {
                // coreboot writes some entries of a mode-1 directory as
                // physical addresses; no flash offset reaches 0xFF000000.
                mode = .physical
            }
            switch mode {
            case .physical: return physical(value)
            case .flashOffset: return value
            case .directoryRelative, .slotRelative: return directory.offset + value
            }
        }
    }

    /// What a compressed BIOS image takes in the flash: the 0x100-byte header
    /// AMD puts in front of a zlib stream — zeros but for the stream's length
    /// at `+0x14` — and the stream. Nil when the bytes at `offset` are not
    /// that header followed by a zlib stream.
    public static func compressedLength(at offset: UInt64, in reader: ImageReader) -> UInt64? {
        guard let stored = reader.uint32(at: offset + CompressedSection.amdZlibCompressedSizeOffset), stored > 0,
              let first = reader.uint8(at: offset + CompressedSection.amdZlibHeaderSize),
              let second = reader.uint8(at: offset + CompressedSection.amdZlibHeaderSize + 1),
              first & 0x0F == 8, (UInt16(first) << 8 | UInt16(second)) % 31 == 0
        else { return nil }
        let length = CompressedSection.amdZlibHeaderSize + UInt64(stored)
        return offset + length <= reader.count ? length : nil
    }

    // MARK: - The checksum

    /// Fletcher-32 over 16-bit little-endian words, folded as the PSP folds
    /// it — what a directory's second word holds for the bytes after it.
    public static func fletcher32(_ bytes: [UInt8]) -> UInt32 {
        var c0: UInt64 = 0xFFFF
        var c1: UInt64 = 0xFFFF
        var index = 0
        var word = 0
        while index + 1 < bytes.count {
            c0 += UInt64(bytes[index]) | UInt64(bytes[index + 1]) << 8
            c1 += c0
            if word % 360 == 0 {
                c0 = (c0 & 0xFFFF) + (c0 >> 16)
                c1 = (c1 & 0xFFFF) + (c1 >> 16)
            }
            index += 2
            word += 1
        }
        for _ in 0..<2 {
            c0 = (c0 & 0xFFFF) + (c0 >> 16)
            c1 = (c1 & 0xFFFF) + (c1 >> 16)
        }
        return UInt32(truncatingIfNeeded: (c1 << 16) | c0)
    }

    // MARK: - Names

    /// AMD's name for an entry's type. A BIOS directory's own types come
    /// first in one; the rest are the PSP's.
    public static func typeName(_ type: UInt8, inBIOSDirectory: Bool) -> String {
        if inBIOSDirectory, let name = biosTypeNames[type] { return name }
        return pspTypeNames[type] ?? String(format: "Type 0x%02X", type)
    }

    /// The types a BIOS directory has of its own.
    static let biosTypeNames: [UInt8: String] = [
        0x60: "APCB", 0x61: "APOB", 0x62: "BIOS", 0x63: "APOB_NV_COPY", 0x64: "PMU_CODE",
        0x65: "PMU_DATA", 0x66: "MICROCODE_PATCH", 0x67: "CORE_MCE_DATA", 0x68: "APCB_COPY",
        0x69: "EARLY_VGA_IMAGE", 0x6B: "COREBOOT_VBOOT_CONTEXT", 0x6D: "ROM_ARMOR_BIOS_NVSTORE",
        0x6E: "DEBUG_UNIT", 0x6F: "OEM_LOGO_IMAGE", 0x70: "BIOS_L2_PTR", 0x77: "DDRPHY_PCU_FW",
        0x7B: "MPRAS_TRUSTED_APP_IMG", 0x7C: "OC_SWEET_SPOT_PROFILE",
    ]

    /// The PSP's types — and a BIOS directory's where it lists one of them.
    static let pspTypeNames: [UInt8: String] = [
        0x00: "AMD_PUBLIC_KEY", 0x01: "PSP_FW_BOOT_LOADER", 0x02: "PSP_FW_TRUSTED_OS",
        0x03: "PSP_FW_RECOVERY_BOOT_LOADER", 0x04: "PSP_NV_DATA", 0x05: "BIOS_PUBLIC_KEY",
        0x06: "BIOS_RTM_FIRMWARE", 0x07: "BIOS_RTM_SIGNATURE", 0x08: "SMU_OFFCHIP_FW",
        0x09: "SEC_DBG_PUBLIC_KEY", 0x0A: "OEM_PSP_FW_PUBLIC_KEY", 0x0B: "SOFT_FUSE_CHAIN_01",
        0x0C: "PSP_BOOT_TIME_TRUSTLETS", 0x0D: "PSP_BOOT_TIME_TRUSTLETS_KEY", 0x10: "PSP_AGESA_RESUME_FW",
        0x12: "SMU_OFF_CHIP_FW_2", 0x13: "DEBUG_UNLOCK", 0x15: "TEE_IP_KEY_MGR_DRIVER",
        0x1A: "PSP_S3_NV_DATA_OR_SEV_DRIVER", 0x1B: "TEE_BOOT_DRIVER", 0x1C: "TEE_SOC_DRIVER",
        0x1D: "TEE_FBG_DRIVER", 0x1F: "TEE_INTERFACE_DRIVER", 0x20: "HARDWARE_IP_CONFIG",
        0x21: "WRAPPED_IKEK", 0x22: "TOKEN_UNLOCK", 0x23: "PSP_DIAG_BL", 0x24: "SEC_GASKET",
        0x25: "MP2_FW", 0x26: "MP2_FW_2", 0x27: "USER_MODE_UNIT_TEST", 0x28: "DRIVER_ENTRIES",
        0x29: "KVM_IMAGE", 0x2A: "MP5_FW", 0x2B: "EMBEDDED_FW_STRUCTURE", 0x2C: "TEE_WRITE_ONCE_NVRAM",
        0x2D: "S0I3_DRIVER", 0x2E: "PREMIUM_CHIPSET_MP0_DXIO_FW", 0x2F: "PREMIUM_CHIPSET_MP1_FW",
        0x30: "ABL0", 0x31: "ABL1", 0x32: "ABL2", 0x33: "ABL3", 0x34: "ABL4", 0x35: "ABL5",
        0x36: "ABL6", 0x37: "ABL7", 0x38: "SEV_DATA", 0x39: "SEV_CODE", 0x3A: "FW_PSP_WHITELIST",
        0x3C: "VBIOS_PRELOAD", 0x3D: "WLAN_UMAC", 0x3E: "WLAN_IMAC", 0x3F: "WLAN_BT",
        0x40: "PSP_FW_L2_PTR", 0x41: "FW_IMC", 0x42: "FW_GEC_OR_DXIO_PHY_SRAM_FW",
        0x43: "DXIO_PHY_SRAM_FW_PUBKEY", 0x44: "FW_XHCI", 0x45: "TOS_SECURITY_POLICY",
        0x46: "ANOTHER_FET", 0x47: "DRTM_TA", 0x48: "PSP_FW_L2A_PTR", 0x49: "BIOS_L2AB_PTR",
        0x4A: "PSP_FW_L2B_PTR", 0x4B: "RESERVED", 0x4C: "PREMIUM_CHIPSET_SEC_POLICY",
        0x4D: "PREMIUM_CHIPSET_DEBUG_UNLOCK", 0x4E: "PMU_PUBKEY", 0x4F: "UMC_FW",
        0x50: "BL_PUBLIC_KEY", 0x51: "TOS_PUBLIC_KEY", 0x52: "OEM_PSP_BL_USER_APP",
        0x53: "OEM_PSP_BL_USER_APP_KEY", 0x54: "PSP_NVRAM", 0x55: "BL_ROLLBACK_SPL",
        0x56: "TOS_ROLLBACK_SPL", 0x57: "PSP_BL_CVIP_TABLE", 0x58: "DMCU_ERAM", 0x59: "DMCU_ISR",
        0x5A: "MSMU_BINARY_0", 0x5B: "MSMU_BINARY_1", 0x5C: "SPI_ROM_CONFIG", 0x5D: "MPIO_FW",
        0x5E: "DF_TOPOLOGY", 0x5F: "FW_PSP_SMUSCS_OR_TPMLITE", 0x64: "TEE_RAS_DRIVER",
        0x65: "TEE_RAS_TRUSTED_APP", 0x67: "TEE_FHP_DRIVER_FW", 0x68: "TEE_SPDM_DRIVER_FW",
        0x69: "TEE_DPE_DRIVER_FW", 0x6A: "TEE_PRE_MEM_DRIVER_FW", 0x6B: "TEE_MP_RAS_DRIVER_FW",
        0x6C: "TEE_POST_MEM_DRIVER_FW", 0x70: "BIOS_L2_PTR", 0x71: "PSP_DMCUB_CODE",
        0x72: "PSP_DMCUB_DATA", 0x73: "PSP_FW_BOOT_LOADER", 0x74: "PSP_PLATFORM_DRIVER",
        0x75: "FW_SOFT_FUSING_BINARY", 0x76: "REGISTER_INIT_BIN", 0x80: "OEM_SYS_TA",
        0x81: "OEM_SYS_TA_SIGNING_KEY", 0x82: "IKEK_OEM", 0x84: "TKEK_OEM", 0x85: "AMF_FW1",
        0x86: "AMF_FW2", 0x87: "MFD_MPM_FACTORY", 0x88: "MFD_MPM_WLAN_FW", 0x89: "MPM_DRIVER",
        0x8A: "USB4_PHY_FW", 0x8B: "FIPS_CERTIFICATION_MODULE", 0x8C: "MPDMA_TF_FW", 0x8D: "IKEK_TA",
        0x8E: "SEC_FW_DATA_RECORDER", 0x8F: "OFFCHIP_USB4_FW", 0x90: "CCX_CORE_INIT_AND_PM",
        0x91: "GMI3_PHY_FW", 0x92: "MPDMA_MPDACC_TIERED_MEMORY_PAGE_MIGRATION_FW", 0x93: "PROM21_FW",
        0x94: "LSDMA_FW", 0x95: "C20_PHY_FW", 0x96: "NPU_FW", 0x97: "AMD_SFFS_PUBKEY",
        0x98: "CPU_FEAT_CONFIG_TBL", 0x99: "PMF_BINARY", 0x9A: "REDUCED_MSMU_SIZE",
        0x9B: "GFX_IMU_LX7_CODE", 0x9C: "GFX_IMU_LX7_DATA", 0x9D: "FW_ROM_OR_FIPS_SRAM",
        0x9E: "SFDR_DATA", 0x9F: "REG_ACCESS_WHITELIST", 0xA0: "CPU_S3_IMAGE",
        0xA2: "UZSC_RESET_WORKAROUND", 0xA3: "USB_NATIVE_DP", 0xA4: "USB_TYPEC_DP", 0xA5: "USB_SS_FW",
        0xA6: "USB4", 0xA7: "OFFCHIP_XHCI_SATA_PCIE", 0xAA: "ASP_LIBSEC", 0xAB: "ART_FMC_IMG",
        0xAC: "ART_RUNTIME_FW", 0xAD: "ART_KEY_DATABASE", 0xAE: "SEC_ASP_LIBROM_OVERLAY_FW",
        0xB0: "MPM_CONTEXT",
    ]
}

extension AMDFirmware {
    /// What a kind of directory is, in words.
    public static func kindName(_ kind: DirectoryKind) -> String {
        switch kind {
        case .psp: return L("PSP directory")
        case .pspLevel2: return L("PSP level 2 directory")
        case .bios: return L("BIOS directory")
        case .biosLevel2: return L("BIOS level 2 directory")
        case .pspCombo: return L("PSP combo directory")
        case .biosCombo: return L("BIOS combo directory")
        case .slotHeader: return L("Image slot header")
        }
    }

    /// What a directory is called: what it is, and its signature.
    public static func directoryName(_ directory: Directory) -> String {
        let signature = directory.kind.signature ?? ""
        switch directory.kind {
        case .psp: return L("PSP directory %1$@", signature)
        case .pspLevel2: return L("PSP level 2 directory %1$@", signature)
        case .bios: return L("BIOS directory %1$@", signature)
        case .biosLevel2: return L("BIOS level 2 directory %1$@", signature)
        case .pspCombo: return L("PSP combo directory %1$@", signature)
        case .biosCombo: return L("BIOS combo directory %1$@", signature)
        case .slotHeader: return L("Image slot header %1$@", directory.slot ?? "")
        }
    }

    /// What a blob is called: AMD's name for its type, and its instance where
    /// it has one — the PMU firmware comes in one per kind of memory.
    public static func entryName(_ entry: Entry) -> String {
        entry.instance == 0 ? entry.typeName : L("%1$@, instance %2$@", entry.typeName, "\(entry.instance)")
    }

}

extension Parser {
    /// The PSP's map of the image this parser reads, worked out once: every
    /// raw area the parser scans asks.
    var amdFirmware: AMDFirmware? {
        if let cached = amdFirmwareCache { return cached }
        let found = AMDFirmware.read(reader)
        amdFirmwareCache = .some(found)
        return found
    }

    /// `nodes` with the PSP's map read out of the padding that holds it
    /// (§9): the EFS, every directory, and every blob a directory lists, each
    /// as a row where a stretch of padding — or an Insyde map's region —
    /// holds the whole of it. A blob something else already reads, a patch
    /// of microcode or a volume, keeps that row; the directory's details
    /// lead to it all the same.
    func readingAMDFirmware(_ nodes: [UEFINode], emptyByte: UInt8, depth: Int) -> [UEFINode] {
        guard let firmware = amdFirmware else { return nodes }
        var result = nodes
        for node in Self.amdFirmwareNodes(firmware, depth: depth) {
            result = placingInLayout(node, in: result, inner: false, emptyByte: emptyByte) ?? result
        }
        return result
    }

    /// The rows the map gives: the EFS, the directories, then the blobs by
    /// where they lie. A compressed BIOS image is left closed, as a
    /// compressed section is, and opens to what it inflates to.
    static func amdFirmwareNodes(_ firmware: AMDFirmware, depth: Int) -> [UEFINode] {
        var nodes = [UEFINode(
            kind: .amdEFS,
            name: L("Embedded Firmware Structure"),
            header: firmware.efsRange,
            body: firmware.efsRange.upperBound..<firmware.efsRange.upperBound,
            // The PSP looks for it where it is.
            isFixed: true
        )]
        for directory in firmware.directories {
            let headerEnd = directory.offset + directory.kind.headerSize
            nodes.append(UEFINode(
                kind: .amdDirectory,
                subtype: directory.kind.rawValue,
                name: AMDFirmware.directoryName(directory),
                header: directory.offset..<min(headerEnd, directory.range.upperBound),
                body: min(headerEnd, directory.range.upperBound)..<directory.range.upperBound,
                isFixed: true
            ))
        }
        for blob in firmware.blobs.sorted(by: { $0.entry.range!.lowerBound < $1.entry.range!.lowerBound }) {
            guard let range = blob.entry.range else { continue }
            let compressed = blob.entry.isStoredCompressed
            let bodyStart = compressed ? range.lowerBound + CompressedSection.amdZlibHeaderSize : range.lowerBound
            nodes.append(UEFINode(
                kind: .amdFirmwareEntry,
                subtype: blob.entry.type,
                name: AMDFirmware.entryName(blob.entry),
                header: range.lowerBound..<bodyStart,
                body: bodyStart..<range.upperBound,
                isFixed: true,
                compression: compressed
                    ? SectionCompression(algorithm: CompressedSection.Algorithm.zlibAMD.name, decodes: true) : nil,
                isExpandable: compressed,
                childDepth: depth + 1
            ))
        }
        return nodes
    }

    /// `nodes` with `found` laid in the deepest stretch of padding — or Insyde
    /// map region, or blob — that holds the whole of it, the way a FIT
    /// structure is laid in padding: a stretch at the top keeps its row and
    /// gets rows of its own, a padding row inside one is replaced by the rows
    /// around `found`.
    ///
    /// Inside a stretch, `found` may also hold rows already read — the
    /// microcode patch a Zen 4 entry wraps in a header of its own, the EFS
    /// inside a BIOS image — and then takes them in as its own rows, cutting
    /// the padding at its edges. Nil when what holds it is something else — a
    /// volume, a row already read — or nothing at all.
    func placingInLayout(_ found: UEFINode, in nodes: [UEFINode], inner: Bool, emptyByte: UInt8) -> [UEFINode]? {
        if let index = nodes.firstIndex(where: {
            $0.range.lowerBound <= found.range.lowerBound && found.range.upperBound <= $0.range.upperBound
        }) {
            var node = nodes[index]
            guard node.space == found.space, Self.holdsAMDFirmware(node) else { return nil }
            var result = nodes
            if !node.children.isEmpty {
                guard let children = placingInLayout(found, in: node.children, inner: true, emptyByte: emptyByte)
                else { return nil }
                node.children = children
                result[index] = node
                return result
            }
            let pieces = padding(from: node.range.lowerBound, to: found.range.lowerBound, emptyByte: emptyByte)
                + [found]
                + padding(from: found.range.upperBound, to: node.range.upperBound, emptyByte: emptyByte)
            if inner, node.kind == .padding {
                result.replaceSubrange(index...index, with: pieces)
            } else {
                node.children = pieces
                result[index] = node
            }
            return result
        }
        return inner ? wrapping(found, around: nodes, emptyByte: emptyByte) : nil
    }

    /// `nodes` — the rows of one stretch — with `found` standing over a run
    /// of them: the rows wholly inside it become its own, and a padding row
    /// it reaches only into is cut at its edge. Nil when an edge falls in a
    /// row that is not padding.
    private func wrapping(_ found: UEFINode, around nodes: [UEFINode], emptyByte: UInt8) -> [UEFINode]? {
        let touched = nodes.indices.filter { nodes[$0].range.overlaps(found.range) }
        guard let first = touched.first, let last = touched.last else { return nil }
        var inside: [UEFINode] = []
        var before: [UEFINode] = []
        var after: [UEFINode] = []
        for index in first...last {
            let node = nodes[index]
            guard node.space == found.space else { return nil }
            if found.range.lowerBound <= node.range.lowerBound, node.range.upperBound <= found.range.upperBound {
                inside.append(node)
                continue
            }
            // Cut at an edge: only a padding row with nothing read in it.
            guard node.kind == .padding, node.children.isEmpty else { return nil }
            if node.range.lowerBound < found.range.lowerBound {
                before += padding(from: node.range.lowerBound, to: found.range.lowerBound, emptyByte: emptyByte)
                inside += padding(from: found.range.lowerBound, to: min(node.range.upperBound, found.range.upperBound),
                                  emptyByte: emptyByte)
            }
            if node.range.upperBound > found.range.upperBound {
                if node.range.lowerBound >= found.range.lowerBound {
                    inside += padding(from: node.range.lowerBound, to: found.range.upperBound, emptyByte: emptyByte)
                }
                after += padding(from: found.range.upperBound, to: node.range.upperBound, emptyByte: emptyByte)
            }
        }
        // The bytes of `found` no row covered are padding too.
        var wrapped = found
        var rows: [UEFINode] = []
        var at = found.range.lowerBound
        for node in inside.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            rows += padding(from: at, to: node.range.lowerBound, emptyByte: emptyByte)
            rows.append(node)
            at = node.range.upperBound
        }
        rows += padding(from: at, to: found.range.upperBound, emptyByte: emptyByte)
        wrapped.children = rows
        var result = nodes
        result.replaceSubrange(first...last, with: before + [wrapped] + after)
        return result
    }

    /// Whether `node` is somewhere the PSP's structures are laid in: padding
    /// that is not an EC image's, an Insyde map's region, a blob.
    private static func holdsAMDFirmware(_ node: UEFINode) -> Bool {
        switch node.kind {
        case .flashDeviceMapRegion, .amdFirmwareEntry: return true
        case .padding: return !ECImage.isECFirmwarePadding(node)
        default: return false
        }
    }
}
