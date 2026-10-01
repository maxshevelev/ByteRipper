import XCTest
@testable import UEFIImage

/// Insyde's Variable Default region (`UEFI_IMAGE_FORMAT.md` §9): a run of
/// `$VSS` stores outside every volume, which the raw-area scan reads as
/// padding — and reads as stores where the flash device map says they are.
final class InsydeVariableDefaultsTests: XCTestCase {
    private static let size: UInt64 = 0x10000
    private static let base: UInt64 = 0x1_0000_0000 - size
    private static let password = KnownGUIDs.guid("C0027E32-8EE5-4D17-9B28-BA50166C4CB4")

    private typealias Entry = (type: EFIGUID, offset: UInt64, size: UInt64)

    /// A flash device map whose entries carry the region types given.
    private static func map(_ entries: [Entry]) -> [UInt8] {
        var body = BinaryWriter()
        for entry in entries {
            body.guid(entry.type)
            body.fill(16, with: 0)                   // RegionId
            body.u64(entry.offset)
            body.u64(entry.size)
            body.u32(FlashDeviceMap.modifiable)
            body.fill(32, with: 0)                   // Hash
        }
        var header = BinaryWriter()
        header.u32(FlashDeviceMap.signature)
        header.u32(UInt32(FlashDeviceMap.headerSize) + UInt32(body.count))
        header.u32(UInt32(FlashDeviceMap.headerSize))
        header.u32(FlashDeviceMap.entrySize)
        header.u8(FlashDeviceMap.entryFormat)
        header.u8(3)                                 // Revision
        header.u8(0)                                 // ExtensionCount
        header.u8(0)                                 // Checksum, filled in below
        header.u64(base)
        var bytes = header.bytes
        bytes[FlashDeviceMap.checksumOffset] = 0 &- Checksums.sum8(bytes)
        return bytes + body.bytes
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

    func testTheRegionTheMapNamesReadsAsItsStores() {
        let parsed = UEFIParser.parse(Self.image())
        let nodes = top(parsed)
        let stores = nodes.filter { $0.kind == .vssStore }

        XCTAssertEqual(stores.map(\.range), [
            0x1000..<(0x1000 + UInt64(Self.firstStore.count)),
            (0x1000 + UInt64(Self.firstStore.count))..<(0x1000 + UInt64(Self.firstStore.count + Self.secondStore.count)),
        ])
        XCTAssertEqual(stores[0].children.map(\.name), ["Setup", "PchSetup"])
        XCTAssertEqual(stores[1].children.map(\.name), ["SaSetup"])
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")

        // The padding before the region and the erased rest of it stay what
        // they were; nothing outside the range the map names is touched.
        let index = nodes.firstIndex { $0.kind == .vssStore }!
        XCTAssertEqual(nodes[index - 1].range, 0..<0x1000)
        XCTAssertEqual(nodes[index - 1].kind, .padding)
        XCTAssertEqual(nodes[index + 2].kind, .freeSpace)
        XCTAssertEqual(nodes[index + 2].range.upperBound, 0x3000)
        XCTAssertEqual(nodes[index + 3].range, 0x3000..<0x4000)
    }

    /// The map's rows are named by region type, the way UEFITool names them.
    func testAnEntryIsNamedByItsRegionType() {
        let map = top(UEFIParser.parse(Self.image())).first { $0.kind == .flashDeviceMapStore }!
        XCTAssertEqual(map.children.map(\.name), ["Variable Defaults", "Password"])
    }

    /// Without a Volume Top File at the tail there is no address to place the
    /// range by, and it stays padding.
    func testWithNoVolumeTopFileAtTheTailTheRegionStaysPadding() {
        let nodes = top(UEFIParser.parse(Self.image(trailing: 0x100)))
        XCTAssertFalse(nodes.contains { $0.kind == .vssStore })
    }

    /// A region nobody wrote is padding still.
    func testAnErasedRegionStaysPadding() {
        let nodes = top(UEFIParser.parse(Self.image(defaults: [])))
        XCTAssertFalse(nodes.contains { $0.kind == .vssStore || $0.kind == .freeSpace })
        XCTAssertEqual(nodes[0].range, 0..<0x4000)
    }

    /// A board can carry the map twice; the range is read once.
    func testTwoMapsNamingTheSameRegionReadItOnce() {
        let entries: [Entry] = [(FlashDeviceMap.variableDefaults, 0x1000, 0x2000)]
        let nodes = top(UEFIParser.parse(Self.image(maps: [entries, entries])))
        XCTAssertEqual(nodes.filter { $0.kind == .vssStore }.count, 2)
        XCTAssertEqual(nodes.filter { $0.kind == .flashDeviceMapStore }.count, 2)
    }

    /// An entry that lands in something already read — here the volume — has
    /// nothing left to do.
    func testAnEntryOutsidePaddingChangesNothing() {
        let entries: [Entry] = [(FlashDeviceMap.variableDefaults, 0xF000, 0x100)]
        let nodes = top(UEFIParser.parse(Self.image(maps: [entries])))
        XCTAssertFalse(nodes.contains { $0.kind == .vssStore })
        XCTAssertEqual(nodes.last?.kind, .volume)
    }
}
