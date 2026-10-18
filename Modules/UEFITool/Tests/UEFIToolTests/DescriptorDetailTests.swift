import XCTest
import UEFIImage
@testable import UEFITool

/// What the descriptor node's detail says beyond its header — the block the
/// reference parser prints under "Descriptor region" (`Design/UEFI_STRUCTURE_TOOL.md`).
final class DescriptorDetailTests: XCTestCase {
    private func detail(_ built: TestUEFI.Built) -> UEFINodeDetail {
        UEFIDetail.build(for: built.node, image: built.image, reader: built.reader, in: .english)
    }

    private func field(_ detail: UEFINodeDetail, _ label: String) -> String? {
        detail.fields.first { $0.label == label }?.value
    }

    private func table(_ detail: UEFINodeDetail, _ title: String) -> UEFIDetailTable? {
        detail.tables.first { $0.title == title }
    }

    /// The row of a table whose first cell reads `name` — a strap field is a
    /// row among hundreds, and this is how one of them is picked out.
    private func row(_ table: UEFIDetailTable, _ name: String) -> [UEFIDetailTable.Cell]? {
        table.rows.first { $0.first?.text == name }
    }

    /// The sixteen bytes the descriptor opens with, printed the way a dump
    /// prints them — this is a vector a bench compares against another board's.
    func testTheReservedVectorIsShownAsBytes() {
        let shown = detail(TestUEFI.flashDescriptor())

        XCTAssertEqual(field(shown, "Reserved vector"),
                       "11 00 00 9C 90 02 00 D6 00 00 00 05 FF FF FF FF")
    }

    /// Where each region the descriptor declares lies, base and limit as the
    /// table writes them — its own excluded, which is this node.
    func testTheRegionsAreAGridOfBaseAndLimit() throws {
        let shown = detail(TestUEFI.flashDescriptor())
        let table = try XCTUnwrap(table(shown, "Region table"))

        XCTAssertEqual(table.columns, ["Region", "Base", "Limit"])
        XCTAssertEqual(table.rows.map { $0.map(\.text) }, [
            ["BIOS region", "0x600000", "0xFFFFFF"],
            ["ME region", "0x1000", "0x5FFFFF"],
        ], "no descriptor row, and no GbE: a region with no limit is not there")
        XCTAssertNil(field(shown, "BIOS region offset"), "and not a row as well")
    }

    /// The chipset the layout is, with its series where it is sold as one.
    func testTheChipsetIsNamed() {
        XCTAssertEqual(field(detail(TestUEFI.flashDescriptor()), "Chipset"),
                       "Cougar Point / Panther Point (6/7 series)")
        XCTAssertEqual(field(detail(TestUEFI.flashDescriptor(version1: false)), "Chipset"),
                       "Alder Point / Raptor Point (600/700 series)")
    }

    /// What the component section says: the chip's size, the three clocks,
    /// and the opcodes the chipset will not send — four on Cougar Point.
    func testTheComponentSectionIsRows() {
        let shown = detail(TestUEFI.flashDescriptor(totalSize: 0x100_0000))

        XCTAssertEqual(field(shown, "Flash chip sizes"), "16 MB")
        XCTAssertNil(field(shown, "Second chip starts at"))
        XCTAssertEqual(field(shown, "Read ID and status clock"), "50 MHz")
        XCTAssertEqual(field(shown, "Write and erase clock"), "50 MHz")
        XCTAssertEqual(field(shown, "Fast read clock"), "50 MHz")
        XCTAssertEqual(field(shown, "Forbidden opcodes"), "21 42 60 AD")
        XCTAssertFalse(shown.fields.contains { $0.isProblem })
    }

    /// Two chips: their sizes end to end, where the second one's addresses
    /// begin, and eight opcodes from Sunrise Point on.
    func testTwoChipsSayWhereTheSecondBegins() {
        let shown = detail(TestUEFI.flashDescriptor(
            version1: false, chipSizes: [0x80_0000, 0x100_0000], totalSize: 0x180_0000))

        XCTAssertEqual(field(shown, "Flash chip sizes"), "8 MB + 16 MB")
        XCTAssertEqual(field(shown, "Second chip starts at"), "0x800000")
        XCTAssertEqual(field(shown, "Forbidden opcodes"), "21 42 60 AD B7 B9 C4 C7")
    }

