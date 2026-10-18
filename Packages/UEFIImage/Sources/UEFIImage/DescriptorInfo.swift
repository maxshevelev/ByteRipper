import Foundation

/// What a flash descriptor says about itself, beyond the regions it maps: the
/// reserved vector it opens with, the chipset generation its layout is, where
/// each region it declares begins and ends, how many flash chips the image
/// spans and how fast the chipset clocks them, which master may read and
/// write which region, the chips its VSCC table knows how to drive, and its
/// PCH straps (§2).
///
/// The regions are already the tree — a descriptor's children are its regions —
/// but the rest of this is not anywhere else in the app, and it is what a bench
/// asks a descriptor: *can the BIOS master even write the ME region on this
/// board, and is the chip I am about to solder on one this firmware knows?*
///
/// Read as a value, once, so the detail panel formats rather than parses, and
/// so the reading itself is testable without a window.
public struct DescriptorInfo: Equatable, Sendable {
    /// The sixteen bytes before the signature. Reserved, and reliably not zero:
    /// on many boards they are the first instruction the chip ever executes.
    public var reservedVector: [UInt8]

    /// The chipset generation the layout is (`DescriptorGeneration`), and
    /// whether the layout is one the rules know rather than the nearest they
    /// assume.
    public var generation: DescriptorGeneration
    public var isGenerationCertain: Bool

    /// A region the descriptor declares, where it begins and where it ends —
    /// inclusive, as the table writes it — in the file's own offsets.
    public struct Region: Equatable, Sendable {
        public var type: FlashRegionType
        public var base: UInt64
        public var limit: UInt64
    }

    /// In the format's region order, the descriptor's own first.
    public var regions: [Region]

    /// The component section (§2.4): the flash chips the image was laid out
    /// for and how the chipset drives them. Nil when its base is not one.
    public var component: Component?

    public struct Component: Equatable, Sendable {
        /// Each chip's size in bytes, one entry per chip the map counts. Nil
        /// for a density code the generation reserves.
        public var chipSizes: [UInt64?]
        /// The clock for reading the chip's id and status.
        public var readIDClock: Clock
        /// The clock for writing and erasing.
        public var writeEraseClock: Clock
        /// The clock for fast reads, nil when fast reads are off.
        public var fastReadClock: Clock?
        /// The opcodes the chipset refuses to send to the chip — four, or
        /// eight from Sunrise Point on — with the unused zero ones left out.
        public var invalidInstructions: [UInt8]
    }

    /// A three-bit clock code and what the generation makes of it.
    public struct Clock: Equatable, Sendable {
        public var code: UInt8
        /// In MHz; two when the generation gives the code two, nil when it
        /// reserves it.
        public var megahertz: [Int]?
    }

    /// One master's read and write masks. Each bit stands for a region — the
    /// `RegionAccess` bits — so a master's word says which regions it may
    /// touch rather than how.
    public struct Master: Equatable, Sendable {
        public var name: String
        public var read: UInt32
        public var write: UInt32
    }

    /// BIOS, ME, GbE — and EC where the descriptor is new enough to have one.
    public var masters: [Master]

    /// How wide a mask is written: two hex digits on a version 1 descriptor,
    /// where a mask is a byte, and three on a version 2, where it is twelve
    /// bits. UEFITool writes them the same way, and the width is the only sign
    /// on screen of which kind of descriptor this is.
    public var maskDigits: Int

    /// What the BIOS master may do to each region — the question behind
    /// "why can't my programmer write this area from inside the OS".
    public struct Access: Equatable, Sendable {
        public var region: String
        public var read: Bool
        public var write: Bool
    }

    public var biosAccess: [Access]

    /// A chip in the VSCC table: the JEDEC id the table lists, and the chip
    /// that id names when it is one the catalogue knows. For an id it does not
    /// know, `vendor` is still the maker the first byte names, when that code
    /// is one `FlashVendors` has.
    public struct Chip: Equatable, Sendable {
        public var jedecID: UInt32
        public var name: String?
        public var vendor: String?
        /// The chip's capacity in kilobytes, when the catalogue lists one.
        public var sizeKB: Int?
        /// Where the catalogue took the name from; nil when it has none.
        public var source: Source?

        public enum Source: Equatable, Sendable { case uefiTool, linux, flashrom }

