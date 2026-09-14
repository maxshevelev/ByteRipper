import XCTest
import Foundation
@testable import MEFirmware

/// A module check's issue names the module it is about, so a panel can put it
/// on that module's row; an issue about the image names none.
final class ModuleIssueTests: XCTestCase {
    /// An LZMA module whose `.met` says it runs past the region: the check
    /// cannot verify it, and says which module.
    func testAnLZMACheckNamesItsModule() {
        let attributes = ModuleAttributesExtension(
            compression: 2, encryption: 0, uncompressedSize: 0x2000,
            compressedSize: 0x1000, deviceID: 0, vendorID: 0x8086, moduleHash: "")
        let partition = CodePartition(
            name: "FTPR", offset: 0, headerVersion: 2, headerLength: 0x14, entryCount: 2,
            checksumValid: true,
            modules: [
                CPDModule(id: 0, name: "kernel", offset: 0x100, isHuffman: false, size: 0x2000),
                CPDModule(id: 1, name: "kernel.met", offset: 0x80, isHuffman: false, size: 0x60,
                          extensions: [CPDExtension(id: 0, tag: 0x0A, size: 0x60, offset: 0x80,
                                                    moduleAttributes: attributes)])
            ])

        let issues = MEFirmwareAnalyzer.lzmaValidationIssues(
            for: partition, in: Data(count: 0x800), baseOffset: 0)

        XCTAssertEqual(issues.map(\.id), [19])
        XCTAssertEqual(issues.first?.module, "kernel")
    }

    /// A payload from before the field decodes with no module.
    func testAnIssueFromBeforeTheFieldHasNoModule() throws {
        let json = Data(#"{"id": 3, "severity": "note", "message": "Not in the database."}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Issue.self, from: json).module)
    }
}
