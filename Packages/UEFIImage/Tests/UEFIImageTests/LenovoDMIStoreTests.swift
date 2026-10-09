import XCTest
import LenovoDMI
@testable import UEFIImage

/// Lenovo's DMI store (`LenovoDMIStore`): read as one row with the log and
/// both blocks under it — in place of the three regions an Insyde map
/// declares, or out of the padding it lies in — and a `LENV` block on its own
/// the same way. The format itself is `LenovoDMI`'s and tested there; these
/// check the rows.
final class LenovoDMIStoreTests: XCTestCase {
    private static let size: UInt64 = 0x10000
    private static let base: UInt64 = 0x1_0000_0000 - size
    /// The region type Insyde's map gives the three: "Unknown".
    private static let unknown = KnownGUIDs.guid("201D65E5-BE23-4875-80F8-B1D4795E7E08")

    private static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    /// A block with `entries`, XORed with `key`, its checksum in order.
    private static func block(generation: UInt32, key: UInt8, entries: [(UInt16, [UInt8])]) -> [UInt8] {
        var body: [UInt8] = []
        for (type, data) in entries {
            body += LenovoDMIFormat.smbiosNamespace
            body += [UInt8(type & 0xFF), UInt8(type >> 8)]
            body += le32(UInt32(data.count)) + [0, 0, 0, 0] + data
        }
        body += [UInt8](repeating: 0, count: 0x1000 - 16 - body.count)
        body = body.map { $0 ^ key }
        let sum = body.reduce(UInt16(0)) { $0 &+ UInt16($1) }
        return Array("LENV".utf8) + le32(generation) + le32(UInt32(entries.count))
            + [0, key, UInt8(sum & 0xFF), UInt8(sum >> 8)] + body
    }

    /// A log with one write of the serial number.
    private static func log(key: UInt8) -> [UInt8] {
        var body: [UInt8] = [0x22, 0x20, 0x06, 0x29, 0x20, 0x30, 0x25, 0x02]
        body += LenovoDMIFormat.smbiosNamespace + [0x00, 0x04] + le32(8) + [0, 0, 0, 0]
        body += [UInt8](repeating: 0, count: 0x2000 - 0x20 - body.count)
        return Array("LDBG".utf8) + le32(0x40) + [UInt8](repeating: 0, count: 24) + body.map { $0 ^ key }
    }

    private static let serial: (UInt16, [UInt8]) = (0x0400, Array("PF0TEST1".utf8))
    private static let mtm: (UInt16, [UInt8]) = (0x0200, Array("82XX0000GE".utf8))

    /// The log, block 1 at generation 3 and block 2 at generation 4.
    private static let store: [UInt8] = log(key: 0x77)
        + block(generation: 3, key: 0x77, entries: [serial, mtm])
        + block(generation: 4, key: 0x77, entries: [serial])