        public init(jedecID: UInt32, name: String?, vendor: String? = nil,
                    sizeKB: Int? = nil, source: Source? = nil) {
            self.jedecID = jedecID
            self.name = name
            self.vendor = vendor
            self.sizeKB = sizeKB
            self.source = source
        }
    }

    public var chips: [Chip]

    /// The PCH strap section (§2.6): the words the chipset reads at power-on,
    /// before any firmware runs. Nil when its base is not one or it is empty.
    public var straps: Straps?

    /// The strap words as they stand, and where a table of the section's
    /// length is at hand, the fields they are made of. The layout is the
    /// chipset's and changes with every generation — and between the mobile
    /// and desktop parts of one — and next to none of it is published, which
    /// is what `DescriptorStrapMap` is: Intel's own layout, taken from the
    /// Flash Image Tool that writes the section.
    public struct Straps: Equatable, Sendable {
        /// Where the first word lies, in the file's own offsets.
        public var base: UInt64
        public var words: [UInt32]
        /// The one bit with a settled meaning on every generation that names
        /// it; nil on one that does not, or a section too short to hold it.
        public var meDisable: MEDisable?
        /// The clock the chipset drives the eSPI bus to the EC at. Nil where
        /// the layout is not one whose word for it is known.
        public var espiClock: ESPIClock?
        /// The flash range the chipset protects from the host, from the
        /// strap the SPI controller loads its GPR0 register from. Nil where
        /// the layout is not one whose word for it is known.
        public var gpr0: ProtectedRange?
        /// The section read as the fields of its layout, each with what this
        /// image holds there. Nil where no table of this length is at hand,
        /// in which case the words above are all there is to say.
        public var fields: [DescriptorStrapMap.Reading]?
    }

    /// The processor strap section — the words the processor reads at
    /// power-on, in the descriptor's third map word (`FLMAP2`). Nil from Tiger
    /// Point on, where that word names the section's place in the PMC's space
    /// instead and the section is no longer in the descriptor to read
    /// (`DescriptorGeneration.hasProcessorStrapSection`).
    public struct ProcessorStraps: Equatable, Sendable {
        /// Where the first word lies, in the file's own offsets.
        public var base: UInt64
        public var words: [UInt32]
        /// The section read as the fields of its layout, each with what this
        /// image holds there. Nil where no table of this length is at hand.
        public var fields: [DescriptorStrapMap.Reading]?
    }

    public var processorStraps: ProcessorStraps?

    /// The MIP area's descriptor table, which Cannon Point introduced: a count
    /// and the area's size, then one eight-byte entry per block — type, offset,
    /// length, reserved — whose payload the entry's offset places after the
    /// table. Block type 1 is the PMC and CPU soft straps, type 0 the CSE DbC
    /// configuration. Nil before Cannon Point, and on Meteor Lake and later,
    /// where the area is erased and the byte the table's place came from means
    /// the SoC soft straps instead.
    public struct MIPTable: Equatable, Sendable {
        public struct Block: Equatable, Sendable {
            /// The tool's block type: 0 is the CSE DbC configuration and 1 the
            /// PMC and CPU soft straps.
            public var type: Int
            /// The block's first byte, in the file's own offsets.
            public var base: UInt64
            /// Its place, in bytes, from the table's first byte.
            public var offset: Int
            public var length: Int
            public var words: [UInt32]
        }

        /// The table's first byte, in the file's own offsets.
        public var base: UInt64
        /// `NumberOfDescriptors`.
        public var count: Int
        /// `SizeOfMip`: the area's length in bytes.
        public var size: Int
        public var blocks: [Block]

        /// The CSE DbC configuration, where the table carries one.
        public var dbc: DBCStraps? {
            guard let block = blocks.first(where: { $0.type == 0 }),
                  block.words.count >= 2 else { return nil }
            return DBCStraps(base: block.base, words: block.words)
        }
    }

    /// The CSE DbC configuration — block type 0's two dwords. Every Flash
    /// Image Tool document that states the block agrees on these three masks
    /// in its second word; the variants add the eHAP and DAM bits or the USB2
    /// AFE signal strengths above them, which the documents do not agree on
    /// and which are therefore not claimed here.
    public struct DBCStraps: Equatable, Sendable {
        public var base: UInt64
        public var words: [UInt32]
        public var fields: [DescriptorStrapMap.Reading]

