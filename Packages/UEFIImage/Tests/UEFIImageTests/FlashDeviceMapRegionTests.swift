import XCTest
@testable import UEFIImage

/// The regions an Insyde flash device map names (`UEFI_IMAGE_FORMAT.md` §9):
/// ranges outside every volume, with no signature, which the raw-area scan
/// reads as padding — and reads as regions named by type where the map says
/// they are. A Variable Defaults region is read further, as its `$VSS` stores.
final class FlashDeviceMapRegionTests: XCTestCase {
    private static let size: UInt64 = 0x10000
    private static let base: UInt64 = 0x1_0000_0000 - size
    private static let password = KnownGUIDs.guid("C0027E32-8EE5-4D17-9B28-BA50166C4CB4")
    private static let unnamed = KnownGUIDs.guid("0BADF00D-0000-4000-8000-000000000001")

    private typealias Entry = (type: EFIGUID, offset: UInt64, size: UInt64)

    /// A flash device map whose entries carry the region types given.
    private static func map(_ entries: [Entry]) -> [UInt8] {
        TestFlashDeviceMap.map(entries, base: base)
    }

    private static let firstStore = TestNVRAM.vssStore(
        variables: [TestNVRAM.vssVariable(name: "Setup"), TestNVRAM.vssVariable(name: "PchSetup")],
        freeSpace: 0
    )
    private static let secondStore = TestNVRAM.vssStore(
        variables: [TestNVRAM.vssVariable(name: "SaSetup")],
        freeSpace: 0
    )