    /// A dump that is not as long as the chips is one chip of two, or a read
    /// of the wrong size, and the row says it.
    func testADumpShorterThanItsChipsIsAProblem() throws {
        let shown = detail(TestUEFI.flashDescriptor(
            version1: false, chipSizes: [0x80_0000, 0x100_0000], totalSize: 0x80_0000))
        let row = try XCTUnwrap(shown.fields.first { $0.label == "Flash chip sizes" })

        XCTAssertEqual(row.value, "8 MB + 16 MB — the dump is 8 MB")
        XCTAssertTrue(row.isProblem)
    }

    /// Each master's masks, as a grid of its own — three numbers a row, which
    /// is a table and not a sentence.
    func testTheMastersMasksAreAGrid() throws {
        let shown = detail(TestUEFI.flashDescriptor())
        let table = try XCTUnwrap(table(shown, "Region access settings"))

        XCTAssertEqual(table.symbol, "key")
        XCTAssertEqual(table.columns, ["Master", "Read", "Write"])
        XCTAssertEqual(table.rows.map { $0[0].text }, ["BIOS", "ME", "GbE"])
        XCTAssertEqual(table.rows.map { $0[1].text }, ["0xA0", "0x40", "0x80"])
        XCTAssertEqual(table.rows.map { $0[2].text }, ["0x00", "0x00", "0x00"])
        XCTAssertNil(field(shown, "BIOS access"), "and not a row as well")
    }

    /// A version 2 descriptor writes twelve bits, so its masks are three digits
    /// wide and it has an EC master the older one does not.
    func testAVersion2DescriptorWritesThreeDigitMasksAndAnEC() throws {
        let shown = detail(TestUEFI.flashDescriptor(
            version1: false,
            masters: [(0xFFF, 0xFFF), (0x0D8, 0x0D8), (0x008, 0x008), (0x100, 0x100)]))
        let table = try XCTUnwrap(table(shown, "Region access settings"))

        XCTAssertEqual(table.rows.map { $0[0].text }, ["BIOS", "ME", "GbE", "EC"])
        XCTAssertEqual(table.rows.first?[1].text, "0xFFF")
        XCTAssertEqual(table.rows.last?[2].text, "0x100")
    }

    /// The access table is a grid, and a permission is a word with a colour:
    /// a column of green with one red in it is the answer to "why can't I
    /// write that region".
    func testTheBiosAccessTableIsAGridOfPermissions() throws {
        let shown = detail(TestUEFI.flashDescriptor())
        let table = try XCTUnwrap(table(shown, "BIOS access table"))

        XCTAssertEqual(table.symbol, "lock.shield")
        XCTAssertEqual(table.columns, ["Region", "Read", "Write"])
        XCTAssertEqual(table.rows.map { $0[0].text }, ["Desc", "BIOS", "ME", "GbE", "PDR"])
        // A0h carries none of the region bits (they are the low five) and 00h
        // writes nothing — so the BIOS master may touch only its own region,
        // which is stated rather than read because it owns it. This is the
        // locked-down board of the reference parser's own example.
        XCTAssertEqual(table.rows.map { $0[1].text }, ["No", "Yes", "No", "No", "No"])
        XCTAssertEqual(table.rows.map { $0[2].text }, ["No", "Yes", "No", "No", "No"])
        XCTAssertEqual(table.rows.map { $0[1].tone },
                       [.no, .yes, .no, .no, .no],
                       "and each carries the colour it reads in")
    }