        static let layout: [DescriptorStrapMap.Field] = [
            .init(name: "DbC_Strap_CSME_Early_USB_DbC_ME_Boot_Stall_Enable",
                  word: 1, bits: 16...23, label: "Early USB DbC ME boot stall"),
            .init(name: "DbC_Strap_CSME_USB3_DbC_port_enable",
                  word: 1, bits: 8...15, label: "USB3 DbC port enable"),
            .init(name: "DbC_Strap_CSME_USB2_DbC_port_enable",
                  word: 1, bits: 0...7, label: "USB2 DbC port enable"),
        ]

        init(base: UInt64, words: [UInt32]) {
            self.base = base
            self.words = words
            self.fields = Self.layout.compactMap { field in
                guard field.word < words.count else { return nil }
                return DescriptorStrapMap.Reading(
                    field: field, value: field.value(in: words[field.word]))
            }
        }
    }

    public var mip: MIPTable?

    /// The descriptor's registers read through Flash Image Tool's own layouts
    /// (`DescriptorRegisterMap`): FLMAP0/1/2, FLCOMP and FLIL at the component
    /// base, the masters' FLMSTR registers, FLDRPLCY and FLUMAP1. Empty where
    /// the generation has no map emitted, or a register's base is not readable.
    public var registerReadings: [DescriptorRegisterReading]

    /// The OEM section of §2.4: `0x100` bytes at `0xF00` in the descriptor,
    /// where a board's maker keeps what it likes — a serial, a BIOS version, a
    /// signature — and which is erased on many boards. Empty when the reader
    /// does not reach it.
    public var oemSection: [UInt8]

    /// The eSPI clock: bits 3–5 of its word.
    public struct ESPIClock: Equatable, Sendable {
        public var word: Int
        public var clock: Clock
    }

    /// A GPRD word: a start and an end in 4 KiB units, inclusive, and whether
    /// reads and writes inside are refused. Neither refused, the range is
    /// off whatever it says.
    public struct ProtectedRange: Equatable, Sendable {
        public var word: Int
        /// In the file's own offsets, as the region table's are.
        public var start: UInt64
        public var end: UInt64
        public var readProtected: Bool
        public var writeProtected: Bool

        public var isOn: Bool { readProtected || writeProtected }
    }

    /// The bit that soft-disables the ME, under the name the trade knows it
    /// by on this generation (HAP, AltMeDisable, ICH_MeDisable).
    public struct MEDisable: Equatable, Sendable {
        public var name: String
        public var word: Int
        public var bit: Int
        public var isSet: Bool
    }

    /// The region bits a master's access mask carries (§2.3).
    enum RegionAccess {
        static let descriptor: UInt32 = 0x01
        static let bios: UInt32 = 0x02
        static let me: UInt32 = 0x04
        static let gbe: UInt32 = 0x08
        static let pdr: UInt32 = 0x10
        static let ec: UInt32 = 0x20
    }

    /// The upper map, at a fixed offset near the end of the descriptor, which
    /// says where the VSCC table is and how long it is.
    enum UpperMap {
        static let offset: UInt64 = 0x0EFC
        /// A VSCC entry is two dwords: the id and its register value. The map's
        /// size field counts dwords, so the entry count is half of it.
        static let entrySize: UInt64 = 8
    }
}

public extension DescriptorInfo {
    /// Reads the descriptor at `base`. Nil when there is no readable map there
    /// — the caller has a node that says it is a descriptor, and this says
    /// whether its own header can be believed.
    static func read(at base: UInt64, in reader: ImageReader) -> DescriptorInfo? {
        guard let map = reader.uint32(at: base + Descriptor.mapOffset),
              let map1 = reader.uint32(at: base + Descriptor.map1Offset),
              let (generation, isCertain) = DescriptorGeneration.read(at: base, in: reader),
              let vector = reader.bytes(at: base, count: 16)
        else { return nil }

        // Up to Wildcat Point a master keeps a byte per mask and there is no
        // EC master; from Sunrise Point on twelve bits per mask, and one more.
        let isVersion1 = !generation.hasWideMasks
        // The master section's base is the second map word's low byte, in the
        // 0x10 units every base in this header is written in. Out of range —
        // an erased word says `0xFF` — there is no section to read, and the
        // bytes at whatever that points to are not masters.
        let masterAt = map1 & 0xFF
        let masterBase = (masterAt > 0 && masterAt <= Descriptor.maxBase)
            ? base + UInt64(masterAt) << 4
            : nil

        return DescriptorInfo(
            reservedVector: vector,
            generation: generation,
            isGenerationCertain: isCertain,
            regions: regions(at: base, map: map, generation: generation, reader: reader),
            component: component(at: base, map: map, generation: generation, reader: reader),
            masters: masters(at: masterBase, isVersion1: isVersion1, reader: reader),
            maskDigits: isVersion1 ? 2 : 3,
            biosAccess: biosAccess(at: masterBase, isVersion1: isVersion1, reader: reader),
            chips: chips(at: base, reader: reader),
            straps: straps(at: base, map1: map1, generation: generation, reader: reader),
            processorStraps: processorStraps(at: base, generation: generation,
                                             isGenerationCertain: isCertain,
                                             reader: reader),
            mip: mipTable(at: base, generation: generation, reader: reader),
            registerReadings: registerReadings(at: base, map: map, map1: map1,
                                               generation: generation, reader: reader),
            oemSection: reader.bytes(at: base + Descriptor.oemSectionOffset,
                                     count: Descriptor.oemSectionSize) ?? []
        )
    }

