import IntelCPUID
import XCTest
@testable import FITTool

/// The processor tables are the IntelCPUID package's, read at run time; what
/// this module adds is what the panel says of a CPUID with them.
final class ProcessorTablesTests: XCTestCase {
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private let names: [String: Any] = ["formatVersion": 1, "entries": [[
        "cpuids": ["806EA"], "codeNames": ["Kaby Lake Refresh U"], "cores": [], "productFamilies": [], "steppings": ["Y0"],
        "segments": ["Mobile"], "processors": [["name": "Intel Core i5-8250U", "sSpec": ["SR3LA"]]]]]]
    private let signatures: [String: Any] = ["formatVersion": 1, "updates": [[
        "revision": "3E", "date": "2025-10-12",
        "signatures": [["cpuid": "90672", "platforms": "07"], ["cpuid": "B06F2", "platforms": "07"]],
        "files": ["Intel/cpuB06F2_plat07_ver0000003E_2025-10-12_PRD_5582AF20.bin"]]]]

    /// Nothing installed is nothing known: the app has no table of its own.
    func testTheTablesAreWhatWasInstalled() throws {
        ProcessorTables.install(.empty)
        XCTAssertTrue(ProcessorNames.current.isEmpty)
        XCTAssertTrue(FITProcessorGroup.groups(for: [0x806EA], language: .english).first?.codeNames.isEmpty ?? false)
        ProcessorTables.install(try ProcessorTables.decode(brandNames: json(names), signatures: json(signatures)))
        XCTAssertEqual(ProcessorNames.current.first?.codeNames, ["Kaby Lake Refresh U"])
        XCTAssertEqual(MicrocodeSignatures.current.sharing(UInt32(0x90672)), ["B06F2"])
        TestTables.install()
    }
}
