import XCTest
@testable import FITTool

/// The processor tables are read from `github.com/maxshevelev/IntelCPUID` at
/// run time; what this target decides is what a pair of files is worth.
final class ProcessorTablesTests: XCTestCase {
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private let names: [String: Any] = ["formatVersion": 1, "entries": [[
        "cpuids": ["806EA"], "codeNames": ["Kaby Lake Refresh U"], "cores": [], "productFamilies": [], "steppings": ["Y0"],
        "segments": ["Mobile"], "processors": [["name": "Intel Core i5-8250U", "sSpec": ["SR3LA"]]]]]]
    private let signatures: [String: Any] = ["formatVersion": 1, "updates": [[
        "revision": "3E", "date": "2025-10-12",
        "signatures": [["cpuid": "90672", "platforms": "07"], ["cpuid": "B06F2", "platforms": "07"]],
        "files": ["Intel/cpuB06F2_plat07_ver0000003E_2025-10-12_PRD_5582AF20.bin"]]]]

    /// A pair of the format this build reads is read whole.
    func testAPairOfTheKnownFormatIsRead() throws {
        let tables = try ProcessorTables.decode(brandNames: json(names), signatures: json(signatures))
        XCTAssertEqual(tables.families.first?.processors.first?.sSpec, ["SR3LA"])
        XCTAssertEqual(tables.microcode.sharing(0x90672), ["B06F2"])
    }

    /// A file of a newer format is refused — the tables in hand are kept —
    /// and so is a file that says no format at all.
    func testANewerFormatIsRefused() {
        var newer = names
        newer["formatVersion"] = 2
        XCTAssertThrowsError(try ProcessorTables.decode(brandNames: json(newer), signatures: json(signatures))) {
            XCTAssertEqual($0 as? ProcessorTables.DecodeError,
                           .unsupportedFormat(file: "IntelCPUIDBrandNames.json", version: 2))
        }
        var unversioned = signatures
        unversioned["formatVersion"] = nil
        XCTAssertThrowsError(try ProcessorTables.decode(brandNames: json(names), signatures: json(unversioned)))
    }

    /// A file that is not the JSON this build reads is refused by name.
    func testAMalformedFileIsRefused() {
        XCTAssertThrowsError(try ProcessorTables.decode(brandNames: Data("<html>".utf8), signatures: json(signatures))) {
            XCTAssertEqual($0 as? ProcessorTables.DecodeError, .malformed(file: "IntelCPUIDBrandNames.json"))
        }
    }

    /// Nothing installed is nothing known: the app has no table of its own.
    func testTheTablesAreWhatWasInstalled() throws {
        ProcessorTables.install(.empty)
        XCTAssertTrue(ProcessorNames.current.isEmpty)
        XCTAssertTrue(FITProcessorGroup.groups(for: [0x806EA], language: .english).first?.codeNames.isEmpty ?? false)
        ProcessorTables.install(try ProcessorTables.decode(brandNames: json(names), signatures: json(signatures)))
        XCTAssertEqual(ProcessorNames.current.first?.codeNames, ["Kaby Lake Refresh U"])
        TestTables.install()
    }
}
