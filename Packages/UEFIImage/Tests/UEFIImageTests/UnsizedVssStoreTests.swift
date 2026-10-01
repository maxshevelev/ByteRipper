import XCTest
@testable import UEFIImage

/// A `$VSS` store whose size field holds the "no size" marker, outside an FDC
/// — Insyde's live variable store (`UEFI_IMAGE_FORMAT.md` §9). The reference
/// refuses it; it is read here by its own structure: variables while the
/// marker holds, then erased bytes, and the store ends where they do.
final class UnsizedVssStoreTests: XCTestCase {
    private func unsized(_ variables: [[UInt8]], freeSpace: UInt64) -> [UInt8] {
        TestNVRAM.vssStore(variables: variables, size: 0xFFFF_FFFF, freeSpace: freeSpace)
    }

    func testTheStoreEndsWhereItsFreeSpaceDoes() {
        let variables = [TestNVRAM.vssVariable(name: "PK"), TestNVRAM.vssVariable(name: "KEK")]
        let store = unsized(variables, freeSpace: 0x100)
        let parsed = UEFIParser.parse(TestNVRAM.nvramVolume(stores: [store, TestNVRAM.ftwStore()]))
        let volume = parsed.roots[0]

        XCTAssertEqual(volume.children.map(\.kind), [.vssStore, .ftwStore])
        XCTAssertEqual(volume.children[0].range, 0x48..<(0x48 + UInt64(store.count)))
        XCTAssertEqual(volume.children[0].children.map(\.kind), [.vssEntry, .vssEntry, .freeSpace])
        XCTAssertEqual(volume.children[0].children.prefix(2).map(\.name), ["PK", "KEK"])
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// With nothing after it, the store reaches the end of the body.
    func testWithNothingAfterItTheStoreReachesTheBodysEnd() {
        let store = unsized([TestNVRAM.vssVariable(name: "PK")], freeSpace: 0x40)
        let volume = UEFIParser.parse(TestNVRAM.nvramVolume(stores: [store], length: 0x200)).roots[0]

        XCTAssertEqual(volume.children.map(\.kind), [.vssStore])
        XCTAssertEqual(volume.children[0].range.upperBound, 0x200)
    }

    /// A header with no variable after it is not measured, and stays padding.
    func testAStoreWithNoVariableStaysPadding() {
        let volume = UEFIParser.parse(TestNVRAM.nvramVolume(stores: [unsized([], freeSpace: 0x40)])).roots[0]
        XCTAssertFalse(volume.children.contains { $0.kind == .vssStore })
    }

    /// Only a plain `$VSS` is measured; an Apple store with the marker is
    /// refused, as the reference refuses it.
    func testAnAppleStoreWithTheMarkerIsRefused() {
        let store = TestNVRAM.vssStore(
            variables: [TestNVRAM.vssVariable(name: "PK")],
            signature: NVRAM.appleSvsSignature, size: 0xFFFF_FFFF, freeSpace: 0x40
        )
        let volume = UEFIParser.parse(TestNVRAM.nvramVolume(stores: [store])).roots[0]
        XCTAssertFalse(volume.children.contains { $0.kind == .vssStore })
    }
}