    /// The descriptor's registers through the tool's layout: each register's
    /// place resolved (absolute, or the component/master base the map words
    /// state) and its words read. A register whose base is out of range or
    /// whose words do not fit is left out.
    /// The MIP area's block table: its place from the upper map's high byte,
    /// its count and size, and each block's payload. A table whose entries do
    /// not fit the area, or a payload past the reader's end, is no table —
    /// the erased area of Meteor Lake reads `0xFFFF` throughout and answers
    /// nil by the count check alone.
    static func mipTable(at base: UInt64, generation: DescriptorGeneration,
                         reader: ImageReader) -> MIPTable? {
        guard generation.hasMIPDescriptorTable,
              let upper = reader.uint32(at: base + UpperMap.offset)
        else { return nil }
        let area = Int(upper >> 24)
        guard area > 0, area <= Int(Descriptor.maxBase) else { return nil }
        let tableAt = base + UInt64(area) << 4
        guard let count = reader.uint16(at: tableAt),
              let size = reader.uint16(at: tableAt + 2),
              count > 0, count <= 8
        else { return nil }
        var blocks: [MIPTable.Block] = []
        for index in 0..<Int(count) {
            let entry = tableAt + 4 + UInt64(index) * 8
            guard let type = reader.uint16(at: entry),
                  let offset = reader.uint16(at: entry + 2),
                  let length = reader.uint16(at: entry + 4),
                  let reserved = reader.uint16(at: entry + 6),
                  reserved == 0, offset >= 4 + count * 8, length > 0,
                  length % 4 == 0
            else { return nil }
            let payload = tableAt + UInt64(offset)
            var words: [UInt32] = []
            for word in 0..<(length / 4) {
                guard let value = reader.uint32(at: payload + UInt64(word) * 4)
                else { return nil }
                words.append(value)
            }
            blocks.append(MIPTable.Block(type: Int(type), base: payload,
                                         offset: Int(offset), length: Int(length),
                                         words: words))
        }
        let end = blocks.map { $0.offset + $0.length }.max() ?? 0
        guard Int(size) >= end else { return nil }
        return MIPTable(base: tableAt, count: Int(count), size: Int(size),
                        blocks: blocks)
    }

    private static func registerReadings(
        at base: UInt64, map: UInt32, map1: UInt32,
        generation: DescriptorGeneration, reader: ImageReader
    ) -> [DescriptorRegisterReading] {
        guard let registerMap = DescriptorRegisterMap.forGeneration(generation) else { return [] }
        let componentAt = map & 0xFF
        let masterAt = map1 & 0xFF
        func address(_ place: DescriptorRegisterMap.Place) -> UInt64? {
            switch place {
            case .absolute(let offset):
                return base + UInt64(offset)
            case .flashComponent(let offset):
                guard componentAt > 0, componentAt <= Descriptor.maxBase else { return nil }
                return base + (UInt64(componentAt) << 4) + UInt64(offset)
            case .flashMaster(let offset):
                guard masterAt > 0, masterAt <= Descriptor.maxBase else { return nil }
                return base + (UInt64(masterAt) << 4) + UInt64(offset)
            }
        }
        var readings: [DescriptorRegisterReading] = []
        for register in registerMap.registers {
            guard let start = address(register.place) else { continue }
            var words: [UInt32] = []
            for index in 0..<register.words {
                guard let word = reader.uint32(at: start + UInt64(index) * 4) else { break }
                words.append(word)
            }
            guard words.count == register.words else { continue }
            readings.append(DescriptorRegisterReading(register: register,
                                                      base: start, words: words))
        }
        return readings
    }

