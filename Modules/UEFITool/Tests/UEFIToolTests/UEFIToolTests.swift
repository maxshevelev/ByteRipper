import XCTest
@testable import UEFITool
import ToolModuleKit
import UEFIImage

/// What the selected node publishes: the node, and its body inside it — the
/// tree is the parser's, and what crosses the seam is only the ranges of the
/// one node worth drawing.
final class UEFIPresenterTests: XCTestCase {
    func testNothingSelectedPublishesNothing() {
        XCTAssertEqual(UEFIPresenter.zones(for: nil), .empty)
    }

    /// A node with a header of its own publishes two zones, and the body is
    /// the one in focus: it is what the node holds, and where it starts is
    /// where the header ended.
    func testANodeWithAHeaderPublishesItsBodyAndFocusesIt() {
        let node = UEFINode(
            id: NodeID([1, 2, 0]),
            kind: .file,
            name: "VTF",
            header: 0x1000..<0x1018,
            body: 0x1018..<0x1100
        )
        let zones = UEFIPresenter.zones(for: node)

        XCTAssertEqual(zones.zones.map(\.id), ["1.2.0", "1.2.0#body"],
                       "the node first, then what is inside it")
        XCTAssertEqual(zones.zones.map(\.range), [0x1000..<0x1100, 0x1018..<0x1100])
        XCTAssertEqual(zones.zones.map(\.name), ["VTF", "VTF body"])
        XCTAssertEqual(zones.focus, "1.2.0#body")
        XCTAssertFalse(zones.zones.contains { $0.id.hasSuffix("#header") },
                       "the header is not a zone — the body's start is where it ended")
    }

    /// Both survive the map the dump actually draws: nesting is legal, and the
    /// focus still names a zone that is in it.
    func testTheNestedZonesSurviveNormalisation() throws {
        let node = UEFINode(
            id: NodeID([0]),
            kind: .volume,
            name: "FFSv2",
            header: 0x0..<0x48,
            body: 0x48..<0x1000
        )
        let drawable = UEFIPresenter.zones(for: node).normalized(contentSize: 0x1000)

        XCTAssertEqual(drawable.zones.count, 2)
        XCTAssertEqual(drawable.focus, "0#body")
        XCTAssertEqual(drawable.zones(containing: 0x10).map(\.id), ["0"],
                       "a byte in the header is in the node's zone and no other")
        XCTAssertEqual(drawable.zones(containing: 0x48).map(\.id), ["0", "0#body"])
    }

    /// The inner two do not have to add up to the node: an FFSv1 file's tail
    /// is part of the node and belongs to neither.
    func testATailStaysInsideTheNodesOwnZone() {
        let node = UEFINode(
            id: NodeID([0, 1]),
            kind: .file,
            name: "Old file",
            header: 0x200..<0x218,
            body: 0x218..<0x2F8,
            tail: 0x2F8..<0x300
        )
        let zones = UEFIPresenter.zones(for: node)

        XCTAssertEqual(zones.zones[0].range, 0x200..<0x300, "the node covers its tail")
        XCTAssertEqual(zones.zones[1].range, 0x218..<0x2F8, "the body stops before it")
    }

    /// Padding, free space, anything the parser met without a header of its
    /// own: splitting it would draw the same range twice, so the node is the
    /// whole of what is published — and it is the focus.
    func testANodeWithoutAHeaderPublishesOneZone() {
        var node = UEFINode(kind: .freeSpace, name: "Free space", range: 0x2000..<0x4000)
        node.id = NodeID([4])
        let zones = UEFIPresenter.zones(for: node)

        XCTAssertEqual(zones.zones.count, 1)
        XCTAssertEqual(zones.zones[0].range, 0x2000..<0x4000)
        XCTAssertEqual(zones.focus, "4")
    }

    /// A node whose header is the whole of it — nothing to hold — is the same
    /// story the other way round.
    func testANodeWithoutABodyPublishesOneZone() {
        let node = UEFINode(
            id: NodeID([2]),
            kind: .padding,
            name: "",
            header: 0x100..<0x120,
            body: 0x120..<0x120
        )
        let zones = UEFIPresenter.zones(for: node)

        XCTAssertEqual(zones.zones.count, 1)
        XCTAssertEqual(zones.focus, "2")
    }

    /// An unnamed node's body still says what it is — the name is what the
    /// dump's menu and the minimap's legend show.
    func testAnUnnamedNodesBodyIsStillNamed() {
        let node = UEFINode(
            id: NodeID([3]),
            kind: .section,
            name: "",
            header: 0x10..<0x14,
            body: 0x14..<0x40
        )
        XCTAssertEqual(UEFIPresenter.zones(for: node).zones.map(\.name), ["", "Body"])
    }

    /// The trip back: a zone id is a node path, and the panel has to read it
    /// to know which row to bring to the front.
    func testZoneIdsRoundTripToNodePaths() {
        let id = NodeID([1, 2, 0])
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: UEFIPresenter.zoneID(for: id)), id)
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "0"), NodeID([0]))
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "3.1"), NodeID([3, 1]))
    }

    /// A part's zone leads to the node it is part of: the reader picked
    /// "VTF body" in the dump and the row they want is VTF. Any part, not only
    /// the one published today — the suffix is not what identifies the node.
    func testAPartsZoneIdLeadsToItsNode() {
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "1.2.0#body"), NodeID([1, 2, 0]))
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "1.2.0#header"), NodeID([1, 2, 0]))
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "0#body"), NodeID([0]))
    }

    func testAZoneIdThatIsNotAPathIsRejected() {
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: ""))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "root"))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "1.x"))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "1..2"))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "#body"))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "1.x#body"))
    }
}

