import XCTest
import UEFIImage
@testable import UEFITool

/// Which rows the tree leaves out while empty padding is hidden.
final class EmptyPaddingTests: XCTestCase {
    private let erased = UEFINode(kind: .padding, name: "Empty padding", range: 0x1000..<0x2000, isErased: true)
    private let data = UEFINode(kind: .padding, name: "Padding", range: 0x2000..<0x2100, isErased: false)
    private let free = UEFINode(kind: .freeSpace, name: "Free space", range: 0x90..<0x1000, isErased: true)
    private let volume = UEFINode(kind: .volume, name: "FFSv2", header: 0..<0x48, body: 0x48..<0x1000)

    /// Only erased padding is empty padding: padding that holds bytes, and a
    /// volume's free space, are rows worth their room.
    func testOnlyErasedPaddingIsEmptyPadding() {
        XCTAssertTrue(UEFITreeDisplay.isEmptyPadding(erased))
        XCTAssertFalse(UEFITreeDisplay.isEmptyPadding(data))
        XCTAssertFalse(UEFITreeDisplay.isEmptyPadding(free))
        XCTAssertFalse(UEFITreeDisplay.isEmptyPadding(volume))
    }

    /// Erased padding with rows read into it — an Insyde map's region
    /// nobody has written — is listed, or its rows would go with it.
    func testErasedPaddingWithRowsIsListed() {
        let region = UEFINode(kind: .flashDeviceMapRegion, name: "Unused", header: 0x1000..<0x1000,
                              body: 0x1000..<0x2000, isErased: true)
        var holding = erased
        holding.children = [region]
        XCTAssertFalse(UEFITreeDisplay.isEmptyPadding(holding))
        XCTAssertEqual(UEFITreeDisplay.listed([holding], showsEmptyPadding: false).count, 1)
    }

    func testTheTreeListsEmptyPaddingOnlyWhenAsked() {
        let nodes = [volume, erased, data, free]
        XCTAssertEqual(UEFITreeDisplay.listed(nodes, showsEmptyPadding: false).map(\.name),
                       ["FFSv2", "Padding", "Free space"])
        XCTAssertEqual(UEFITreeDisplay.listed(nodes, showsEmptyPadding: true).map(\.name),
                       ["FFSv2", "Empty padding", "Padding", "Free space"])
    }

    /// The copies a store's later entries replaced are left out by id, with
    /// the empty padding or without it.
    func testTheTreeLeavesOutTheCopiesItIsToldTo() {
        let image = UEFIImage(size: 0x3000, roots: [volume, erased, data, free])
        let ids = image.roots.map(\.id)
        XCTAssertEqual(UEFITreeDisplay.listed(image.roots, showsEmptyPadding: true, hiding: [ids[2]]).map(\.name),
                       ["FFSv2", "Empty padding", "Free space"])
        XCTAssertEqual(UEFITreeDisplay.listed(image.roots, showsEmptyPadding: false, hiding: [ids[0]]).map(\.name),
                       ["Padding", "Free space"])
    }

    /// An erased pad file is hidden with the empty padding; one holding data stays.
    func testAnErasedPadFileIsEmptyPadding() {
        let empty = UEFINode(kind: .file, subtype: 0xF0, name: "Padding file", guid: .zero,
                             header: 0..<0x18, body: 0x18..<0x100)
        var holding = empty
        holding.children = [UEFINode(kind: .padding, name: "Non-UEFI data", range: 0x40..<0x100)]
        let raw = UEFINode(kind: .file, subtype: 0x01, name: "", guid: .zero,
                           header: 0..<0x18, body: 0x18..<0x100)
        XCTAssertTrue(UEFITreeDisplay.isEmptyPadding(empty))
        XCTAssertFalse(UEFITreeDisplay.isEmptyPadding(holding))
        XCTAssertFalse(UEFITreeDisplay.isEmptyPadding(raw))
        XCTAssertEqual(UEFITreeDisplay.listed([empty, holding, raw], showsEmptyPadding: false).count, 2)
        XCTAssertEqual(UEFITreeDisplay.listed([empty, holding, raw], showsEmptyPadding: true).count, 3)
    }
}
