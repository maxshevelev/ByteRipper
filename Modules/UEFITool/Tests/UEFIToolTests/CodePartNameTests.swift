import UEFIImage
import XCTest
@testable import UEFITool

/// What a Code panel is called: the module the tree names and the image's
/// format, not the image section's own name, which every module shares.
final class CodePartNameTests: XCTestCase {
    func testACodePanelIsNamedAfterItsModuleAndFormat() {
        let pe32 = UEFINode(id: .root.child(0).child(0).child(1), kind: .section, subtype: 0x10,
                            name: "PE32 image", header: 0x1C..<0x20, body: 0x20..<0x80)
        let te = UEFINode(id: .root.child(0).child(1).child(0), kind: .section, subtype: 0x12,
                          name: "TE image", header: 0x9C..<0xA0, body: 0xA0..<0xF0)
        let secCore = UEFINode(id: .root.child(0).child(0), kind: .file, subtype: 0x03,
                               name: "SecCore", header: 0..<0x18, body: 0x18..<0x80,
                               children: [UEFINode(id: .root.child(0).child(0).child(0), kind: .section,
                                                   subtype: 0x15, name: "UI", header: 0x18..<0x1C, body: 0x1C..<0x1C),
                                          pe32])
        let peim = UEFINode(id: .root.child(0).child(1), kind: .file, subtype: 0x06,
                            name: "S3RestoreAcpiPei", header: 0x80..<0x98, body: 0x98..<0xF0, children: [te])
        let volume = UEFINode(id: .root.child(0), kind: .volume, name: "Volume",
                              header: 0..<0, body: 0..<0x100, children: [secCore, peim])
        let image = UEFIImage(size: 0x100, roots: [volume])

        XCTAssertEqual(UEFIPresenter.codePartName(of: pe32.id, in: image, bytes: [0x4D, 0x5A]), "SecCore ▸ PE32")
        XCTAssertEqual(UEFIPresenter.codePartName(of: te.id, in: image, bytes: [0x56, 0x5A]), "S3RestoreAcpiPei ▸ TE")
        XCTAssertEqual(UEFIPresenter.codePartName(of: peim.id, in: image, bytes: [0x56, 0x5A]), "S3RestoreAcpiPei ▸ TE",
                       "a file whose body is the image: the bytes say the format")
        XCTAssertNil(UEFIPresenter.codePartName(of: volume.id, in: image, bytes: []), "no file, no module name")
    }
}
