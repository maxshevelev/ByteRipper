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
            DescriptorInfo.Chip(jedecID: 0x1F4700, name: "Atmel AT25DF321", sizeKB: 4096),
            DescriptorInfo.Chip(jedecID: 0xEF4019, name: "Winbond W25Q256", sizeKB: 32768),
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
            DescriptorInfo.Chip(jedecID: 0xEF4019, name: "Winbond W25Q256", sizeKB: 32768),
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
        XCTAssertGreaterThan(JedecIDs.count(from: .flashrom), 150)
        XCTAssertEqual(JedecIDs.name(of: 0x1C7018), "EON EN25QH128")
        XCTAssertEqual(JedecIDs.name(of: 0xC22019), "Macronix MX25L256")
        XCTAssertNil(JedecIDs.name(of: 0x000000))
    }

    /// Where both sources know an id, UEFITool names it; flashrom still gives the
    /// size, and an id only flashrom lists carries flashrom as its source.
    func testTheCatalogueKeepsEachEntrysSourceAndSize() throws {
        let both = try XCTUnwrap(JedecIDs.chip(of: 0xEF4019))
        XCTAssertEqual(both.name, "Winbond W25Q256")
        XCTAssertEqual(both.source, .uefiTool)
        XCTAssertEqual(both.sizeKB, 32768)

        let extra = try XCTUnwrap(JedecIDs.chip(of: 0xC84017))
        XCTAssertEqual(extra.sizeKB, 8192)
    }
}