    /// A board that lets its BIOS master into the other regions reads the other
    /// way round — which is the whole reason the table is drawn in colour.
    func testAnOpenBoardsAccessTableReadsGreen() throws {
        // Read and write descriptor, BIOS, ME, GbE and PDR alike.
        let shown = detail(TestUEFI.flashDescriptor(masters: [(0x1F, 0x1F), (0, 0), (0, 0)]))
        let table = try XCTUnwrap(table(shown, "BIOS access table"))

        XCTAssertEqual(table.rows.map { $0[1].text }, ["Yes", "Yes", "Yes", "Yes", "Yes"])
        XCTAssertEqual(table.rows.map { $0[2].tone }, [.yes, .yes, .yes, .yes, .yes])
    }

    /// The chips the firmware was built to drive, named where the catalogue
    /// knows the id.
    func testTheVsccTableIsAGridOfChips() throws {
        let shown = detail(TestUEFI.flashDescriptor(totalSize: 0x100_0000))
        let table = try XCTUnwrap(table(shown, "Flash chips in VSCC table"))

        XCTAssertEqual(table.symbol, "cpu", "the square chip the ME panel waits under")
        XCTAssertEqual(table.columns, ["JEDEC ID", "Chip", "Size", "Source"])
        XCTAssertEqual(table.rows.map { $0[0].text }, ["1F4700", "1C7018", "C22019", "EF4019"])
        XCTAssertEqual(table.rows.map { $0[1].text },
                       ["Atmel AT25DF321", "EON EN25QH128",
                        "Macronix MX25L256", "Winbond W25Q256"])
        XCTAssertEqual(table.rows.map { $0[2].text }, ["4 MB", "16 MB", "32 MB", "32 MB"])
        XCTAssertEqual(table.rows.map { $0[2].tone }, [.no, .plain, .plain, .plain],
                       "red where the chip (4 MB) is smaller than the 16 MB dump")
        XCTAssertEqual(table.rows.map { $0[3].text }, Array(repeating: "UEFITool", count: 4))
    }

    /// A chip that holds the whole dump is not marked, however much bigger it is;
    /// the red is only for one the dump does not fit into.
    func testNoChipIsRedWhenTheDumpFitsAll() throws {
        let shown = detail(TestUEFI.flashDescriptor(totalSize: 0x40_0000))
        let table = try XCTUnwrap(table(shown, "Flash chips in VSCC table"))

        XCTAssertEqual(table.rows.map { $0[2].tone }, [.plain, .plain, .plain, .plain])
    }

    /// Two chips: no one chip has to hold the dump, but one smaller than the
    /// smallest the descriptor declares cannot be either of them.
    func testWithTwoChipsRedIsASizeBelowTheSmallest() throws {
        let shown = detail(TestUEFI.flashDescriptor(
            chipSizes: [0x80_0000, 0x100_0000], totalSize: 0x180_0000))
        let table = try XCTUnwrap(table(shown, "Flash chips in VSCC table"))

        XCTAssertEqual(table.rows.map { $0[2].text }, ["4 MB", "16 MB", "32 MB", "32 MB"])
        XCTAssertEqual(table.rows.map { $0[2].tone }, [.no, .plain, .plain, .plain],
                       "red where the chip (4 MB) is below the smallest declared (8 MB)")
    }

    /// Where the section's length is one no table of the chipset's layout is at
    /// hand for, the words stand as the numbers they are, each row outlining
    /// its four bytes in the dump; only the ME-disable word says anything about
    /// its bits.
    func testTheStrapsAreAGridOfWordsWhereNoLayoutIsAtHand() throws {
        var words = [UInt32](repeating: 0, count: 11)
        words[1] = 0x1234_5678
        // Eleven words is a length no table states, on a generation whose own
        // section (16, 18 or 21 words) is another length.
        let shown = detail(TestUEFI.flashDescriptor(straps: words, strapCount: 11))
        let table = try XCTUnwrap(table(shown, "PCH straps"))

        XCTAssertEqual(table.columns, ["Strap", "Offset", "Value", "Meaning"])
        XCTAssertEqual(table.rows.count, 11, "one row per word of the section")
        XCTAssertEqual(table.rows[1].map(\.text), ["PCHSTRP1", "0x204", "0x12345678", "Unknown"])
        XCTAssertEqual(table.rows[10][3].text, "AltMeDisable in bit 7; the other bits unknown")
        XCTAssertEqual(table.rowTargets[1], .range(0x204..<0x208, name: "PCHSTRP1"))
        XCTAssertEqual(table.linkColumn, 1)
        XCTAssertTrue(table.startsFolded, "the grid stays folded until asked for")
        XCTAssertFalse(try XCTUnwrap(self.table(shown, "Region table")).startsFolded,
                       "the short tables are open")
    }

