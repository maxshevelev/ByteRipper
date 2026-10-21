import UEFIImage
import XCTest
@testable import UEFITool

/// The DMI button says whose layout the image's store is, and only "DMI" when
/// the stores are more than one vendor's.
final class DMIButtonTitleTests: XCTestCase {
    private static func title(_ kinds: UEFINodeKind...) -> String {
        let stores = kinds.enumerated().map { index, kind in
            DMIStore(kind: kind, range: UInt64(index) * 0x1000..<UInt64(index) * 0x1000 + 0x200)
        }
        return UEFITreeDisplay.dmiButtonTitle(stores, in: .english)
    }

    func testEachVendorByItsLayout() {
        XCTAssertEqual(Self.title(.lenovoDMIStore), "Lenovo DMI")
        XCTAssertEqual(Self.title(.gpnvStore), "ASUS DMI")
        XCTAssertEqual(Self.title(.acerDMIStore), "Acer DMI")
        XCTAssertEqual(Self.title(.vssEntry), "HP DMI")
        XCTAssertEqual(Self.title(.sysFStore), "Apple DMI")
    }

    func testTwoStoresOfOneVendorNameIt() {
        XCTAssertEqual(Self.title(.lenovoDMIStore, .lenovoDMIStore), "Lenovo DMI")
    }

    func testStoresOfTwoVendorsAreJustDMI() {
        XCTAssertEqual(Self.title(.lenovoDMIStore, .gpnvStore), "DMI")
    }
}
