import XCTest
import UEFIImage
@testable import UEFITool

/// What the descriptor node's detail says beyond its header — the block the
/// reference parser prints under "Descriptor region" (`Design/UEFI_STRUCTURE_TOOL.md`).
final class DescriptorDetailTests: XCTestCase {
    private func detail(_ built: TestUEFI.Built) -> UEFINodeDetail {
        UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)
    }

    private func field(_ detail: UEFINodeDetail, _ label: String) -> String? {
        detail.fields.first { $0.label == label }?.value
    }

    private func table(_ detail: UEFINodeDetail, _ title: String) -> UEFIDetailTable? {
        detail.tables.first { $0.title == title }
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
        XCTAssertEqual(table.columns, ["JEDEC ID", "Chip", "Size"])
        XCTAssertEqual(table.rows.map { $0[0].text }, ["1F4700", "1C7018", "C22019", "EF4019"])
        XCTAssertEqual(table.rows.map { $0[1].text },
                       ["Atmel AT25DF321", "EON EN25QH128",
                        "Macronix MX25L256", "Winbond W25Q256"])
        XCTAssertEqual(table.rows.map { $0[2].text }, ["4 MB", "16 MB", "32 MB", "32 MB"])
        XCTAssertEqual(table.rows.map { $0[2].tone }, [.no, .plain, .plain, .plain],
                       "red where the chip (4 MB) is smaller than the 16 MB dump")
    }

    /// A chip that holds the whole dump is not marked, however much bigger it is;
    /// the red is only for one the dump does not fit into.
    func testNoChipIsRedWhenTheDumpFitsAll() throws {
        let shown = detail(TestUEFI.flashDescriptor(totalSize: 0x40_0000))
        let table = try XCTUnwrap(table(shown, "Flash chips in VSCC table"))

        XCTAssertEqual(table.rows.map { $0[2].tone }, [.plain, .plain, .plain, .plain])
    }

    /// A node that is not a descriptor gets none of this — no tables, and no
    /// rows read from bytes that are not a descriptor's.
    func testOnlyADescriptorCarriesTheDescriptorBlock() {
        let volume = TestUEFI.volume()

        XCTAssertTrue(detail(volume).tables.isEmpty)
        XCTAssertNil(field(detail(volume), "Reserved vector"))
    }
}