    /// On Cougar Point the 18-word section reads as the fields Intel's SPI
    /// Programming Guide names, with the words the guide calls reserved left
    /// as raw rows; the values here are `ME 7`'s.
    func testTheCougarPointStrapsAreFields() throws {
        var words = [UInt32](repeating: 0, count: 18)
        words[0] = 0x0920_D682
        words[10] = 0x0081_0044
        let shown = detail(TestUEFI.flashDescriptor(straps: words))
        let table = try XCTUnwrap(table(shown, "PCH straps"))

        XCTAssertEqual(table.columns, ["Field", "Bits", "Value", "Default"])
        XCTAssertEqual(try XCTUnwrap(row(table, "PCHSTRP0_SMB_EN")).map(\.text),
                       ["PCHSTRP0_SMB_EN", "7", "0x1", ""])
        XCTAssertEqual(try XCTUnwrap(row(table, "PCHSTRP0_BBBS")).map(\.text),
                       ["PCHSTRP0_BBBS", "29–30", "0x0", ""])
        XCTAssertEqual(try XCTUnwrap(row(table, "PCHSTRP10_Deep_SX_EN")).map(\.text),
                       ["PCHSTRP10_Deep_SX_EN", "23", "0x1", ""])
        XCTAssertEqual(try XCTUnwrap(row(table, "PCHSTRP3")).map(\.text),
                       ["PCHSTRP3", "", "0x0", ""],
                       "a reserved word keeps its raw row")
        XCTAssertEqual(table.sections.count, 18, "a section per word")
    }

    /// The processor strap section is a grid of the fields its layout names,
    /// under the word they take — the same shape as the PCH section's.
    func testTheProcessorStrapsAreAGridOfFields() throws {
        let shown = detail(TestUEFI.flashDescriptor(
            processorStraps: [0x0000_1000, 0x0010_8002, 0x0800_0210]))
        let table = try XCTUnwrap(table(shown, "CPU straps"))

        XCTAssertEqual(table.columns, ["Field", "Bits", "Value", "Default"])
        XCTAssertTrue(table.startsFolded, "the CPU straps start folded, as the PCH ones do")
        XCTAssertEqual(try XCTUnwrap(row(table, "Processor_max_frequency_boot")).map(\.text),
                       ["Processor_max_frequency_boot", "12", "0x1", "0x1"])
        XCTAssertEqual(try XCTUnwrap(row(table, "SaPowerPlaneTopology")).map(\.text),
                       ["SaPowerPlaneTopology", "0–3", "0x2", "0x2"])
    }

    /// The OEM section's bytes, in rows of sixteen, with the address that
    /// outlines them — shown only where a board's maker wrote something.
    func testTheOEMSectionIsAGridWhereSomethingIsWritten() throws {
        var oem = [UInt8](repeating: 0xFF, count: 0x20)
        oem[0] = 0x4E
        oem[1] = 0x31
        let shown = detail(TestUEFI.flashDescriptor(oemSection: oem))
        let table = try XCTUnwrap(table(shown, "OEM section"))

        XCTAssertEqual(table.columns, ["Offset", "Bytes"])
        XCTAssertEqual(table.rows.count, 16)
        XCTAssertEqual(table.rows[0].map(\.text),
                       ["0xF00", "4E 31 FF FF FF FF FF FF FF FF FF FF FF FF FF FF"])
        XCTAssertEqual(table.rowTargets[0], .range(0xF00..<0xF10, name: "0xF00"))
        XCTAssertEqual(table.linkColumn, 0)

        XCTAssertNil(self.table(detail(TestUEFI.flashDescriptor()), "OEM section"),
                     "an erased section is not a table")
    }