    /// A 64 KiB image with no descriptor: the defaults at `0x1000`, the map at
    /// `0x4000`, and a volume ending in the Volume Top File flush against the
    /// image's end — which maps it at `0xFFFF0000`.
    private static func image(
        defaults: [UInt8] = firstStore + secondStore,
        maps: [[Entry]] = [[(FlashDeviceMap.variableDefaults, 0x1000, 0x2000), (password, 0x3000, 0x100)]],
        trailing: Int = 0
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: Int(size))
        bytes.replaceSubrange(0x1000..<(0x1000 + defaults.count), with: defaults)
        var at = 0x4000
        for entries in maps {
            let store = map(entries)
            bytes.replaceSubrange(at..<(at + store.count), with: store)
            at += 0x400
        }
        let volume = TestImage.volume(length: 0x1000, lastFile: TestImage.volumeTopFile())
        bytes.replaceSubrange(0xF000..<0x10000, with: volume)
        return bytes + [UInt8](repeating: 0xFF, count: trailing)
    }

    private func top(_ parsed: UEFIImage) -> [UEFINode] {
        parsed.roots[0].children
    }

    /// The regions placed among `nodes`: rows inside the padding that holds
    /// them.
    private func regions(_ nodes: [UEFINode]) -> [UEFINode] {
        nodes.flatMap { $0.kind == .padding ? $0.children : [$0] }.filter { $0.kind == .flashDeviceMapRegion }
    }

    func testTheVariableDefaultsRegionReadsAsItsStores() {
        let parsed = UEFIParser.parse(Self.image())
        let nodes = top(parsed)
        let defaults = regions(nodes).first { $0.guid == FlashDeviceMap.variableDefaults }!
        let stores = defaults.children.filter { $0.kind == .vssStore }

        XCTAssertEqual(defaults.range, 0x1000..<0x3000)
        XCTAssertEqual(defaults.name, "Variable Defaults")
        XCTAssertEqual(stores.map(\.range), [
            0x1000..<(0x1000 + UInt64(Self.firstStore.count)),
            (0x1000 + UInt64(Self.firstStore.count))..<(0x1000 + UInt64(Self.firstStore.count + Self.secondStore.count)),
        ])
        XCTAssertEqual(stores[0].children.map(\.name), ["Setup", "PchSetup"])
        XCTAssertEqual(stores[1].children.map(\.name), ["SaSetup"])
        XCTAssertEqual(defaults.children.last?.kind, .freeSpace)
        XCTAssertEqual(defaults.children.last?.range.upperBound, 0x3000)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// Every other region is a leaf named by its type, a row inside the
    /// padding that holds it: the padding keeps its place, range and name,
    /// and nothing outside the range the map names is touched.
    func testARegionIsARowOfThePaddingAndNamedByItsType() {
        let outer = top(UEFIParser.parse(Self.image()))[0]
        XCTAssertEqual(outer.kind, .padding)
        XCTAssertEqual(outer.range, 0..<0x4000)
        XCTAssertEqual(outer.name, "Padding")
        let nodes = outer.children
        let found = regions(nodes)

        XCTAssertEqual(found.map(\.name), ["Variable Defaults", "Password"])
        XCTAssertEqual(found.map(\.range), [0x1000..<0x3000, 0x3000..<0x3100])
        XCTAssertEqual(found[1].guid, Self.password)
        XCTAssertTrue(found[1].children.isEmpty)
        XCTAssertTrue(found.allSatisfy(\.isFixed))

        let index = nodes.firstIndex { $0.kind == .flashDeviceMapRegion }!
        XCTAssertEqual(nodes[index - 1].range, 0..<0x1000)
        XCTAssertEqual(nodes[index - 1].kind, .padding)
        XCTAssertEqual(nodes[index + 2].range, 0x3100..<0x4000)
        XCTAssertEqual(nodes[index + 2].kind, .padding)
    }

    /// The Type column keeps UEFITool's word for these bytes, and the
    /// subtype says whether anything was written.
    func testARegionClassifiesAsPadding() {
        let nodes = top(UEFIParser.parse(Self.image()))
        let password = regions(nodes).first { $0.guid == Self.password }!
        let defaults = regions(nodes).first { $0.guid == FlashDeviceMap.variableDefaults }!

        XCTAssertEqual(password.uefiItemType, UEFITypes.Item.padding.rawValue)
        XCTAssertTrue(password.isErased)
        XCTAssertEqual(password.uefiItemSubtype, UEFITypes.Sub.onePadding)
        XCTAssertFalse(defaults.isErased)
        XCTAssertEqual(defaults.uefiItemSubtype, UEFITypes.Sub.dataPadding)
    }

    /// A type UEFITool does not name is still a region, called what it is.
    func testARegionOfAnUnnamedTypeKeepsItsGUID() {
        let entries: [Entry] = [(Self.unnamed, 0x2000, 0x800)]
        let found = regions(top(UEFIParser.parse(Self.image(maps: [entries]))))
        XCTAssertEqual(found.map(\.guid), [Self.unnamed])
        XCTAssertEqual(found.first?.name, "Flash device map region")
    }

    /// An EC Firmware region that opens on an ITE image adds its
    /// identification to the type's name.
    func testAnECRegionIsNamedByTheImageItHolds() {
        var bytes = Self.image(maps: [[(FlashDeviceMap.ecFirmware, 0x2000, 0x1000)]])
        bytes.replaceSubrange(0x2000..<0x3000, with: ITEFirmwareTests.image())
        let found = regions(top(UEFIParser.parse(bytes)))
        XCTAssertEqual(found.map(\.name), ["EC Firmware (ITE8380-EC-V1.43)"])
    }

    /// The image in an EC Firmware region is as long as the map's entry, not
    /// as its last written byte: the entry is the firmware's own slot, and
    /// the erased tail is part of it — 128 KB in `CSME 12`, not 96.
    func testAnECRegionsImageIsAsLongAsItsEntry() throws {
        var bytes = Self.image(maps: [[(FlashDeviceMap.ecFirmware, 0x2000, 0x2000)]])
        bytes.replaceSubrange(0x2000..<0x3000, with: ITEFirmwareTests.image())
        let region = try XCTUnwrap(regions(top(UEFIParser.parse(bytes))).first)

        XCTAssertEqual(region.range, 0x2000..<0x4000)
        XCTAssertEqual(region.namedImageLength, 0x2000, "the entry's size, though half of it is erased")
    }

    /// An entry gives the region's size, not each image's: with several images
    /// in the region each runs to its last written byte, as anywhere else —
    /// `LENV_CSME 16`'s 512 KB region holds a 16 KB and two 192 KB images.
    func testSeveralImagesInAnECRegionAreMeasuredByTheirBytes() throws {
        var bytes = Self.image(maps: [[(FlashDeviceMap.ecFirmware, 0x2000, 0x2000)]])
        bytes.replaceSubrange(0x2000..<0x2800, with: ITEFirmwareTests.image("ITE5507-SB-V0.67", length: 0x800))
        bytes.replaceSubrange(0x3000..<0x3800, with: ITEFirmwareTests.image("ITE8380-EC-V0.00", length: 0x800))
        let region = try XCTUnwrap(regions(top(UEFIParser.parse(bytes))).first)

        XCTAssertEqual(region.name, "EC Firmware")
        XCTAssertNil(region.namedImageLength)
        XCTAssertEqual(region.children.filter { $0.kind == .ecImage }.map(\.range),
                       [0x2000..<0x3000, 0x3000..<0x4000])
    }

    /// The map's rows are named by region type, the way UEFITool names them.
    func testAnEntryIsNamedByItsRegionType() {
        let map = top(UEFIParser.parse(Self.image())).first { $0.kind == .flashDeviceMapStore }!
        XCTAssertEqual(map.children.map(\.name), ["Variable Defaults", "Password"])
    }

    /// Without a Volume Top File at the tail there is no address to place the
    /// ranges by, and they stay padding.
    func testWithNoVolumeTopFileAtTheTailTheRegionsStayPadding() {
        let nodes = top(UEFIParser.parse(Self.image(trailing: 0x100)))
        XCTAssertTrue(regions(nodes).isEmpty)
        XCTAssertFalse(nodes.flatMap(\.flattened).contains { $0.kind == .vssStore })
    }

    /// A full dump with bytes appended after it: the descriptor says where
    /// the BIOS region ends, and that end is the one mapped at the top.
    func testBytesAppendedAfterTheBiosRegionDoNotHideTheRegions() {
        var bytes = Self.image(trailing: 0xC00)
        let descriptor = TestImage.descriptor(regions: [(.descriptor, 0..<0x1000), (.bios, 0x1000..<Self.size)])
        bytes.replaceSubrange(0..<descriptor.count, with: descriptor)
        let parsed = UEFIParser.parse(bytes)
        let bios = parsed.roots[0].children.first { $0.kind == .region }!

        XCTAssertEqual(regions(bios.children).map(\.name), ["Variable Defaults", "Password"])
        XCTAssertEqual(regions(bios.children).map(\.range), [0x1000..<0x3000, 0x3000..<0x3100])
    }

    /// An AMD board's flash ends in no Volume Top File; the map's entry for
    /// its own region says where it is, and places the rest by it.
    func testWithNoVolumeTopFileTheMapPlacesItselfByItsOwnEntry() {
        let entries: [Entry] = [(FlashDeviceMap.variableDefaults, 0x1000, 0x2000), (Self.password, 0x3000, 0x100),
                                (FlashDeviceMap.flashDeviceMap, 0x4000, 0x1000)]
        let nodes = top(UEFIParser.parse(Self.image(maps: [entries], trailing: 0x100)))
        XCTAssertEqual(regions(nodes).map(\.name), ["Variable Defaults", "Password"])
        XCTAssertEqual(regions(nodes).map(\.range), [0x1000..<0x3000, 0x3000..<0x3100])
    }

    /// A copy of the map somewhere else — inside a file — keeps the
    /// original's entries; an answer that is not a whole number of 4 KiB
    /// blocks is that, and is not taken.
    func testAMapAwayFromItsOwnRegionDoesNotPlaceItself() throws {
        let entries: [Entry] = [(FlashDeviceMap.flashDeviceMap, 0x4000, 0x1000)]
        var bytes = [UInt8](repeating: 0xFF, count: 0x8000)
        let store = Self.map(entries)
        bytes.replaceSubrange(0x4000..<(0x4000 + store.count), with: store)
        bytes.replaceSubrange(0x5124..<(0x5124 + store.count), with: store)
        let reader = ImageReader(bytes)
        func node(at offset: UInt64) -> UEFINode {
            let entry = offset + FlashDeviceMap.headerSize
            return UEFINode(kind: .flashDeviceMapStore, name: "", header: offset..<entry,
                            body: entry..<(entry + UInt64(FlashDeviceMap.entrySize)), children: [
                UEFINode(kind: .flashDeviceMapEntry, name: "", guid: FlashDeviceMap.flashDeviceMap,
                         header: entry..<(entry + UInt64(FlashDeviceMap.entrySize)),
                         body: (entry + UInt64(FlashDeviceMap.entrySize))..<(entry + UInt64(FlashDeviceMap.entrySize))),
            ])
        }
        XCTAssertEqual(FlashDeviceMap.addressDiff(of: node(at: 0x4000), reader: reader), Self.base)
        XCTAssertNil(FlashDeviceMap.addressDiff(of: node(at: 0x5124), reader: reader))
    }

    /// A Variable Defaults region nobody wrote is a region still, with no
    /// stores in it.
    func testAnErasedVariableDefaultsRegionHoldsNoStores() {
        let defaults = regions(top(UEFIParser.parse(Self.image(defaults: [])))).first {
            $0.guid == FlashDeviceMap.variableDefaults
        }!
        XCTAssertTrue(defaults.children.isEmpty)
        XCTAssertTrue(defaults.isErased)
    }

    /// A board can carry the map twice; each range is read once.
    func testTwoMapsNamingTheSameRegionReadItOnce() {
        let entries: [Entry] = [(FlashDeviceMap.variableDefaults, 0x1000, 0x2000)]
        let nodes = top(UEFIParser.parse(Self.image(maps: [entries, entries])))
        XCTAssertEqual(regions(nodes).count, 1)
        XCTAssertEqual(regions(nodes)[0].children.filter { $0.kind == .vssStore }.count, 2)
        XCTAssertEqual(nodes.filter { $0.kind == .flashDeviceMapStore }.count, 2)
    }

    /// Where two entries overlap, the one that starts first is placed, and the
    /// other — no longer inside padding — stays out.
    func testOfTwoOverlappingEntriesTheFirstByAddressIsPlaced() {
        let entries: [Entry] = [(Self.password, 0x2800, 0x1000), (Self.unnamed, 0x2000, 0x1000)]
        let found = regions(top(UEFIParser.parse(Self.image(defaults: [], maps: [entries]))))
        XCTAssertEqual(found.map(\.guid), [Self.unnamed])
        XCTAssertEqual(found.map(\.range), [0x2000..<0x3000])
    }

    /// An entry that lands in something already read — here the volume — has
    /// nothing left to do.
    func testAnEntryOutsidePaddingChangesNothing() {
        let entries: [Entry] = [(FlashDeviceMap.variableDefaults, 0xF000, 0x100)]
        let nodes = top(UEFIParser.parse(Self.image(maps: [entries])))
        XCTAssertTrue(regions(nodes).isEmpty)
        XCTAssertEqual(nodes.last?.kind, .volume)
    }
}
