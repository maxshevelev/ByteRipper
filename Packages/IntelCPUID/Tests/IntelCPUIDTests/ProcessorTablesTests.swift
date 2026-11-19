import XCTest
@testable import IntelCPUID

/// The processor tables are read from `github.com/maxshevelev/IntelCPUID` at
/// run time; what this package decides is what a pair of files is worth.
final class ProcessorTablesTests: XCTestCase {
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private let names: [String: Any] = ["formatVersion": 1, "source": ["retrieved": "2026-11-14"], "entries": [[
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
        XCTAssertEqual(tables.microcode.sharing("90672"), ["B06F2"])
        XCTAssertEqual(tables.retrieved, "2026-11-14")
        XCTAssertEqual(tables.microcode.update(file: "Intel/cpuB06F2_plat07_ver0000003E_2025-10-12_PRD_5582AF20.bin")?
            .revision, "3E")
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

    /// The notes are keyed by the entry they are of; an entry that does not
    /// read is left out, and notes that do not read at all leave the tables
    /// standing.
    func testNotesAreReadEntryByEntryAndNeverBlockTheTables() throws {
        let notes: [String: Any] = ["entries": [
            ["cpuids": ["806EA"], "codeNames": ["Kaby Lake Refresh U"], "note": "From the notes.",
             "evidence": [["url": "https://example.com/a", "quote": "806EA", "gives": ["cpuids"]],
                          ["url": "https://example.com/b", "quote": "i5-8250U", "gives": ["processors"]]]],
            ["cpuids": "not a list"]
        ]]
        let tables = try ProcessorTables.decode(brandNames: json(names), signatures: json(signatures), notes: json(notes))
        let family = try XCTUnwrap(tables.families.first)
        XCTAssertEqual(tables.notes(on: family)?.note, "From the notes.")
        XCTAssertEqual(tables.notes(on: family)?.sources.map(\.url), ["https://example.com/a"],
                       "a page that only lists models is not a source of the entry")
        XCTAssertEqual(tables.notes.count, 1)

        let unread = try ProcessorTables.decode(brandNames: json(names), signatures: json(signatures),
                                                notes: Data("404: Not Found".utf8))
        XCTAssertTrue(unread.notes.isEmpty)
        XCTAssertFalse(unread.isEmpty)
    }

    /// A CPUID written with an X matches any digit there, and nothing longer.
    func testAPatternMatchesAnyDigitWhereItHasAnX() {
        let family = ProcessorFamily(cpuids: ["606AX"], codeNames: ["Ice Lake Xeon-SP"])
        XCTAssertTrue(family.matches("606A6"))
        XCTAssertFalse(family.matches("606B6"))
        XCTAssertFalse(family.matches("606A66"))
    }
}