    /// From Tiger Point on the straps are the message in the descriptor's MIP
    /// area — the third map word states its offset from 0xC00 and its length.
    func testATigerPointDescriptorReadsTheMIPMessage() throws {
        let shown = detail(TestUEFI.flashDescriptor(version1: false, map2: 0x0011_01A0))
        let table = try XCTUnwrap(self.table(shown, "CPU straps"))

        XCTAssertEqual(table.sections.first?.title, "CPUSTRP0")
        XCTAssertEqual(table.columns, ["Field", "Bits", "Value", "Default"])
        XCTAssertTrue(table.startsFolded, "the CPU straps start folded, as the PCH ones do")
        // The message states no default, so the column says so with a dash
        // rather than standing empty.
        let fields = table.rows.filter { $0.first?.text != "Field" }
        XCTAssertFalse(fields.isEmpty)
        XCTAssertTrue(fields.allSatisfy { $0.count == 4 && $0[3].text == "—" })
    }

    /// The bit that soft-disables the ME is a row of its own, and set it reads
    /// as a state — the reason an otherwise whole ME does not run.
    func testTheMEDisableBitIsARow() throws {
        let clear = detail(TestUEFI.flashDescriptor(version1: false, straps: [0]))
        XCTAssertEqual(field(clear, "HAP bit"), "Not set")

        let set = detail(TestUEFI.flashDescriptor(version1: false, straps: [0x0001_0000]))
        let row = try XCTUnwrap(set.fields.first { $0.label == "HAP bit" })
        XCTAssertEqual(row.value, "Set — the ME is soft-disabled")
        XCTAssertEqual(row.tone, .caution)
    }

    /// On the mobile Alder Point layout GPR0 and the eSPI clock are rows, and
    /// their words say what they hold.
    func testGPR0AndTheESPIClockAreRowsOnAMobileLayout() throws {
        var words = [UInt32](repeating: 0, count: 23)
        words[21] = 0x829B_0001
        words[22] = 0x0058_0E20
        let shown = detail(TestUEFI.flashDescriptor(version1: false, straps: words, strapCount: 70))

        let gpr0 = try XCTUnwrap(shown.fields.first { $0.label == "GPR0" })
        XCTAssertEqual(gpr0.value, "0x1000 – 0x29BFFF: writes refused")
        XCTAssertEqual(gpr0.tone, .caution)
        XCTAssertEqual(field(shown, "eSPI clock"), "60 MHz")

        // Every field of the layout is a row of its own — 759 of them for this
        // section — with the ME-disable bit among them.
        let table = try XCTUnwrap(table(shown, "PCH straps"))
        XCTAssertEqual(table.columns, ["Field", "Bits", "Value", "Default"])
        XCTAssertEqual(table.rows.count, 760)
        XCTAssertEqual(try XCTUnwrap(row(table, "SPI_GLOBAL_PROTECTED_RNG_DEF")).map(\.text),
                       ["SPI_GLOBAL_PROTECTED_RNG_DEF", "0–31", "0x829B0001", "0x0"])
        let clockRow = try XCTUnwrap(row(table, "SPI_ec_max_freq"))
        XCTAssertEqual(clockRow.map(\.text), ["SPI_ec_max_freq", "3–5", "0x4", "0x0"])

        // A value the build set away from the default is drawn in bold; one
        // left at it is not.
        XCTAssertTrue(clockRow[2].isStrong)
        XCTAssertFalse(clockRow[3].isStrong, "the default itself is not")
        let plainRow = try XCTUnwrap(row(table, "SPI_ec_plch_dis"))
        XCTAssertFalse(plainRow[2].isStrong)

        // The rows fall into a section per word, which names the word, what
        // its fields share, and where it is — its address outlines the word.
        let clock = try XCTUnwrap(table.rows.firstIndex { $0[0].text == "SPI_ec_max_freq" })
        let section = try XCTUnwrap(table.sections.first { $0.rows.contains(clock) })
        XCTAssertEqual(section.title, "PCHSTRP22")
        XCTAssertEqual(section.subtitle, "SPI")
        XCTAssertEqual(section.address, "0x258")
        XCTAssertEqual(section.target, .range(0x258..<0x25C, name: "PCHSTRP22"))
        // The line says, folded, how many of its fields the build set.
        let setHere = table.rows[section.rows].filter { $0[2].isStrong }.count
        XCTAssertGreaterThan(setHere, 0)
        XCTAssertEqual(section.note, "Non-default: \(setHere)")
        let quiet = try XCTUnwrap(table.sections.first { section in
            !table.rows[section.rows].contains { $0[2].isStrong }
        })
        XCTAssertNil(quiet.note, "a word left at its defaults says nothing")
        XCTAssertEqual(table.sections.count, 70, "a section per word")
        XCTAssertEqual(table.sections.map(\.rows.count).reduce(0, +), table.rows.count,
                       "and every row in one")
        XCTAssertTrue(zip(table.sections, table.sections.dropFirst())
            .allSatisfy { $0.rows.upperBound == $1.rows.lowerBound }, "in order")
    }