    /// A 64 KiB image with no descriptor: the store at `0x8000`, a map at
    /// `0x4000` when `mapped`, and a volume ending in the Volume Top File
    /// flush against the image's end — which maps it at `0xFFFF0000`.
    private static func image(mapped: Bool, storeAt offset: Int = 0x8000) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: Int(size))
        bytes.replaceSubrange(offset..<(offset + store.count), with: store)
        if mapped {
            let map = TestFlashDeviceMap.map([
                (unknown, UInt64(offset), 0x2000),
                (unknown, UInt64(offset) + 0x2000, 0x1000),
                (unknown, UInt64(offset) + 0x3000, 0x1000)
            ], base: base)
            bytes.replaceSubrange(0x4000..<(0x4000 + map.count), with: map)
        }
        let volume = TestImage.volume(length: 0x1000, lastFile: TestImage.volumeTopFile())
        bytes.replaceSubrange(0xF000..<0x10000, with: volume)
        return bytes
    }

    private func stores(_ parsed: UEFIImage) -> [UEFINode] {
        parsed.allNodes.filter { $0.kind == .lenovoDMIStore }
    }

    /// The map's three "Unknown" regions are the one store they are: a row in
    /// their place, the log and the blocks under it, the block the firmware
    /// reads marked, and nothing of them left as a map region.
    func testTheMapsThreeRegionsAreOneStore() throws {
        let parsed = UEFIParser.parse(Self.image(mapped: true))
        let store = try XCTUnwrap(stores(parsed).first)
        XCTAssertEqual(stores(parsed).count, 1)
        XCTAssertEqual(store.range, 0x8000..<0xC000)
        XCTAssertTrue(store.isFixed, "the firmware finds it where the map says")
        XCTAssertFalse(parsed.allNodes.contains { $0.kind == .flashDeviceMapRegion && $0.guid == Self.unknown })
        XCTAssertEqual(store.children.map(\.kind), [.ldbgLog, .lenvBlock, .lenvBlock])
        XCTAssertEqual(store.children.map(\.range), [0x8000..<0xA000, 0xA000..<0xB000, 0xB000..<0xC000])
        XCTAssertEqual(store.children.map(\.subtype), [nil, 0, 1], "block 2 has the higher generation")
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// Without a map the store is read out of the padding it lies in, which
    /// keeps its place, range and name.
    func testWithoutAMapTheStoreIsReadOutOfPadding() throws {
        let parsed = UEFIParser.parse(Self.image(mapped: false))
        let store = try XCTUnwrap(stores(parsed).first)
        XCTAssertEqual(store.range, 0x8000..<0xC000)
        let outer = try XCTUnwrap(parsed.roots[0].children.first { $0.range.contains(0x8000) })
        XCTAssertEqual(outer.kind, .padding)
        XCTAssertEqual(outer.children.map(\.kind), [.padding, .lenovoDMIStore, .padding])
        XCTAssertEqual(outer.children.first?.range.upperBound, 0x8000)
        XCTAssertEqual(outer.children.last?.range.lowerBound, 0xC000)
    }

    /// Each entry's row is its header and its value, in the file, named by
    /// what it holds; the log's rows are its dated writes.
    func testEntriesAreRowsOfTheirBlock() throws {
        let store = try XCTUnwrap(stores(UEFIParser.parse(Self.image(mapped: true))).first)
        let entries = store.children[1].children
        XCTAssertEqual(entries.map(\.kind), [.lenvEntry, .lenvEntry])
        XCTAssertEqual(entries.map(\.name), ["Baseboard serial number", "Machine type/model"])
        XCTAssertEqual(entries[0].header, 0xA010..<0xA028)
        XCTAssertEqual(entries[0].body, 0xA028..<0xA030)
        XCTAssertEqual(entries[1].header.lowerBound, 0xA030)
        XCTAssertEqual(store.children[1].header, 0xA000..<0xA010)

        let writes = store.children[0].children
        XCTAssertEqual(writes.map(\.name), ["2022-06-29 20:30:25"])
        XCTAssertEqual(writes.map(\.kind), [.ldbgEntry])
    }

    /// To UEFITool these bytes are padding, as a GPNV store's are.
    func testTheStoreClassifiesAsPadding() throws {
        let store = try XCTUnwrap(stores(UEFIParser.parse(Self.image(mapped: true))).first)
        for node in store.flattened {
            XCTAssertEqual(node.uefiItemType, UEFITypes.Item.padding.rawValue, "\(node.kind)")
        }
    }

    /// A block on its own — what a block opened out of a dump is — reads as a
    /// block, with no other to be chosen over.
    func testABlockOnItsOwnIsABlock() throws {
        let block = Self.block(generation: 3, key: 0x77, entries: [Self.serial])
        let parsed = UEFIParser.parse(block)
        let row = try XCTUnwrap(parsed.allNodes.first { $0.kind == .lenvBlock })
        XCTAssertEqual(row.range, 0..<0x1000)
        XCTAssertNil(row.subtype)
        XCTAssertEqual(row.children.map(\.name), ["Baseboard serial number"])
        XCTAssertTrue(stores(parsed).isEmpty)
    }

    /// The tree finds the store without the panel opening the way to it:
    /// a copy with every container in the file opened says where it is.
    @MainActor
    func testTheTreeFindsTheStoreWhereverItLies() async {
        let tree = LazyUEFITree(Self.image(mapped: true))
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        await withCheckedContinuation { continuation in tree.resolveDMIStores { continuation.resume() } }
        XCTAssertEqual(tree.dmiStores, [DMIStore(kind: .lenovoDMIStore, range: 0x8000..<0xC000)])
    }

    @MainActor
    func testAnImageWithoutAStoreHasNone() async {
        var bytes = Self.image(mapped: false)
        bytes.replaceSubrange(0x8000..<0xC000, with: [UInt8](repeating: 0xFF, count: 0x4000))
        let tree = LazyUEFITree(bytes)
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        await withCheckedContinuation { continuation in tree.resolveDMIStores { continuation.resume() } }
        XCTAssertEqual(tree.dmiStores, [])
    }

    /// The drivers that name an entry's key are found in the image's code —
    /// here a constant, the namespace and the type in a row — and named by
    /// their files.
    @MainActor
    func testTheTreeNamesTheDriversThatReadAnEntry() async {
        let code = [UInt8](repeating: 0, count: 0x20) + LenovoDMIFormat.smbiosNamespace + [0x00, 0x04]
        let driver = TestImage.sectionedFile(sections: [
            TestImage.section(type: 0x10, body: code),
            TestImage.nameSection("L05SmbiosOverride")
        ])
        var bytes = Self.image(mapped: false)
        let volume = TestImage.volume(length: 0x1000, files: [driver])
        bytes.replaceSubrange(0x1000..<0x2000, with: volume)
        let tree = LazyUEFITree(bytes)
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        let named = expectation(description: "the drivers are searched")
        let token = tree.addObserver { change in
            if case .lenovoDMIReadersRead = change { named.fulfill() }
        }
        tree.resolveLenovoDMIReaders()
        await fulfillment(of: [named], timeout: 5)
        tree.removeObserver(token)
        XCTAssertEqual(tree.lenovoDMIReaders?.drivers(of: .smbios(0x0400)), ["L05SmbiosOverride"])
        XCTAssertEqual(tree.lenovoDMIReaders?.drivers(of: .smbios(0x0200)), [])
    }

    /// `LDBG` with nothing signed after it is not the store: driver code
    /// names the signature too.
    func testAStrayLDBGIsNotAStore() {
        var bytes = Self.image(mapped: false)
        bytes.replaceSubrange(0x8000..<0xC000, with: Self.log(key: 0x77) + [UInt8](repeating: 0x11, count: 0x2000))
        let parsed = UEFIParser.parse(bytes)
        XCTAssertTrue(stores(parsed).isEmpty)
        XCTAssertFalse(parsed.allNodes.contains { $0.kind == .lenvBlock })
    }
}