    /// The processor straps, where this generation's descriptor keeps them:
    /// the section the classic third map word points at up to Cannon Point, or
    /// — from Tiger Point to Alder Point and the embedded lines — the message
    /// in the MIP area, at `0xC00` plus the offset the same word carries
    /// (`FLMAP2[2:11]`), as many words as `FLMAP2[16:23]` says (§2.7). Nil
    /// where neither applies, where the generation is only assumed (the MIP
    /// reading needs the map word's Tiger Point meaning), or where a section
    /// lies outside the descriptor. Meteor Lake and later are nil by
    /// generation: their descriptor carries no CPU message (it is in the FITC
    /// partition's MIP table), and the map-word bits there mean other straps.
    private static func processorStraps(
        at base: UInt64, generation: DescriptorGeneration,
        isGenerationCertain: Bool, reader: ImageReader
    ) -> ProcessorStraps? {
        if generation.hasProcessorStrapSection {
            return classicProcessorStraps(at: base, reader: reader)
        }
        guard generation.hasMIPProcessorStraps, isGenerationCertain,
              let map2 = reader.uint32(at: base + Descriptor.map2Offset)
        else { return nil }
        let offset = UInt64((map2 >> 2) & 0x3FF)
        let count = UInt64((map2 >> 16) & 0xFF)
        guard count > 0, Descriptor.mipOffset + offset + count * 4 <= Descriptor.size
        else { return nil }
        let section = base + Descriptor.mipOffset + offset
        var words: [UInt32] = []
        for index in 0..<count {
            guard let word = reader.uint32(at: section + index * 4) else { break }
            words.append(word)
        }
        guard !words.isEmpty else { return nil }
        let map = DescriptorStrapMap.forMIPProcessorSection(words: words.count)
        return ProcessorStraps(base: section, words: words,
                               fields: map?.readings(in: words))
    }

    /// The processor strap section of the classic map word, at its base and as
    /// long as its count — the fields Tiger Point stopped writing. Cut at the
    /// descriptor's end, as the PCH section is.
    private static func classicProcessorStraps(
        at base: UInt64, reader: ImageReader
    ) -> ProcessorStraps? {
        guard let map2 = reader.uint32(at: base + Descriptor.map2Offset) else { return nil }
        let strapAt = map2 & 0xFF
        guard strapAt > 0, strapAt <= Descriptor.maxBase else { return nil }
        let offset = UInt64(strapAt) << 4
        let count = min(UInt64(map2 >> 8 & 0xFF), (Descriptor.size - offset) / 4)
        guard count > 0 else { return nil }
        let section = base + offset
        var words: [UInt32] = []
        for index in 0..<count {
            guard let word = reader.uint32(at: section + index * 4) else { break }
            words.append(word)
        }
        guard !words.isEmpty else { return nil }
        let map = DescriptorStrapMap.forProcessorSection(words: words.count)
        return ProcessorStraps(base: section, words: words,
                               fields: map?.readings(in: words))
    }

    /// The PCH strap section, at `PchStrapBase << 4`, as many words long as
    /// the map's strap length says — cut at the descriptor's end, past which
    /// nothing is a strap however long an erased length claims to be.
    private static func straps(
        at base: UInt64, map1: UInt32, generation: DescriptorGeneration, reader: ImageReader
    ) -> Straps? {
        let strapAt = map1 >> 16 & 0xFF
        guard strapAt > 0, strapAt <= Descriptor.maxBase else { return nil }
        let offset = UInt64(strapAt) << 4
        let count = min(UInt64(map1 >> 24), (Descriptor.size - offset) / 4)
        let section = base + offset
        var words: [UInt32] = []
        for index in 0..<count {
            guard let word = reader.uint32(at: section + index * 4) else { break }
            words.append(word)
        }
        guard !words.isEmpty else { return nil }
        let meDisable = generation.meDisableBit.flatMap { bit -> MEDisable? in
            guard bit.word < words.count else { return nil }
            return MEDisable(name: bit.name, word: bit.word, bit: bit.bit,
                             isSet: words[bit.word] >> bit.bit & 1 != 0)
        }
        // The chipset's layout of this length, where one is at hand: what
        // names the words and says which of them the two fields below are.
        let map = DescriptorStrapMap.forSection(words: words.count)
        var straps = Straps(base: section, words: words, meDisable: meDisable,
                            fields: map?.readings(in: words))
        if let field = map?.espiClockField, field.word < words.count {
            let code = UInt8(field.value(in: words[field.word]))
            straps.espiClock = ESPIClock(
                word: field.word,
                clock: Clock(code: code, megahertz: generation.espiClock(code)))
        }
        // Fifteen bits of start, a read enable, fifteen of end, a write
        // enable — ifdtool's `union gprd`, which is the whole of the field.
        if let field = map?.protectedRangeField, field.word < words.count {
            let gprd = field.value(in: words[field.word])
            straps.gpr0 = ProtectedRange(
                word: field.word,
                start: base + UInt64(gprd & 0x7FFF) << 12,
                end: base + (UInt64(gprd >> 16 & 0x7FFF) << 12 | 0xFFF),
                readProtected: gprd >> 15 & 1 != 0,
                writeProtected: gprd >> 31 & 1 != 0)
        }
        return straps
    }