/// What the panel says about a node, by its type. Built in the pure target so
/// the view controller lays out what this decides rather than deciding itself.
final class UEFIDetailTests: XCTestCase {
    private func field(_ detail: UEFINodeDetail, _ label: String) -> String? {
        detail.fields.first { $0.label == label }?.value
    }

    private func problem(_ detail: UEFINodeDetail, _ label: String) -> Bool? {
        detail.fields.first { $0.label == label }?.isProblem
    }

    func testAVolumeSaysWhatItsHeaderSays() {
        let built = TestUEFI.volume()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "FFSv2")
        XCTAssertEqual(field(detail, "Kind"), "Volume")
        XCTAssertEqual(field(detail, "Type"), "Revision 2")
        XCTAssertEqual(field(detail, "GUID"), "\(KnownGUIDs.ffsV2) (FFSv2)")
        XCTAssertEqual(field(detail, "Header"), "0x0 · 0x38 (56) bytes")
        XCTAssertEqual(field(detail, "Body"), "0x38 · 0xFC8 (4040) bytes")
        XCTAssertEqual(field(detail, "Total"), "0x0 · 0x1000 (4096) bytes")
        XCTAssertEqual(field(detail, "Address"), "0xFFFF0000")
        XCTAssertEqual(field(detail, "Length"), "0x1000 (4096)")
        XCTAssertEqual(field(detail, "Signature"), "0x56544152")
        XCTAssertEqual(field(detail, "Attributes"), "0x800 (Erase polarity)")
        XCTAssertEqual(field(detail, "Header length"), "0x38 (56)")
        XCTAssertEqual(field(detail, "Checksum"), "0x1234 (Valid)")
        XCTAssertEqual(field(detail, "Ext. header"), "0x0")
        XCTAssertEqual(field(detail, "Revision"), "2")
    }

    /// A volume whose file system GUID nobody documented is still shown by its
    /// GUID — the raw form, since there is no name to add.
    func testAnUnknownVolumeGuidShowsRaw() {
        let guid = EFIGUID(low: 0x11, high: 0x22)
        let built = TestUEFI.volume(guid: guid, name: "")
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "GUID"), guid.description)
        XCTAssertEqual(detail.title, "Volume")
    }

    func testAFileNamesItsTypeAndReadsBackItsHeader() {
        let built = TestUEFI.file(type: 0x07, attributes: 0x04, size: 0x100, state: 0xF8)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "Volume Top File")
        XCTAssertEqual(field(detail, "Kind"), "FFS file")
        XCTAssertEqual(field(detail, "Type"), "Driver")
        XCTAssertEqual(field(detail, "Attributes"), "0x4 (Fixed)")
        XCTAssertEqual(field(detail, "Size"), "0x100 (256)")
        XCTAssertEqual(field(detail, "State"), "0xF8 (Erase polarity)")
        XCTAssertEqual(field(detail, "Header checksum"), "0xAA (Valid)")
        XCTAssertEqual(field(detail, "Body checksum"), "0xBB (Valid)")
        XCTAssertEqual(field(detail, "Header"), "0x0 · 0x18 (24) bytes")
    }

    /// A file whose state marks its header invalid says so, and its sums are
    /// shown unchecked rather than wrong: it owes none, and there is nothing
    /// for Fix Checksum to write (§5.5).
    func testAFileMarkedInvalidShowsItsSumsUnchecked() throws {
        let built = TestUEFI.file(state: 0x00)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)
        let state = try XCTUnwrap(detail.fields.first { $0.label == "State" })

        XCTAssertEqual(state.value, "0x0 — header marked invalid")
        XCTAssertEqual(state.tone, .caution)
        XCTAssertEqual(field(detail, "Header checksum"), "0xAA (not checked)")
        XCTAssertEqual(field(detail, "Body checksum"), "0xBB (not checked)")
        XCTAssertTrue(UEFIChecksumCheck.repairs(for: built.node, volumeRevision: nil, in: built.reader).isEmpty)
        XCTAssertTrue(UEFIChecksumCheck.repairs(for: built.node, volumeRevision: 2, in: built.reader).isEmpty)
    }

    /// A large file leaves the three-byte size at zero and keeps the real one
    /// in 64 bits — the detail has to follow the pointer, not show `0x0`.
    func testALargeFileReadsItsSizeFromTheLargeField() {
        var bytes = TestUEFI.file(size: 0).bytes
        let largeSize: UInt64 = 0x1_0000_0000
        let largeBytes = (0..<8).map { UInt8(truncatingIfNeeded: largeSize >> (8 * $0)) }
        for (index, byte) in largeBytes.enumerated() {
            bytes[0x18 + index] = byte
        }
        let node = TestUEFI.file(size: 0).node
        let image = UEFIImage(size: 0x1_0000_0000, roots: [node])
        let detail = UEFIDetail.build(for: node, image: image, reader: ImageReader(bytes))

        XCTAssertEqual(field(detail, "Size"), "0x100000000 (4294967296)")
    }

    /// An unknown file type keeps its number in the name — the only thing there
    /// is to say about a vendor type nobody documented.
    func testAnUnknownFileTypeKeepsItsNumber() {
        let built = TestUEFI.file(type: 0x7F)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Type"), "File type 0x7F")
    }

    func testASectionNamesItsTypeAndSize() {
        let built = TestUEFI.section(type: 0x19, size: 0x40)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "Section")
        XCTAssertEqual(field(detail, "Type"), "Raw")
        XCTAssertEqual(field(detail, "Size"), "0x40 (64)")
        XCTAssertEqual(field(detail, "Header"), "0x0 · 0x4 (4) bytes")
    }

    /// An extended-size section leaves the three-byte field at the marker and
    /// keeps the real size in 32 bits — the detail reads the 32-bit one.
    func testAnExtendedSectionReadsItsSizeInThirtyTwoBits() {
        let built = TestUEFI.section(type: 0x19, size: 0xFF_FFFF)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Size"), "0x100000 (1048576)")
        XCTAssertEqual(field(detail, "Header"), "0x0 · 0x8 (8) bytes")
    }

    func testAMicrocodeHeaderComesBackValidated() {
        let built = TestUEFI.microcode(revision: 0xF0, signature: 0x0008_06EA, totalSize: 0x100)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "Microcode")
        XCTAssertEqual(field(detail, "Header type"), "0x1")
        XCTAssertEqual(field(detail, "Update revision"), "0xF0")
        XCTAssertEqual(field(detail, "Date"), "2019-07-15")
        XCTAssertEqual(field(detail, "CPUID"), "806EA")
        XCTAssertEqual(field(detail, "Loader revision"), "0x1")
        XCTAssertEqual(field(detail, "Platform IDs"), "0x1")
        XCTAssertEqual(field(detail, "Data size"), "0x40 (64)")
        XCTAssertEqual(field(detail, "Total size"), "0x100 (256)")
        XCTAssertEqual(field(detail, "Processor"), "Family 0x6, model 0x8E, stepping 0xA")
        XCTAssertEqual(field(detail, "Platforms"), "0")
        XCTAssertNil(field(detail, "Extended signatures"), "an update for one processor has no table")
        XCTAssertTrue(detail.tables.isEmpty)
    }

    /// Bytes that are not microcode do not pretend to be: the reader refuses
    /// them, and the detail falls back to what every node has.
    func testBytesThatAreNotMicrocodeShowNoMicrocodeFields() {
        var bytes = TestUEFI.microcode().bytes
        bytes[0] = 0x00  // HeaderType must be 1
        let built = TestUEFI.microcode()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: ImageReader(bytes))

        XCTAssertEqual(field(detail, "Kind"), "Microcode")
        XCTAssertEqual(field(detail, "Header type"), "0x0")
        XCTAssertNil(field(detail, "Update revision"))
        XCTAssertNil(field(detail, "Date"))
    }

    /// Padding has no header of its own: the size the common fields carry is
    /// the whole of what there is to say, and the title is the kind.
    func testPaddingShowsOnlyTheCommonFields() {
        let built = TestUEFI.padding(totalSize: 0x100)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "Padding")
        XCTAssertEqual(field(detail, "Kind"), "Padding")
        XCTAssertEqual(field(detail, "Total"), "0x0 · 0x100 (256) bytes")
        XCTAssertNil(field(detail, "Length"))
        XCTAssertNil(field(detail, "Signature"))
    }

    /// A compressed node's address means nothing, so the one field worth
    /// skipping is skipped — not shown as a guess.
    func testACompressedNodeHasNoAddress() {
        let built = TestUEFI.file()
        var node = built.node
        node.space = .decompressed(chain: [0])
        let detail = UEFIDetail.build(for: node, image: built.image, reader: built.reader)

        XCTAssertNil(field(detail, "Address"))
    }

    /// Without a volume top file no address in the image is knowable, so the
    /// field is absent rather than shown as zero.
    func testAnImageWithNoAddressMapHasNoAddress() {
        let built = TestUEFI.file()
        let image = UEFIImage(size: built.image.size, roots: [built.node])
        let detail = UEFIDetail.build(for: built.node, image: image, reader: built.reader)

        XCTAssertNil(field(detail, "Address"))
    }

    // MARK: - The Intel image root

    /// The root of a whole SPI dump reads its counters off the descriptor's
    /// map — the block the reference parser prints under "Intel image". The
    /// default builder bytes are the map of a real Coffee Lake board.
    func testAnIntelImageReadsItsDescriptorCounters() {
        let built = TestUEFI.intelImage()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "Intel image")
        XCTAssertEqual(field(detail, "Kind"), "Intel image")
        XCTAssertEqual(field(detail, "Type"), "Intel")
        XCTAssertEqual(field(detail, "Header"), "Empty")
        XCTAssertEqual(field(detail, "Body"), "0x0 · 0x1000 (4096) bytes")
        XCTAssertEqual(field(detail, "Address"), "0xFFFF0000")
        XCTAssertEqual(field(detail, "Flash chips"), "1")
        XCTAssertEqual(field(detail, "Regions"), "1")
        XCTAssertEqual(field(detail, "Masters"), "3")
        XCTAssertEqual(field(detail, "PCH straps"), "90")
        XCTAssertEqual(field(detail, "PROC straps"), "3")
    }

    /// The three zero-based counters are stored minus one and the two strap
    /// counts are not, so a map holding raw values reads the counts back one
    /// higher than the chips/regions/masters fields and exactly equal to the
    /// strap fields.
    func testAnIntelImageReadsZeroBasedCountersBackPlusOne() {
        let built = TestUEFI.intelImage(
            flashMap0: 0x0204_0003,          // chips 0 → 1, regions 2 → 3
            flashMap1: 0x0700_0108,          // masters 1 → 2, PCH straps 7
            flashMap2: 0x8000                // PROC straps 0x80
        )
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Flash chips"), "1")
        XCTAssertEqual(field(detail, "Regions"), "3")
        XCTAssertEqual(field(detail, "Masters"), "2")
        XCTAssertEqual(field(detail, "PCH straps"), "7")
        XCTAssertEqual(field(detail, "PROC straps"), "128")
    }

    // MARK: - The UEFI image root

    /// The root a bare file is wrapped in is the whole file and nothing else:
    /// an empty header means no descriptor to read, so the detail shows only
    /// the common geometry fields and the Type/Subtype words — never the Intel
    /// descriptor counters the sibling root reads.
    func testAUefiImageWrapperShowsOnlyItsCommonFields() {
        let node = UEFINode(
            kind: .uefiImage,
            subtype: UEFITypes.Sub.uefiImage,
            name: "UEFI image",
            header: 0..<0,
            body: 0..<0x1000,
            isFixed: true
        )
        let image = UEFIImage(size: 0x1000, roots: [node])
        let detail = UEFIDetail.build(
            for: node, image: image,
            reader: ImageReader([UInt8](repeating: 0, count: 0x1000))
        )

        XCTAssertEqual(detail.title, "UEFI image")
        XCTAssertEqual(field(detail, "Kind"), "UEFI image")
        XCTAssertEqual(field(detail, "Type"), "UEFI")
        XCTAssertEqual(field(detail, "Header"), "Empty")
        XCTAssertEqual(field(detail, "Body"), "0x0 · 0x1000 (4096) bytes")
        XCTAssertEqual(field(detail, "Total"), "0x0 · 0x1000 (4096) bytes")
        XCTAssertEqual(field(detail, "Flags"), "fixed")
        XCTAssertNil(field(detail, "Flash chips"))
        XCTAssertNil(field(detail, "Regions"))
        XCTAssertNil(field(detail, "Length"))
    }

    // MARK: - NVRAM stores and entries

    func testAVssStoreReadsItsFormatAndState() {
        let built = TestUEFI.nvramVssStore()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "VSS store")
        XCTAssertEqual(field(detail, "Format"), "0x5A")
        XCTAssertEqual(field(detail, "State"), "0x1")
        XCTAssertEqual(field(detail, "Reserved"), "0x0")
        XCTAssertEqual(field(detail, "Reserved1"), "0x0")
    }

    /// A VSS2 store keeps the same four fields a VSS store does, after its
    /// 16-byte store GUID — the detail reads them at the pushed-out offsets.
    func testAVss2StoreReadsItsFormatAndState() {
        let built = TestUEFI.nvramVss2Store()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "VSS2 store")
        XCTAssertEqual(field(detail, "Format"), "0x5A")
        XCTAssertEqual(field(detail, "State"), "0x1")
        XCTAssertEqual(field(detail, "Reserved"), "0x0")
        XCTAssertEqual(field(detail, "Reserved1"), "0x0")
    }

    /// A variable's vendor GUID is the common GUID field the parser set on the
    /// node — the same row every GUID-bearing node has — and the attribute bits
    /// read as their words, not just a number.
    func testAVssVariableShowsItsVendorGuidAndAttributeWords() {
        let guid = EFIGUID(low: 0x1111_1111, high: 0x2222_2222)
        let built = TestUEFI.nvramVssVariable(attributes: 0x0000_0007, vendorGuid: guid)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "BootOrder")
        XCTAssertEqual(field(detail, "Kind"), "VSS entry")
        XCTAssertEqual(field(detail, "Type"), "Standard")
        XCTAssertEqual(field(detail, "GUID"), guid.description)
        XCTAssertEqual(field(detail, "State"), "0x7F")
        XCTAssertEqual(field(detail, "Reserved"), "0x0")
        XCTAssertEqual(field(detail, "Attributes"), "0x7 (NonVolatile, BootService, Runtime)")
    }

    /// An FTW block's header CRC is not re-verified here — the parser needs the
    /// erase byte to blank the CRC and state fields, and it already reports a
    /// mismatch when it reads the block — so the value is shown without a
    /// validity claim the panel cannot back up.
    func testAFtwStoreShowsItsStateAndHeaderCrc() {
        let built = TestUEFI.nvramFtwStore(crc: 0xDEAD_BEEF)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "FTW store")
        XCTAssertEqual(field(detail, "State"), "0x1")
        XCTAssertEqual(field(detail, "Header CRC32"), "0xDEADBEEF")
    }

    /// A SysF store checks itself with a CRC32 over everything before its final
    /// four bytes, so the detail can vouch for it the same way.
    func testASysfStoreChecksItsCrc() {
        let built = TestUEFI.nvramSysfStore()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "SysF store")
        let stored = Checksums.crc32(Array(built.bytes.dropLast(4)))
        XCTAssertEqual(field(detail, "CRC32"), Checksums.text(stored, valid: true, digits: 8))
    }

    /// Apple's device overrides are text inside a bzip2 stream; the detail
    /// unpacks them into a row a rule.
    func testAnOverridesVariableIsReadAsRules() throws {
        let built = TestUEFI.sysfOverrides()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Rules"), "2")
        let table = try XCTUnwrap(detail.tables.first { $0.title == "Device overrides" })
        XCTAssertEqual(table.rows.map { $0.map(\.text) }, [
            ["ADD_DEVICE", "Every device", #"[class="USBPort",location="rear-right"]"#],
            ["REMOVE_DEVICE", #"class="Sensor""#, #"(class="Sensor"&location="ALSL")"#],
        ])
    }

    func testASysfStoreFlagsABadCrc() {
        let built = TestUEFI.nvramSysfStore(crc: 0xDEAD_BEEF)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        // A wrong stored CRC reads with the value it should be — the CRC32 of
        // everything before the store's final four bytes, which the fixture put
        // `0xDEADBEEF` in place of.
        let shouldBe = Checksums.crc32(Array(built.bytes.dropLast(4)))
        XCTAssertEqual(
            field(detail, "CRC32"),
            Checksums.text(0xDEAD_BEEF, valid: false, expected: UInt64(shouldBe), digits: 8)
        )
    }

    /// An EVSA store is an entry of its own whose checksum covers its 20-byte
    /// header, and the detail can recompute it from what is in the panel.
    func testAnEvsaStoreChecksItsHeaderChecksum() {
        let built = TestUEFI.nvramEvsaStore(attributes: 0x0000_0007)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "EVSA store")
        XCTAssertEqual(field(detail, "Attributes"), "0x7")
        XCTAssertEqual(field(detail, "Reserved"), "0x0")
        XCTAssertEqual(field(detail, "Checksum"), Checksums.text(built.bytes[1], valid: true))
    }

    /// A data variable's header carries the two id words its guid and name
    /// entries own, and an attributes word whose extended-header bit has a word
    /// of its own.
    func testAnEvsaDataVariableReadsItsIdsAttributesAndChecksum() {
        let built = TestUEFI.nvramEvsaDataEntry(attributes: 0x1000_0007, data: [0x01])
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "Lang")
        XCTAssertEqual(field(detail, "Kind"), "EVSA entry")
        XCTAssertEqual(field(detail, "VarId"), "0x2")
        XCTAssertEqual(field(detail, "GuidId"), "0x1")
        XCTAssertEqual(field(detail, "Attributes"), "0x10000007 (NonVolatile, BootService, Runtime, ExtendedHeader)")
        XCTAssertEqual(field(detail, "Checksum"), Checksums.text(built.bytes[1], valid: true))
    }

    /// An NVAR entry shows its attributes in the reference's words, where its
    /// chain goes next, and what its extended header says — the checksum
    /// checked the same way the parser checks it.
    func testAnNvarEntryReadsItsAttributesNextAndExtendedHeader() {
        let built = TestUEFI.nvarEntry()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "Setup")
        XCTAssertEqual(field(detail, "Kind"), "NVAR entry")
        XCTAssertEqual(field(detail, "Attributes"), "0x96 (AsciiName, Guid, ExtHeader, Valid)")
        XCTAssertEqual(field(detail, "Next entry"), "0x40")
        XCTAssertNil(field(detail, "GUID index"))
        XCTAssertEqual(field(detail, "Extended attributes"), "0x1 (Checksum)")
        let stored = built.bytes[built.bytes.count - 3]
        XCTAssertEqual(field(detail, "Checksum"), Checksums.text(stored, valid: true))
    }

    /// Each ITE image in the block is a row: what it says it is, and where.
    func testECFirmwareListsEveryITEImageItHolds() {
        let built = TestUEFI.itePadding()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)
        XCTAssertEqual(
            detail.fields.filter { $0.label == "ITE identification" }.map(\.value),
            ["ITE5507-SB-V0.67 · 0x0", "ITE8380-EC-V0.00 · 0x1000"]
        )
    }

    /// A store says how full it is and what its entries still count for.
    func testAStoreShowsHowFullItIs() {
        let entry = UEFINode(kind: .vssEntry, subtype: UEFITypes.Sub.standardVssEntry, name: "Setup",
                             header: 0x10..<0x30, body: 0x30..<0xC0)
        let free = UEFINode(kind: .freeSpace, name: "", range: 0xC0..<0x110, isErased: true)
        let store = UEFINode(kind: .vssStore, name: "VSS store", header: 0..<0x10, body: 0x10..<0x110,
                             children: [entry, free])
        let bytes = [UInt8](repeating: 0, count: 0x110)
        let detail = UEFIDetail.build(for: store, image: UEFIImage(size: 0x110, roots: [store]), reader: ImageReader(bytes))

        XCTAssertEqual(field(detail, "In use"), "0xB0 (176) · 68\u{00A0}%")
        XCTAssertEqual(field(detail, "Free space"), "0x50 (80)")
        XCTAssertEqual(field(detail, "Current entries"), "1")
        XCTAssertEqual(field(detail, "Superseded entries"), "0")
        XCTAssertEqual(field(detail, "Deleted entries"), "0")
    }

    /// A VSS2 store holding `copies` of Setup — the values given, all but the
    /// last marked — and one other variable, as the parser lays it out: the
    /// header through the name, then the value.
    private func setupHistory(_ copies: [[UInt8]]) -> (UEFIImage, ImageReader) {
        var bytes = [UInt8](repeating: 0xFF, count: 0x1C)
        var entries: [UEFINode] = []
        func variable(_ name: String, _ value: [UInt8], marked: Bool) {
            let offset = UInt64(bytes.count)
            let ucs2: [UInt8] = name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
            func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
            bytes += [0xAA, 0x55, marked ? 0x3C : 0x3F, 0x00, 0x03, 0x00, 0x00, 0x00]
            bytes += u32(ucs2.count)
            bytes += u32(value.count)
            bytes += [UInt8](repeating: 0x11, count: 16)
            bytes += ucs2
            let nameEnd = UInt64(bytes.count)
            bytes += value
            entries.append(UEFINode(
                kind: .vssEntry,
                subtype: marked ? UEFITypes.Sub.invalidVssEntry : UEFITypes.Sub.standardVssEntry,
                name: marked ? "Invalid" : name, guid: EFIGUID(bytes: [UInt8](repeating: 0x11, count: 16)),
                header: offset..<nameEnd, body: nameEnd..<UInt64(bytes.count), isFixed: true))
        }
        variable("Lang", [0x65], marked: false)
        for (index, value) in copies.enumerated() {
            variable("Setup", value, marked: index < copies.count - 1)
        }
        let store = UEFINode(kind: .vss2Store, name: "VSS2 store", header: 0..<0x1C,
                             body: 0x1C..<UInt64(bytes.count), children: entries)
        return (UEFIImage(size: UInt64(bytes.count), roots: [store]), ImageReader(bytes))
    }

    /// A marked entry names the variable it is a copy of, and every copy is a
    /// row: where it is, what it is now, its size, and what it changed.
    func testAVariablesCopiesAreAHistoryTable() throws {
        let (image, reader) = setupHistory([[0, 0, 0, 0], [0, 1, 1, 0], [0, 1, 1, 0], [0, 1, 1, 0, 5]])
        let focus = image.roots[0].children[2]
        let detail = UEFIDetail.build(for: focus, image: image, reader: reader)
        let table = try XCTUnwrap(detail.tables.first { $0.title == "Variable history" })

        XCTAssertEqual(field(detail, "Variable"), "Setup", "the tree calls it Invalid")
        XCTAssertEqual(table.columns, ["Copy", "Address", "State", "Size", "Change"])
        XCTAssertEqual(table.rows.map { $0[0].text }, ["1", "▸ 2", "3", "4"])
        XCTAssertEqual(table.rowTargets, image.roots[0].children.dropFirst().map(\.id), "a click on a row shows that copy")
        XCTAssertEqual(table.rows.map { $0[1].text }, image.roots[0].children.dropFirst().map { "0x" + String($0.range.lowerBound, radix: 16, uppercase: true) })
        XCTAssertEqual(table.rows.map { $0[2].text }, ["Superseded", "Superseded", "Superseded", "Current"])
        XCTAssertEqual(table.rows.map { $0[3].text }, ["4", "4", "4", "5"])
        XCTAssertEqual(table.rows.map { $0[4].text }, [
            "—", "changed bytes: 2, at +0x1–0x2", "No change", "size 4 → 5",
        ])
    }

    /// A variable the store keeps once has no history, and a live entry needs
    /// no name of its variable beside its own.
    func testAVariableWithOneCopyHasNoHistory() {
        let (image, reader) = setupHistory([[1]])
        let detail = UEFIDetail.build(for: image.roots[0].children[1], image: image, reader: reader)
        XCTAssertNil(detail.tables.first { $0.title == "Variable history" })
        XCTAssertNil(field(detail, "Variable"))
    }

    /// Hundreds of copies list the latest, and the one in focus however old.
    func testALongHistoryShowsTheLatestCopies() throws {
        let (image, reader) = setupHistory((0..<50).map { [UInt8($0)] })
        let detail = UEFIDetail.build(for: image.roots[0].children[1], image: image, reader: reader)
        let rows = try XCTUnwrap(detail.tables.first { $0.title == "Variable history" }).rows

        XCTAssertEqual(rows.count, UEFIDetail.historyRows + 2)
        XCTAssertEqual(rows[0][0].text, "▸ 1")
        XCTAssertEqual(rows[1][1].text, "10 earlier copies not shown")
        XCTAssertEqual(rows.last?[0].text, "50")
    }

    /// A Dell variable is a number in a namespace: its row says both, and its
    /// detail the header's fields, each complemented back.
    func testADvarEntryIsNamedByItsNamespaceAndNumber() {
        let namespace = EFIGUID("417ACEE0-6FA9-4A82-99D7-F9B1DD271E48")!
        // Stored, NameId and NamespaceGuid, 8-bit fields, attributes 7, id 1,
        // the GUID, name id 0x40, two bytes of data.
        let bytes: [UInt8] = [0xFA, 0xF9, 0xFF, 0xF8, 0xFE] + namespace.bytes + [0xBF, 0xFD, 0x01, 0x02]
        let entry = UEFINode(kind: .dvarEntry, subtype: UEFITypes.Sub.namespaceGuidDvarEntry, name: "40",
                             guid: namespace, header: 0..<23, body: 23..<25, isFixed: true)
        let image = UEFIImage(size: 25, roots: [entry])
        let detail = UEFIDetail.build(for: image.roots[0], image: image, reader: ImageReader(bytes))

        XCTAssertEqual(UEFITreeDisplay.name(for: entry, catalogue: .empty), "0x40", "no Setup page names it")
        XCTAssertEqual(UEFITreeDisplay.name(for: entry, catalogue: .empty, reader: ImageReader(bytes)), "0x40 = 0x201",
                       "and its value, little-endian")
        let long = UEFINode(kind: .dvarEntry, subtype: UEFITypes.Sub.namespaceGuidDvarEntry, name: "2",
                            guid: namespace, header: 0..<23, body: 0..<16, isFixed: true)
        XCTAssertEqual(UEFITreeDisplay.name(for: long, catalogue: .empty, reader: ImageReader(bytes)), "0x2 (16 bytes)",
                       "too long for a number: its size")
        XCTAssertEqual(UEFITreeDisplay.typeText(for: entry), "DVAR entry")
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: entry), "NamespaceGuid")
        XCTAssertEqual(field(detail, "State"), "0x5 (Stored)")
        XCTAssertEqual(field(detail, "Entry flags"), "0x6 (NameId, NamespaceGuid)")
        XCTAssertEqual(field(detail, "Namespace ID"), "0x1")
        XCTAssertEqual(field(detail, "Name ID"), "0x40")
        XCTAssertEqual(field(detail, "Data size"), "0x2 (2)")
        XCTAssertEqual(UEFIHelpTerms.term(for: entry)?.rawValue, "dvar")
    }

    /// Where Dell's Setup asks about a DVAR variable, the row is called by
    /// the question's keyword, and the detail says what Setup says: the
    /// option, its page, what this value means there, its help.
    func testADvarEntryIsNamedByTheSetupQuestionAboutIt() throws {
        let namespace = EFIGUID("417ACEE0-6FA9-4A82-99D7-F9B1DD271E48")!
        // A store's header, then a stored entry declaring the namespace, name
        // id 0x40, one byte of data: 1.
        let entryBytes: [UInt8] = [0xFA, 0xF9, 0xFF, 0xF8, 0xFE] + namespace.bytes + [0xBF, 0xFE, 0x01]
        let bytes = Array("DVAR".utf8) + [0xDE, 0xFF, 0xFF, 0xFF, 0x7C] + entryBytes
        let entry = UEFINode(kind: .dvarEntry, subtype: UEFITypes.Sub.namespaceGuidDvarEntry, name: "40",
                             guid: namespace, header: 9..<32, body: 32..<33, isFixed: true)
        let store = UEFINode(kind: .dvarStore, name: "", header: 0..<9, body: 9..<33, children: [entry])
        let settings = DellSetup.Catalogue(settings: [
            DellSetup.Key(namespace: namespace, nameId: 0x40): DellSetup.Setting(
                prompt: "Allow BIOS Downgrade", keyword: "AllowBiosDowngrade",
                help: "Lets an older BIOS be flashed.", form: "Security", kind: .checkbox
            ),
        ])
        let image = UEFIImage(size: 33, roots: [store], dvarSettings: settings)
        let shown = try XCTUnwrap(image.roots.first?.children.first)
        let detail = UEFIDetail.build(for: shown, image: image, reader: ImageReader(bytes))

        XCTAssertEqual(UEFITreeDisplay.name(for: shown, catalogue: .empty, in: image), "AllowBiosDowngrade")
        XCTAssertEqual(UEFITreeDisplay.name(for: shown, catalogue: .empty, in: image, reader: ImageReader(bytes)),
                       "AllowBiosDowngrade = Ticked (0x1)", "the value, as Setup words it")
        XCTAssertEqual(UEFITreeDisplay.name(for: shown, catalogue: .empty), "0x40", "before the forms are read")
        XCTAssertEqual(field(detail, "Setup option"), "Allow BIOS Downgrade")
        XCTAssertEqual(field(detail, "Keyword"), "AllowBiosDowngrade")
        XCTAssertEqual(field(detail, "Setup page"), "Security")
        XCTAssertEqual(field(detail, "Value in Setup"), "Ticked (0x1)")
        XCTAssertEqual(field(detail, "Setup help"), "Lets an older BIOS be flashed.")
    }

    /// The version table's region shows what the table states.
    func testABVDTRegionShowsTheVersionsTheTableStates() {
        let built = TestUEFI.bvdtRegion()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "Flash device map region")
        XCTAssertEqual(field(detail, "BIOS version"), "JKCN31WW")
        XCTAssertEqual(field(detail, "Product name"), "S370-IAU")
        XCTAssertEqual(field(detail, "Kernel version"), "05.44.02")
        XCTAssertEqual(field(detail, "Release date"), "2022-07-21")
        XCTAssertEqual(field(detail, "Compiler"), "MSC 1600 (Visual Studio 2010)")
        XCTAssertEqual(field(detail, "ESRT firmware class"), "F102E4FC-EB52-4FD9-8098-E51308E275F7")
        XCTAssertEqual(field(detail, "ESRT version"), "0x52440031")
    }

    /// The ranges `$BME$` lists, placed in the file, each with what is exactly
    /// there — and a dash where nothing is.
    func testABVDTRegionListsTheRangesOfItsBMERecord() throws {
        let built = TestUEFI.bvdtRegion()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)
        let table = try XCTUnwrap(detail.tables.first { $0.title == "Ranges listed in $BME$" })

        XCTAssertEqual(table.columns, ["Start", "Size", "Holds"])
        XCTAssertEqual(table.rows.map { $0.map(\.text) }, [
            ["0x0", "0x1000 (4096)", "BIOS Version Data Table"],
            ["0x100000", "0x100000 (1048576)", "—"],
        ])
    }

    /// A checksum that does not match says what it should be.
    func testAnNvarEntryWithAWrongChecksumSaysWhatItShouldBe() {
        let built = TestUEFI.nvarEntry(next: 0xFF_FFFF, wrongBy: 1)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertNil(field(detail, "Next entry"))
        let stored = built.bytes[built.bytes.count - 3]
        XCTAssertEqual(
            field(detail, "Checksum"),
            Checksums.text(stored, valid: false, expected: UInt64(stored &- 1))
        )
    }

    /// A SLIC marker's OEM id and table id are stored ASCII, and the windows
    /// flag is the fixed word the parser accepts — shown as that word, never as
    /// the byte soup its little-endian layout would spell.
    func testAMarkerShowsItsOemAndWindowsFlag() {
        let built = TestUEFI.nvramSlicMarker()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "SLIC data")
        XCTAssertEqual(field(detail, "Version"), "0x1")
        XCTAssertEqual(field(detail, "OEM ID"), "TESTCO")
        XCTAssertEqual(field(detail, "OEM table ID"), "TABLID01")
        XCTAssertEqual(field(detail, "Windows flag"), "WINDOWS")
        XCTAssertEqual(field(detail, "SLIC version"), "0x1")
    }

    func testAFirehoseFlashMapReadsItsCountAndReserved() {
        let built = TestUEFI.nvramFlashMapStore(numEntries: 3)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "FlashMap store")
        XCTAssertEqual(field(detail, "Entries"), "3")
        XCTAssertEqual(field(detail, "Reserved"), "0x0")
    }

    /// A flash map entry carries its region's physical layout: the data and
    /// entry types first, then where the region lies.
    func testAFlashMapEntryReadsItsRegionLayout() {
        let built = TestUEFI.nvramFlashMapEntry(
            dataType: 0x0000,
            entryType: 0x0001,
            address: 0xFFF0_0000,
            size: 0x1000,
            offset: 0x40
        )
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "FlashMap entry")
        XCTAssertEqual(field(detail, "Data type"), "0x0")
        XCTAssertEqual(field(detail, "Entry type"), "0x1")
        XCTAssertEqual(field(detail, "Size"), "0x1000 (4096)")
        XCTAssertEqual(field(detail, "Offset"), "0x40")
        XCTAssertEqual(field(detail, "Physical address"), "0xFFF00000")
    }

    // MARK: - Checksum rows and byte-length sizes

    /// A node with nothing to fix reads each checksum as valid and no problem.
    /// The repairs are the caller's word — the parse's, in the running tool —
    /// and the detail renders that word rather than re-reading the body to
    /// second-guess it.
    func testACleanVolumeChecksumIsValidAndNoProblem() {
        let built = TestUEFI.volume()
        let detail = UEFIDetail.build(
            for: built.node, image: built.image, reader: built.reader, repairs: []
        )

        XCTAssertEqual(field(detail, "Checksum"), "0x1234 (Valid)")
        XCTAssertEqual(problem(detail, "Checksum"), false)
    }

    /// A repair sitting on the volume's checksum field reads it as wrong, names
    /// the value the fix would write, and is the problem the controller colours
    /// red — only that row, not the volume's other fields. The repair's bytes
    /// are the fixture's own: this header really does want `0xD4F1`.
    func testAWrongVolumeChecksumSaysWhatItShouldBe() {
        let built = TestUEFI.volume()
        let detail = UEFIDetail.build(
            for: built.node, image: built.image, reader: built.reader,
            repairs: [ChecksumRepair(offset: 0x32, bytes: [0xF1, 0xD4])]
        )

        XCTAssertEqual(field(detail, "Checksum"), "0x1234 (Invalid), should be 0xD4F1")
        XCTAssertEqual(problem(detail, "Checksum"), true)
        XCTAssertEqual(problem(detail, "Length"), false, "only the checksum row is the problem")
    }

    /// A file's header and body checksums are separate fields: a repair on one
    /// reads only that one invalid — a header wants `0xFF`, a body `0xAA`, the
    /// fixture's own values — and the other keeps reading valid.
    func testAFileHeaderAndBodyChecksumsAreMarkedIndependently() {
        let built = TestUEFI.file()

        let headerWrong = UEFIDetail.build(
            for: built.node, image: built.image, reader: built.reader,
            repairs: [ChecksumRepair(offset: 0x10, bytes: [0xFF])]
        )
        XCTAssertEqual(field(headerWrong, "Header checksum"), "0xAA (Invalid), should be 0xFF")
        XCTAssertEqual(problem(headerWrong, "Header checksum"), true)
        XCTAssertEqual(field(headerWrong, "Body checksum"), "0xBB (Valid)")
        XCTAssertEqual(problem(headerWrong, "Body checksum"), false)

        let bodyWrong = UEFIDetail.build(
            for: built.node, image: built.image, reader: built.reader,
            repairs: [ChecksumRepair(offset: 0x11, bytes: [0xAA])]
        )
        XCTAssertEqual(field(bodyWrong, "Header checksum"), "0xAA (Valid)")
        XCTAssertEqual(field(bodyWrong, "Body checksum"), "0xBB (Invalid), should be 0xAA")
        XCTAssertEqual(problem(bodyWrong, "Body checksum"), true)
    }

    /// A microcode image carries one checksum dword; a repair on it reads the
    /// row as the problem, quoting the dword a fix would write — the fixture
    /// wants `0xF8E2D6CA`, and the four repair bytes spell it little-endian.
    func testAMicrocodeChecksumRowSaysWhatItShouldBe() {
        let built = TestUEFI.microcode()

        let clean = UEFIDetail.build(
            for: built.node, image: built.image, reader: built.reader, repairs: []
        )
        XCTAssertEqual(field(clean, "Image checksum"), "0x00000000 (Valid)")
        XCTAssertEqual(problem(clean, "Image checksum"), false)

        let corrupt = UEFIDetail.build(
            for: built.node, image: built.image, reader: built.reader,
            repairs: [ChecksumRepair(offset: 0x10, bytes: [0xCA, 0xD6, 0xE2, 0xF8])]
        )
        XCTAssertEqual(field(corrupt, "Image checksum"), "0x00000000 (Invalid), should be 0xF8E2D6CA")
        XCTAssertEqual(problem(corrupt, "Image checksum"), true)
    }

    /// A byte-length field reads `0x800 (2048)`, while codes and masks on the
    /// same node stay bare hex — the decimal is only for the fields a reader
    /// wants in it.
    func testByteLengthSizesReadInDecimalAndCodesStayHex() {
        let built = TestUEFI.microcode(dataSize: 0x800, totalSize: 0x1000)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Data size"), "0x800 (2048)")
        XCTAssertEqual(field(detail, "Total size"), "0x1000 (4096)")
        XCTAssertEqual(field(detail, "CPUID"), "806EA")
        XCTAssertEqual(field(detail, "Update revision"), "0xF0")
    }
}
