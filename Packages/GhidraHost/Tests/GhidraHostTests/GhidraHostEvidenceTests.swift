import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A publish warns of an EDK2 function whose plate does not cite the pinned
/// tag truly, and of nothing else; with no sources configured it checks nothing.
final class GhidraHostEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostEvidence-\(UUID().uuidString)", isDirectory: true)
        let library = directory.appendingPathComponent("checkout/MdePkg/Library/BaseLib", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("""
            UINTN
            EFIAPI
            AsciiStrLen (
              IN CONST CHAR8  *String
              )
            {
              return 0;
            }
            """.utf8).write(to: library.appendingPathComponent("String.c"))
        try Data("MdePkg/Library/BaseLib/String.c\n".utf8)
            .write(to: directory.appendingPathComponent("checkout/\(EDK2Evidence.listingName)"))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func proposal(_ name: String, kind: String = "edk2", plate: String) throws -> LibraryProposal {
        let entry = try JSONSerialization.data(withJSONObject: ["name": name, "plate": plate], options: [.sortedKeys])
        return LibraryProposal(body: LibraryBody(size: 8, full: "00", specific: "01"), name: name, kind: kind,
                               address: "0x1000", entry: entry)
    }

    func testOnlyAnEDK2FunctionWhoseCitationFailsIsWarnedOf() throws {
        let checkout = directory.appendingPathComponent("checkout")
        let warnings = GhidraHost.evidenceWarnings([
            try proposal("AsciiStrLen", plate: "Length.\n\nEvidence: AsciiStrLen, MdePkg/Library/BaseLib/String.c:3."),
            try proposal("AsciiStrLenWrong", plate: "Evidence: AsciiStrLen, MdePkg/Library/BaseLib/String.c:641."),
            try proposal("LibAmdIoWrite", kind: "amd", plate: "No EDK2 here.")
        ], checkout: checkout)
        XCTAssertEqual(warnings.map(\.name), ["AsciiStrLenWrong"])
        XCTAssertEqual(warnings.first?.findings.first?.outcome, .notDefinition)
        XCTAssertEqual(warnings.first?.findings.first?.definedAt, 3)
    }

    func testNoSourcesConfiguredChecksNothing() async throws {
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   holder: "GhidraHostEvidenceTests", edk2Sources: nil),
                              writer: try ContentStore(root: directory.appendingPathComponent("store")))
        let result = await host.evidenceCheck([try proposal("AsciiStrLen", plate: "no evidence")])
        XCTAssertEqual(result.warnings, [])
        XCTAssertNil(result.unchecked)
    }

    func testTheConfiguredCheckoutIsRead() async throws {
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   holder: "GhidraHostEvidenceTests",
                                                   edk2Sources: directory.appendingPathComponent("checkout")),
                              writer: try ContentStore(root: directory.appendingPathComponent("store")))
        let result = await host.evidenceCheck([try proposal("AsciiStrLen", plate: "no evidence")])
        XCTAssertEqual(result.warnings.first?.findings.map(\.outcome), [.noEvidence])
        XCTAssertNil(result.unchecked)
    }
}