    /// The bit that soft-disables the ME is a row among the fields — the chipset
    /// layout does not name it, so it has no default of the tool's to stand
    /// against — and its value is the bit.
    func testTheMEDisableBitIsARowOfTheLayoutsTable() throws {
        func hap(_ words: [UInt32]) throws -> [UEFIDetailTable.Cell] {
            let shown = detail(TestUEFI.flashDescriptor(version1: false, straps: words,
                                                        strapCount: 70))
            return try XCTUnwrap(row(XCTUnwrap(self.table(shown, "PCH straps")), "HAP"))
        }

        XCTAssertEqual(try hap([0]).map(\.text), ["HAP", "16", "0x0", ""])
        XCTAssertEqual(try hap([0x0001_0000]).map(\.text), ["HAP", "16", "0x1", ""])
        XCTAssertEqual(try hap([0]).count, 4)
    }

    /// A zero GPRD is off, and a clock code nobody defines shows the code.
    func testAnOffGPR0AndAnUnknownClock() {
        var words = [UInt32](repeating: 0, count: 23)
        words[22] = 6 << 3
        let shown = detail(TestUEFI.flashDescriptor(version1: false, straps: words, strapCount: 70))

        XCTAssertEqual(field(shown, "GPR0"), "Off")
        XCTAssertEqual(field(shown, "eSPI clock"), "Unknown (code 6)")
    }

    /// The desktop layout keeps the two fields in words of its own: word 29 is
    /// the eSPI clock and word 28 GPR0, while what the mobile layout calls
    /// GPR0 — word 21 — is neither.
    func testTheDesktopLayoutReadsItsOwnWords() {
        var words = [UInt32](repeating: 0, count: 115)
        words[21] = 0x2222_2222
        words[28] = 0x801F_8001
        words[29] = 4 << 3
        let shown = detail(TestUEFI.flashDescriptor(
            version1: false, straps: words, strapCount: 115))

        XCTAssertEqual(field(shown, "GPR0"), "0x1000 – 0x1FFFF: reads and writes refused")
        XCTAssertEqual(field(shown, "eSPI clock"), "60 MHz")
    }

    /// No strap section, no strap table and no bit row.
    func testNoStrapsMeansNoStrapRows() {
        let shown = detail(TestUEFI.flashDescriptor())

        XCTAssertNil(table(shown, "PCH straps"))
        XCTAssertNil(field(shown, "AltMeDisable bit"))
    }

    /// A node that is not a descriptor gets none of this — no tables, and no
    /// rows read from bytes that are not a descriptor's.
    func testOnlyADescriptorCarriesTheDescriptorBlock() {
        let volume = TestUEFI.volume()

        XCTAssertTrue(detail(volume).tables.isEmpty)
        XCTAssertNil(field(detail(volume), "Reserved vector"))
    }
}