    /// Every region the table declares. A region with a zero limit is not
    /// there at all, which is the table's way of saying so, and is left out
    /// rather than shown as an area at zero.
    private static func regions(
        at base: UInt64, map: UInt32, generation: DescriptorGeneration, reader: ImageReader
    ) -> [Region] {
        let regionBase = (map >> 16) & 0xFF
        guard regionBase > 0, regionBase <= Descriptor.maxBase else { return [] }
        let section = base + UInt64(regionBase) << 4

        var regions: [Region] = []
        for index in 0..<generation.regionCount {
            guard let type = FlashRegionType(rawValue: index),
                  let first = reader.uint16(at: section + UInt64(index) * 4),
                  let last = reader.uint16(at: section + UInt64(index) * 4 + 2)
            else { break }
            // The descriptor's own entry is zero/zero on every image — it is
            // the first 0x1000 bytes by definition — so it is stated rather
            // than read, and every other region needs a limit to exist.
            if type == .descriptor {
                regions.append(Region(type: type, base: base, limit: base + Descriptor.size - 1))
                continue
            }
            guard last != 0, first <= last, first != Descriptor.erasedRegionEntry else { continue }
            regions.append(Region(type: type, base: base + UInt64(first) << 12,
                                  limit: base + (UInt64(last) << 12 | 0xFFF)))
        }
        return regions
    }

    /// The component section, at `ComponentBase << 4`: `FLCOMP`, then the
    /// forbidden opcodes in one dword — two from Sunrise Point on, where the
    /// partition boundary register became the second.
    private static func component(
        at base: UInt64, map: UInt32, generation: DescriptorGeneration, reader: ImageReader
    ) -> Component? {
        let componentBase = map & 0xFF
        guard componentBase > 0, componentBase <= Descriptor.maxBase else { return nil }
        let section = base + UInt64(componentBase) << 4
        guard let flcomp = reader.uint32(at: section),
              let invalid = reader.uint32(at: section + 4),
              let invalid1 = reader.uint32(at: section + 8)
        else { return nil }

        // The map counts the chips less one, in two bits.
        let chipCount = Int(map >> 8 & 0x3) + 1
        let bits = generation.densityBits
        let mask: UInt32 = (1 << bits) - 1
        let chipSizes: [UInt64?] = (0..<min(chipCount, 2)).map { index in
            let code = flcomp >> (UInt32(index * bits)) & mask
            // 512 KiB doubled per step: up to 16 MB in three bits, 64 MB in four.
            let largest: UInt32 = bits == 3 ? 5 : 7
            return code <= largest ? UInt64(0x8_0000) << code : nil
        }
        func clock(_ shift: UInt32) -> Clock {
            let code = UInt8(flcomp >> shift & 0x7)
            return Clock(code: code, megahertz: generation.clock(code))
        }
        let words = generation.hasEightInvalidInstructions ? [invalid, invalid1] : [invalid]
        let opcodes = words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }

