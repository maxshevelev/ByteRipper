import XCTest
@testable import UEFIImage

/// What a flash descriptor says about itself beyond its map: the reserved
/// vector, where each region starts, which master may touch which region, and
/// the flash chips the firmware was built to drive (§2).
final class DescriptorInfoTests: XCTestCase {
    private func info(_ bytes: [UInt8]) throws -> DescriptorInfo {
        try XCTUnwrap(DescriptorInfo.read(at: 0, in: ImageReader(bytes)))
    }

    /// The sixteen bytes before the signature, as they are — on a real board
    /// they are the first instruction the chip executes, so they are shown
    /// rather than skipped.
    func testTheReservedVectorIsReadWhole() throws {
        let vector: [UInt8] = [0x11, 0x00, 0x00, 0x9C, 0x90, 0x02, 0x00, 0xD6,
                               0x00, 0x00, 0x00, 0x05, 0xFF, 0xFF, 0xFF, 0xFF]
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x60_0000..<0x100_0000)], reservedVector: vector))

        XCTAssertEqual(read.reservedVector, vector)
    }

    /// Every region the table declares, where it begins and where it ends —
    /// the descriptor's own first, which the format states rather than stores.
    func testEachDeclaredRegionIsReadWithItsLimit() throws {
        let read = try info(TestImage.descriptor(regions: [
            (.me, 0x1000..<0x60_0000),
            (.bios, 0x60_0000..<0x100_0000),
        ]))

        XCTAssertEqual(read.regions, [
            DescriptorInfo.Region(type: .descriptor, base: 0, limit: 0xFFF),
            DescriptorInfo.Region(type: .bios, base: 0x60_0000, limit: 0xFF_FFFF),
            DescriptorInfo.Region(type: .me, base: 0x1000, limit: 0x5F_FFFF),
        ])
    }

    /// A region with a zero limit is not there at all, and is left out rather
    /// than shown as an area at offset zero.
    func testAnAbsentRegionIsNotListed() throws {
        let read = try info(TestImage.descriptor(regions: [(.bios, 0x1000..<0x40_0000)]))

        XCTAssertEqual(read.regions.map(\.type), [.descriptor, .bios])
    }

    /// The PCH straps are every word the map counts — `0x73` on this Alder
    /// Point layout — read where the map puts them, and HAP is bit 16 of the
    /// first.
    /// The processor strap section, where the descriptor still holds it: the
    /// third map word's base and count, up to Cannon Point.
    func testTheProcessorStrapsOfACannonPointBoard() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], version1: true,
            processorStraps: [0x0000_1000, 0x0010_8002, 0x0800_0210]))
        let straps = try XCTUnwrap(read.processorStraps)

        XCTAssertEqual(straps.base, 0x300)
        XCTAssertEqual(straps.words, [0x0000_1000, 0x0010_8002, 0x0800_0210])
        let boot = try XCTUnwrap(straps.fields?.first {
            $0.field.name == "CPU_Strap_Processor_max_frequency_boot"
        })
        XCTAssertEqual(boot.value, 1)
        XCTAssertFalse(boot.isSet, "the tool builds this section with the bit set")
        let plane = try XCTUnwrap(straps.fields?.first {
            $0.field.name == "CPU_Strap_SaPowerPlaneTopology"
        })
        XCTAssertEqual(plane.value, 2)
    }

    /// From Tiger Point on the straps are the message in the descriptor's MIP
    /// area: at `0xC00` plus the offset the third map word states
    /// (`FLMAP2[2:11]`), as many words as `FLMAP2[16:23]` says.
    func testTheProcessorStrapsOfATigerPointBoardAreTheMIPMessage() throws {
        var bytes = TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], map2: 0x0011_01A0)
        let base = 0xC00 + 0x68
        for (index, word) in [UInt32(0x0000_1000), 0x0000_0001].enumerated() {
            for byte in 0..<4 {
                bytes[base + index * 4 + byte] = UInt8(truncatingIfNeeded: word >> (8 * byte))
            }
        }
        let read = try info(bytes)

        XCTAssertEqual(read.generation, .tigerPoint)
        XCTAssertTrue(read.isGenerationCertain)
        let straps = try XCTUnwrap(read.processorStraps)
        XCTAssertEqual(straps.base, UInt64(base))
        XCTAssertEqual(straps.words.count, 17)
        XCTAssertEqual(straps.words.first, 0x0000_1000)
        let boot = try XCTUnwrap(straps.fields?.first {
            $0.field.name == "CPU_Strap_Fast_wakeup"
        })
        XCTAssertEqual(boot.value, 1)
        XCTAssertEqual(boot.field.label, "Processor Boot at P1 Frequency")
        XCTAssertEqual(boot.field.options?[1], "Yes")
        XCTAssertNil(boot.field.defaultValue, "the message states no defaults")
        XCTAssertFalse(boot.isSet, "and no field of it is emphasised")
    }

    /// From Meteor Lake the descriptor no longer carries the CPU straps: they
    /// moved into the FITC partition's MIP table (what the ME analyzer reads),
    /// and the map-word bits that name a Tiger Point message mean the SoC soft
    /// straps there. The erased words the old reading would take for a section
    /// are not one — the panel shows no CPU strap table for them.
    func testAMeteorLakeDescriptorCarriesNoProcessorStraps() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], map2: 0x0003_01C0))
        XCTAssertEqual(read.generation, .meteorLake)
        XCTAssertTrue(read.isGenerationCertain)
        XCTAssertNil(read.processorStraps)
    }

    /// The descriptor's own registers, through Flash Image Tool's layout: the
    /// map words at 0x14, the component's at `FCBA << 4`, the recovery policy
    /// and the VSCC/MIP map. Meteor Lake and later only — the map's FLCOMP is
    /// that generation's density and clock bits.
    func testTheDescriptorRegistersAreReadThroughTheToolsLayout() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            component: (chips: 1, flcomp: 0, flill: 0, flill1: 0),
            map2: 0x0003_01C0))
        XCTAssertEqual(read.generation, .meteorLake)
        XCTAssertEqual(read.registerReadings.map(\.register.name),
                       ["FLMAP0", "FLMAP1", "FLMAP2", "FLCOMP", "FLIL",
                        "FLDRPLCY", "FLUMAP1"],
                       "FLMSTR is absent: the test's master base is 0xFF, out of range")
        let map0 = try XCTUnwrap(read.registerReadings.first)
        XCTAssertEqual(map0.base, 0x14)
        XCTAssertEqual(map0.words, [0x0004_0003])
        let fields = Dictionary(uniqueKeysWithValues: map0.readings.map {
            ($0.field.name, $0.value)
        })
        XCTAssertEqual(fields["FLMAP0_Flash_Component_Base_Address"], 3)
        XCTAssertEqual(fields["FLMAP0_Flash_Region_Base_Address"], 4)
        // FLCOMP sits at FCBA << 4, which the map word states.
        let component = try XCTUnwrap(read.registerReadings.first {
            $0.register.name == "FLCOMP"
        })
        XCTAssertEqual(component.base, 0x30)
        // The map on an Alder Point descriptor is not this tool's.
        XCTAssertTrue(try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)])).registerReadings.isEmpty)
    }

    /// The OEM section is the fixed `0x100` bytes at `0xF00`, whatever a board
    /// wrote there — and all `0xFF` reads as an erased one, not as absent.
    func testTheOEMSectionIsTheFixedHundredBytes() throws {
        var bytes = TestImage.descriptor(regions: [(.bios, 0x1000..<0x40_0000)])
        bytes[0xF00] = 0x4E
        bytes[0xFFF] = 0x45
        let read = try info(bytes)

        XCTAssertEqual(read.oemSection.count, 0x100)
        XCTAssertEqual(read.oemSection.first, 0x4E)
        XCTAssertEqual(read.oemSection.last, 0x45)
    }

    /// A count of zero, or a base no descriptor has, is no section.
    func testNoProcessorStrapCountMeansNoSection() throws {
        XCTAssertNil(try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], map2: 0x0021_0000)).processorStraps)
        XCTAssertNil(try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], map2: 0x0021_01F1)).processorStraps)
    }

    func testTheStrapsOfAnAlderPointBoardAndItsHAPBit() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], straps: [0x0001_0000, 0x1234_5678]))
        let straps = try XCTUnwrap(read.straps)

        XCTAssertEqual(straps.base, 0x200)
        XCTAssertEqual(straps.words.count, 0x73)
        XCTAssertEqual(Array(straps.words.prefix(3)), [0x0001_0000, 0x1234_5678, 0xFFFF_FFFF])
        XCTAssertEqual(straps.meDisable,
                       DescriptorInfo.MEDisable(name: "HAP", word: 0, bit: 16, isSet: true))
    }

    /// From Ibex Peak to Wildcat Point the bit is AltMeDisable, bit 7 of the
    /// eleventh word — and a first word with bit 16 set says nothing there.
    func testACougarPointBoardsBitIsAltMeDisable() throws {
        var words = [UInt32](repeating: 0, count: 11)
        words[0] = 0x0001_0000
        let clear = try XCTUnwrap(info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], version1: true, straps: words)).straps)
        XCTAssertEqual(clear.words.count, 0x12)
        XCTAssertEqual(clear.meDisable,
                       DescriptorInfo.MEDisable(name: "AltMeDisable", word: 10, bit: 7, isSet: false))

        words[10] = 0x80
        let set = try XCTUnwrap(info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], version1: true, straps: words)).straps)
        XCTAssertEqual(set.meDisable?.isSet, true)
    }

    /// Which bit, generation by generation: ifdtool's and me_cleaner's, and
    /// none where neither names one.
    func testTheMEDisableBitByGeneration() {
        XCTAssertEqual(DescriptorGeneration.ich9.meDisableBit?.name, "ICH_MeDisable")
        XCTAssertEqual(DescriptorGeneration.ich9.meDisableBit?.bit, 0)
        XCTAssertEqual(DescriptorGeneration.lynxPoint.meDisableBit?.word, 10)
        XCTAssertEqual(DescriptorGeneration.sunrisePoint.meDisableBit?.name, "HAP")
        XCTAssertEqual(DescriptorGeneration.apolloLake.meDisableBit?.name, "HAP")
        XCTAssertNil(DescriptorGeneration.bayTrail.meDisableBit)
        XCTAssertNil(DescriptorGeneration.emmitsburg.meDisableBit)
    }

    /// The seventy-word layout of Tiger and Alder Point mobile: the eSPI clock
    /// in bits 3–5 of word 22, and GPR0 in word 21 — here as `ifdtool -p adl
    /// --gpr0-enable` writes it into `clean_me`: the ME region to the end of
    /// its FITC, writes refused.
    func testTheESPIClockAndGPR0OfAMobileAlderPointLayout() throws {
        var words = [UInt32](repeating: 0, count: 23)
        words[21] = 0x829B_0001
        words[22] = 0x0058_0E20
        let straps = try XCTUnwrap(info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], straps: words, strapCount: 70)).straps)

        XCTAssertEqual(straps.espiClock,
                       DescriptorInfo.ESPIClock(word: 22, clock: DescriptorInfo.Clock(code: 4, megahertz: [60])))
        XCTAssertEqual(straps.gpr0, DescriptorInfo.ProtectedRange(
            word: 21, start: 0x1000, end: 0x29_BFFF, readProtected: false, writeProtected: true))
        XCTAssertEqual(straps.gpr0?.isOn, true)
    }

    /// A GPRD of zero is no protection, and a clock code ifdtool's table has
    /// no entry for is a code without a clock.
    func testAZeroGPR0IsOffAndAnUnlistedClockIsUnknown() throws {
        var words = [UInt32](repeating: 0, count: 23)
        words[22] = 6 << 3
        let straps = try XCTUnwrap(info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], straps: words, strapCount: 70)).straps)

        XCTAssertEqual(straps.gpr0?.isOn, false)
        XCTAssertEqual(straps.espiClock?.clock, DescriptorInfo.Clock(code: 6, megahertz: nil))
    }

    /// The desktop layout puts the two fields in words of its own: Alder Point
    /// S's 115-word section keeps the eSPI clock in word 29 and GPR0 in word
    /// 28, and what the mobile layout calls GPR0 — word 21 — is neither.
    func testTheDesktopLayoutReadsItsOwnWords() throws {
        var words = [UInt32](repeating: 0, count: 115)
        words[21] = 0x2222_2222
        words[28] = 0x001F_8001                       // 0x1000–0x1FFFF, both refused
        words[29] = 4 << 3
        let straps = try XCTUnwrap(info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], straps: words)).straps)

        XCTAssertEqual(straps.words.count, 115)
        XCTAssertEqual(straps.espiClock?.word, 29)
        XCTAssertEqual(straps.espiClock?.clock, DescriptorInfo.Clock(code: 4, megahertz: [60]))
        XCTAssertEqual(straps.gpr0?.word, 28)
        XCTAssertEqual(straps.gpr0?.start, 0x1000)
        XCTAssertEqual(straps.gpr0?.end, 0x1_FFFF)
        XCTAssertEqual(straps.gpr0?.isOn, true)
    }

    /// Which layouts the two fields are read on: the length of the section,
    /// which is what an image states about it. Tiger Point H's 101 words and
    /// Alder Point S's desktop 114 and 115 are layouts of their own.
    func testTheStrapFieldsAreKeyedByTheSectionsLength() throws {
        XCTAssertEqual(DescriptorStrapMap.forSection(words: 70)?.espiClockField?.word, 22)
        XCTAssertEqual(DescriptorStrapMap.forSection(words: 70)?.protectedRangeField?.word, 21)
        XCTAssertEqual(DescriptorStrapMap.forSection(words: 101)?.espiClockField?.word, 20)
        XCTAssertEqual(DescriptorStrapMap.forSection(words: 101)?.protectedRangeField?.word, 19)
        XCTAssertEqual(DescriptorStrapMap.forSection(words: 115)?.espiClockField?.word, 29)
        XCTAssertEqual(DescriptorStrapMap.forSection(words: 115)?.protectedRangeField?.word, 28)
        XCTAssertEqual(DescriptorStrapMap.forSection(words: 114)?.espiClockField?.word, 26)
        XCTAssertEqual(DescriptorStrapMap.forSection(words: 114)?.protectedRangeField?.word, 25)
        XCTAssertNil(DescriptorStrapMap.forSection(words: 6))
        // Meteor Lake's 130-word section is the SoC soft-strap block, laid out
        // by MFIT 18's `SoC` document — byte-addressed, so a field's place is
        // the bit range `offset*8 + bit_low … + bit_high`.
        let soc = try XCTUnwrap(DescriptorStrapMap.forSection(words: 130))
        XCTAssertEqual(soc.fields.count, 1184)
        let laneReverse = try XCTUnwrap(soc.fields.first { $0.name == "SoC_Strap_PCIE2_LNREV" })
        XCTAssertEqual(laneReverse.word, 6)
        XCTAssertEqual(laneReverse.bits, 0...0)
        XCTAssertEqual(laneReverse.label, "PCIe Controller 3 (Port 9-12)")
        XCTAssertEqual(laneReverse.options, [0: "1x4", 1: "1x4 Lane Reversed"])
        XCTAssertNil(laneReverse.defaultValue, "the SoC values are per reference platform")
        XCTAssertNotNil(soc.espiClockField)
        XCTAssertNotNil(soc.protectedRangeField)
    }

    /// The section as its fields: every field of the layout, with what this
    /// image holds there, in the table's order — and each saying whether the
    /// image leaves it at the value Flash Image Tool builds with.
    func testTheStrapsAreReadAsTheLayoutsFields() throws {
        var words = [UInt32](repeating: 0, count: 70)
        words[22] = 3 << 3
        let straps = try XCTUnwrap(info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], straps: words, strapCount: 70)).straps)
        let fields = try XCTUnwrap(straps.fields)

        let clock = try XCTUnwrap(fields.first { $0.field.name == "PCH_Strap_SPI_ec_max_freq" })
        XCTAssertEqual(clock.value, 3)
        XCTAssertEqual(clock.field.bits, 3...5)
        XCTAssertEqual(clock.isSet, true, "the tool builds this one at 0")
        let protected = try XCTUnwrap(fields.first { $0.field.name == "PCH_Strap_SPI_GLOBAL_PROTECTED_RNG_DEF" })
        XCTAssertEqual(protected.isSet, false, "zero is what the tool builds")
        XCTAssertEqual(fields.count, DescriptorStrapMap.pch70.fields.count,
                       "every field of the layout is read, not only the ones set")
        XCTAssertEqual(Set(fields.map(\.field.word)), Set(0..<70),
                       "every word of the section holds fields of the layout")
    }

    /// The 130-word SoC section reads through its layout: the field names are
    /// the tool's, and the values are the image's own.
    func testTheSoCStrapSectionIsReadThroughItsLayout() throws {
        var words = [UInt32](repeating: 0, count: 130)
        words[6] = 1                         // PCIe Controller 3, lanes reversed
        words[65] = 3 << 3                   // eSPI / EC bus frequency, 50 MHz
        let straps = try XCTUnwrap(info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)], straps: words, strapCount: 130)).straps)
        let fields = try XCTUnwrap(straps.fields)
        let laneReverse = try XCTUnwrap(fields.first { $0.field.name == "SoC_Strap_PCIE2_LNREV" })
        XCTAssertEqual(laneReverse.value, 1)
        let clock = try XCTUnwrap(fields.first { $0.field.name == "SoC_Strap_SPI_ec_max_freq" })
        XCTAssertEqual(clock.value, 3)
        XCTAssertEqual(fields.count, DescriptorStrapMap.pch130.fields.count,
                       "every field of the layout is read")
    }

    /// A section shorter than the table names the fields still inside it and
    /// claims nothing about the words past its end.
    func testAFieldPastTheEndOfASectionIsNotRead() {
        let map = DescriptorStrapMap.pch70
        let cut = [UInt32](repeating: 0x1234_5678, count: 4)

        XCTAssertEqual(map.readings(in: cut).map(\.field.word).max(), 3)
        XCTAssertEqual(map.readings(in: cut).count, map.fields.filter { $0.word < 4 }.count)
    }

    /// What the generated tables have to be: a name apiece, every field inside
    /// the word it belongs to, and no word of the section left unnamed — which
    /// is what makes a word's meaning a list of fields rather than a guess.
    /// (Two fields *may* share a word's bits: the tool documents both an
    /// address and the fields inside it, as `SMT1_AUDIDB118` and the bits
    /// under it, and reads the same half-word two ways.)
    func testEveryStrapWordIsNamedByItsOwnFields() {
        XCTAssertFalse(DescriptorStrapMap.all.isEmpty)
        for map in DescriptorStrapMap.all {
            var names = Set<String>()
            var words = Set<Int>()
            for field in map.fields {
                XCTAssertLessThan(field.word, map.words,
                                  "\(field.name) is past the section it belongs to")
                XCTAssertEqual(field.bits.lowerBound, max(0, field.bits.lowerBound), field.name)
                XCTAssertLessThan(field.bits.upperBound, 32, field.name)
                XCTAssertLessThanOrEqual(field.bits.lowerBound, field.bits.upperBound, field.name)
                XCTAssertTrue(names.insert(field.name).inserted,
                              "\(field.name) is in one table twice")
                words.insert(field.word)
            }
            // The SoC block states three 32-bit CSME SMT IDs across a word
            // boundary; a one-word field cannot hold those, so the three words
            // they partly cover may hold no field of their own.
            let crossing: Set<Int> = map.words == 130 ? [41, 46, 51] : []
            XCTAssertEqual(Set(0..<map.words).subtracting(words), crossing,
                           "every word of the \(map.words)-word section holds fields")
        }
    }

    /// No strap base, no section — the bytes at offset zero are not straps.
    func testNoStrapBaseMeansNoStraps() throws {
        XCTAssertNil(try info(TestImage.descriptor(regions: [(.bios, 0x1000..<0x40_0000)])).straps)
    }

    /// A length that runs past the descriptor is cut where the descriptor
    /// ends: what follows is the next region, not straps.
    func testTheStrapsStopAtTheDescriptorsEnd() throws {
        var bytes = TestImage.descriptor(regions: [(.bios, 0x1000..<0x40_0000)])
        bytes[0x1A] = 0xE0                                  // FPSBA: 0xE00
        bytes[0x1B] = 0xFF                                  // 255 words claimed
        bytes += [UInt8](repeating: 0, count: 0x1000)
        let straps = try XCTUnwrap(info(bytes).straps)

        XCTAssertEqual(straps.words.count, 0x80, "0x200 bytes to the end, four a word")
    }

    /// The generation the layout is goes with the rest.
    func testTheGenerationIsRead() throws {
        let alder = try info(TestImage.descriptor(regions: [(.bios, 0x1000..<0x40_0000)]))
        XCTAssertEqual(alder.generation, .alderPoint)
        XCTAssertTrue(alder.isGenerationCertain)
        let cougar = try info(TestImage.descriptor(regions: [(.bios, 0x1000..<0x40_0000)], version1: true))
        XCTAssertEqual(cougar.generation, .cougarPoint)
    }

    /// Two chips of four-bit density, the clocks in Alder Point's codes, and
    /// eight forbidden opcodes — `CSME 16`'s component section.
    func testTheComponentSectionOfAnAlderPointBoard() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            component: (chips: 2, flcomp: 0x0930_F054, flill: 0xAD60_4221, flill1: 0xC7C4_B9B7)))
        let component = try XCTUnwrap(read.component)

        XCTAssertEqual(component.chipSizes, [0x80_0000, 0x100_0000], "8 MB, then 16 MB")
        XCTAssertEqual(component.readIDClock, DescriptorInfo.Clock(code: 1, megahertz: [50]))
        XCTAssertEqual(component.writeEraseClock.megahertz, [50])
        XCTAssertEqual(component.fastReadClock?.megahertz, [50])
        XCTAssertEqual(component.invalidInstructions, [0x21, 0x42, 0x60, 0xAD, 0xB7, 0xB9, 0xC4, 0xC7])
    }

    /// One chip whose density is three bits, Cougar Point's clock codes, and
    /// a single word of opcodes — the next being the partition boundary.
    func testTheComponentSectionOfACougarPointBoard() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            version1: true,
            component: (chips: 1, flcomp: 0x6490_0024, flill: 0, flill1: 0x1234_5678)))
        let component = try XCTUnwrap(read.component)

        XCTAssertEqual(component.chipSizes, [0x80_0000], "code 4 in the low three bits; the second chip is not counted")
        XCTAssertEqual(component.readIDClock.megahertz, [50])
        XCTAssertEqual(component.fastReadClock?.megahertz, [50])
        XCTAssertEqual(component.invalidInstructions, [], "no opcode is forbidden, and the boundary is not one")
    }

    /// Fast reads switched off have no clock; a code the generation reserves
    /// is kept as the code; a density past the largest is no size.
    func testWhatAComponentSectionDoesNotSay() throws {
        // Density 0xE, read-ID code 2 (reserved on Alder Point), fast read off.
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            component: (chips: 1, flcomp: 0x1100_000E, flill: 0, flill1: 0)))
        let component = try XCTUnwrap(read.component)

        XCTAssertEqual(component.chipSizes, [nil])
        XCTAssertEqual(component.readIDClock, DescriptorInfo.Clock(code: 2, megahertz: nil))
        XCTAssertNil(component.fastReadClock)
    }

    /// No component base, no section — not one read from offset zero.
    func testNoComponentBaseMeansNoComponentSection() throws {
        XCTAssertNil(try info(TestImage.descriptor(regions: [(.bios, 0x1000..<0x40_0000)])).component)
    }

    /// A version 1 descriptor keeps a byte of read and a byte of write per
    /// master, in records of four.
    func testAVersion1DescriptorReadsItsThreeMastersAsBytes() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            version1: true,
            masters: [(read: 0xA0, write: 0x00), (read: 0x40, write: 0x00),
                      (read: 0x80, write: 0x00)]))

        XCTAssertEqual(read.masters, [
            DescriptorInfo.Master(name: "BIOS", read: 0xA0, write: 0x00),
            DescriptorInfo.Master(name: "ME", read: 0x40, write: 0x00),
            DescriptorInfo.Master(name: "GbE", read: 0x80, write: 0x00),
        ])
        XCTAssertEqual(read.maskDigits, 2, "a byte is two hex digits")
    }

    /// A version 2 descriptor packs twelve bits of each into one dword, and has
    /// an EC master the older one does not.
    func testAVersion2DescriptorReadsTwelveBitMasksAndTheECMaster() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            masters: [(read: 0xFFF, write: 0xFFF), (read: 0x0D8, write: 0x0D8),
                      (read: 0x008, write: 0x008), (read: 0x100, write: 0x100)]))

        XCTAssertEqual(read.masters.map(\.name), ["BIOS", "ME", "GbE", "EC"])
        XCTAssertEqual(read.masters.first, DescriptorInfo.Master(name: "BIOS", read: 0xFFF, write: 0xFFF))
        XCTAssertEqual(read.masters.last, DescriptorInfo.Master(name: "EC", read: 0x100, write: 0x100))
        XCTAssertEqual(read.maskDigits, 3, "twelve bits is three")
    }

    /// The table a bench actually reads: what the BIOS master may do to each
    /// region. Its own region is stated rather than read — it owns it — and
    /// every other row is a bit out of its two masks.
    func testTheBiosAccessTableIsReadOffTheBiosMasksOwnBits() throws {
        // Read: descriptor + BIOS + ME. Write: BIOS only.
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            version1: true,
            masters: [(read: 0x07, write: 0x02), (read: 0, write: 0), (read: 0, write: 0)]))

        XCTAssertEqual(read.biosAccess, [
            DescriptorInfo.Access(region: "Desc", read: true, write: false),
            DescriptorInfo.Access(region: "BIOS", read: true, write: true),
            DescriptorInfo.Access(region: "ME", read: true, write: false),
            DescriptorInfo.Access(region: "GbE", read: false, write: false),
            DescriptorInfo.Access(region: "PDR", read: false, write: false),
        ])
    }

    /// A version 2 descriptor's table has an EC row too.
    func testAVersion2AccessTableHasAnECRow() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            masters: [(read: 0x20, write: 0x20)]))

        XCTAssertEqual(read.biosAccess.map(\.region), ["Desc", "BIOS", "ME", "GbE", "PDR", "EC"])
        XCTAssertEqual(read.biosAccess.last, DescriptorInfo.Access(region: "EC", read: true, write: true))
    }

    /// The VSCC table: the chips the firmware was built to drive, named where
    /// the catalogue knows the id and left as the id where it does not.
    func testTheVsccTableIsReadAndItsChipsNamed() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            chips: [0x1F4700, 0xEF4019, 0x0A0B0C]))

        XCTAssertEqual(read.chips, [
            DescriptorInfo.Chip(jedecID: 0x1F4700, name: "Atmel AT25DF321", sizeKB: 4096, source: .uefiTool),
            DescriptorInfo.Chip(jedecID: 0xEF4019, name: "Winbond W25Q256", sizeKB: 32768, source: .uefiTool),
            DescriptorInfo.Chip(jedecID: 0x0A0B0C, name: nil),
        ])
    }

    /// An id the catalogue does not know still names its maker, from the first
    /// byte; a code nobody here knows names nothing, and a named chip carries no
    /// vendor of its own.
    func testAnUnlistedChipIsNamedByItsVendor() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            chips: [0xEF0000, 0xEF4019, 0x0A0B0C]))

        XCTAssertEqual(read.chips, [
            DescriptorInfo.Chip(jedecID: 0xEF0000, name: nil, vendor: "Winbond"),
            DescriptorInfo.Chip(jedecID: 0xEF4019, name: "Winbond W25Q256", sizeKB: 32768, source: .uefiTool),
            DescriptorInfo.Chip(jedecID: 0x0A0B0C, name: nil),
        ])
    }

    /// An erased tail in the table is not a chip.
    func testAnErasedVsccEntryIsNotAChip() throws {
        let read = try info(TestImage.descriptor(
            regions: [(.bios, 0x1000..<0x40_0000)],
            chips: [0xEF4019, 0xFFFFFF, 0x000000]))

        XCTAssertEqual(read.chips.map(\.jedecID), [0xEF4019])
    }

    /// A descriptor with no table at all says so by having none, rather than by
    /// inventing one out of whatever is at the offset a zero base points to.
    func testNoVsccTableMeansNoChips() throws {
        let read = try info(TestImage.descriptor(regions: [(.bios, 0x1000..<0x40_0000)]))

        XCTAssertTrue(read.chips.isEmpty)
        XCTAssertTrue(read.masters.isEmpty, "and no masters either")
    }

    /// The catalogue is the whole of upstream's table, not a truncated read of
    /// it: the generator refuses under a hundred, and this is the count it
    /// produced.
    func testTheChipCatalogueIsComplete() {
        XCTAssertEqual(JedecIDs.count(from: .uefiTool), 185)
        XCTAssertGreaterThan(JedecIDs.count(from: .linux), 50)
        XCTAssertGreaterThan(JedecIDs.count(from: .flashrom), 100)
        XCTAssertEqual(JedecIDs.name(of: 0x1C7018), "EON EN25QH128")
        XCTAssertEqual(JedecIDs.name(of: 0xC22019), "Macronix MX25L256")
        XCTAssertNil(JedecIDs.name(of: 0x000000))
    }

    /// Where several sources know an id, the first names it (UEFITool, Linux,
    /// flashrom) and the size is the first any lists; an id only one source
    /// lists carries that source.
    func testTheCatalogueKeepsEachEntrysSourceAndSize() throws {
        let both = try XCTUnwrap(JedecIDs.chip(of: 0xEF4019))
        XCTAssertEqual(both.name, "Winbond W25Q256")
        XCTAssertEqual(both.source, .uefiTool)
        XCTAssertEqual(both.sizeKB, 32768)

        let extra = try XCTUnwrap(JedecIDs.chip(of: 0xC84017))
        XCTAssertEqual(extra.sizeKB, 8192)

        let kernel = try XCTUnwrap(JedecIDs.chip(of: 0x207017))
        XCTAssertEqual(kernel.name, "XMC XM25QH64A")
        XCTAssertEqual(kernel.source, .linux)
        XCTAssertEqual(kernel.sizeKB, 8192)
    }
}
