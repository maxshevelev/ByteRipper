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

    func testTheTreeListsEmptyPaddingOnlyWhenAsked() {
        let nodes = [volume, erased, data, free]
        XCTAssertEqual(UEFITreeDisplay.listed(nodes, showsEmptyPadding: false).map(\.name),
                       ["FFSv2", "Padding", "Free space"])
        XCTAssertEqual(UEFITreeDisplay.listed(nodes, showsEmptyPadding: true).map(\.name),
                       ["FFSv2", "Empty padding", "Padding", "Free space"])
    }
}