        return Component(
            chipSizes: chipSizes,
            readIDClock: clock(27),
            writeEraseClock: clock(24),
            fastReadClock: flcomp & 1 << 20 != 0 ? clock(21) : nil,
            invalidInstructions: opcodes.filter { $0 != 0 }
        )
    }

    /// The master section's read and write masks, one master per row.
    private static func masters(
        at masterBase: UInt64?, isVersion1: Bool, reader: ImageReader
    ) -> [Master] {
        guard let masterBase else { return [] }
        if isVersion1 {
            // Three records of `id, read, write` — two bytes, then one each.
            let names = ["BIOS", "ME", "GbE"]
            return names.enumerated().compactMap { index, name in
                let entry = masterBase + UInt64(index) * 4
                guard let read = reader.uint8(at: entry + 2),
                      let write = reader.uint8(at: entry + 3)
                else { return nil }
                return Master(name: name, read: UInt32(read), write: UInt32(write))
            }
        }
        // One dword per master: eight reserved bits, then twelve of read and
        // twelve of write. EC's sits a dword past a reserved one.
        let names: [(String, UInt64)] = [("BIOS", 0), ("ME", 4), ("GbE", 8), ("EC", 16)]
        return names.compactMap { name, offset in
            guard let word = reader.uint32(at: masterBase + offset) else { return nil }
            return Master(name: name, read: word >> 8 & 0xFFF, write: word >> 20 & 0xFFF)
        }
    }

    /// What the BIOS master may do to each region, read off its own masks —
    /// except to the BIOS region itself, which it owns and which the table
    /// states rather than reads, exactly as the reference parser does.
    private static func biosAccess(
        at masterBase: UInt64?, isVersion1: Bool, reader: ImageReader
    ) -> [Access] {
        guard let masterBase else { return [] }
        let bios: (read: UInt32, write: UInt32)
        if isVersion1 {
            guard let read = reader.uint8(at: masterBase + 2),
                  let write = reader.uint8(at: masterBase + 3)
            else { return [] }
            bios = (UInt32(read), UInt32(write))
        } else {
            guard let word = reader.uint32(at: masterBase) else { return [] }
            bios = (word >> 8 & 0xFFF, word >> 20 & 0xFFF)
        }

        var rows = [
            Access(region: "Desc", read: bios.read & RegionAccess.descriptor != 0,
                   write: bios.write & RegionAccess.descriptor != 0),
            Access(region: "BIOS", read: true, write: true),
            Access(region: "ME", read: bios.read & RegionAccess.me != 0,
                   write: bios.write & RegionAccess.me != 0),
            Access(region: "GbE", read: bios.read & RegionAccess.gbe != 0,
                   write: bios.write & RegionAccess.gbe != 0),
            Access(region: "PDR", read: bios.read & RegionAccess.pdr != 0,
                   write: bios.write & RegionAccess.pdr != 0),
        ]
        if !isVersion1 {
            rows.append(Access(region: "EC", read: bios.read & RegionAccess.ec != 0,
                               write: bios.write & RegionAccess.ec != 0))
        }
        return rows
    }

    /// The VSCC table: the flash chips this firmware was built to drive, by
    /// JEDEC id, named where the catalogue knows them.
    private static func chips(at base: UInt64, reader: ImageReader) -> [Chip] {
        guard let map = reader.uint16(at: base + UpperMap.offset) else { return [] }
        // The same rule as every other base in this header: out of range is no
        // table rather than a table read from wherever it points.
        let tableAt = UInt32(map & 0xFF)
        guard tableAt > 0, tableAt <= Descriptor.maxBase else { return [] }
        let tableBase = base + UInt64(tableAt) << 4
        // The size field counts dwords; an entry is two of them.
        let count = UInt64(map >> 8 & 0xFF) / 2
        guard count > 0 else { return [] }

        var chips: [Chip] = []
        for index in 0..<count {
            let entry = tableBase + index * UpperMap.entrySize
            guard let vendor = reader.uint8(at: entry),
                  let device0 = reader.uint8(at: entry + 1),
                  let device1 = reader.uint8(at: entry + 2)
            else { break }
            let id = UInt32(vendor) << 16 | UInt32(device0) << 8 | UInt32(device1)
            // An erased or empty tail is not a chip.
            guard id != 0, id != 0xFF_FFFF else { continue }
            let known = JedecIDs.chip(of: id)
            chips.append(Chip(jedecID: id, name: known?.name,
                              vendor: known == nil ? FlashVendors.name(ofJedecID: id) : nil,
                              sizeKB: known?.sizeKB,
                              source: known.map { chip in
                                  switch chip.source {
                                  case .uefiTool: return .uefiTool
                                  case .linux: return .linux
                                  case .flashrom: return .flashrom
                                  }
                              }))
        }
        return chips
    }
}
