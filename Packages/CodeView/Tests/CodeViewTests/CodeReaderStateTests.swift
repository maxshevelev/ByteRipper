import CodeAnalysis
import XCTest
@testable import CodeView

/// The code screen's rules without a window: a search narrows the lists, a
/// function the search hides is brought back before it is selected, and an
/// instruction selects the function that holds it.
final class CodeReaderStateTests: XCTestCase {
    private func state() throws -> CodeReaderState {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":3,
         "strings":[{"address":"0x300","value":"BootOrder","type":"unicode"},
                    {"address":"0x320","value":"Setup","type":"unicode"}],
         "functions":[
          {"entry":"0x220","name":"FUN_00000220","instructions":[
            {"address":"0x220","bytes":"56","text":"PUSH ESI"},
            {"address":"0x221","bytes":"C3","text":"RET"}]},
          {"entry":"0x230","name":"entry","instructions":[
            {"address":"0x230","bytes":"90","text":"NOP"}]},
          {"entry":"0x240","name":"FUN_00000240","instructions":[
            {"address":"0x240","bytes":"C3","text":"RET"}]}]}
        """.utf8))
        return CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
    }

    func testItOpensOnTheFirstFunctionAndItsFirstInstruction() throws {
        let state = try state()
        XCTAssertEqual(state.function, 0)
        XCTAssertEqual(state.line, 0)
        XCTAssertEqual(state.selectedRow, 0)
        XCTAssertEqual(state.listedFunctions, [0, 1, 2])
    }

    func testSearchNarrowsEveryList() throws {
        var state = try state()
        state.search("  ret ")
        XCTAssertEqual(state.listedFunctions, [0, 2])
        XCTAssertEqual(state.row(ofFunction: 2), 1)
        XCTAssertNil(state.row(ofFunction: 1))
        state.search("boot")
        XCTAssertEqual(state.listedStrings, [0])
        state.show(.strings)
        XCTAssertEqual(state.rowCount, 1)
    }

    func testRevealingAHiddenFunctionClearsTheSearch() throws {
        var state = try state()
        state.show(.strings)
        state.search("ret")
        XCTAssertTrue(state.reveal(function: 0), "the list switched to Functions")
        XCTAssertEqual(state.list, .functions)
        XCTAssertEqual(state.searchText, "ret", "the function was listed; the search stays")
        XCTAssertTrue(state.reveal(function: 1))
        XCTAssertEqual(state.searchText, "", "entry has no RET; the search goes")
        XCTAssertFalse(state.reveal(function: 1), "nothing left to change")
    }

    func testAnInstructionSelectsItsFunction() throws {
        var state = try state()
        state.selectLine(3)
        XCTAssertEqual(state.function, 2)
        XCTAssertEqual(state.selectedRow, 0)
        state.selectLine(1)
        XCTAssertEqual(state.function, 0)
        XCTAssertEqual(state.selectedRow, 1)
        XCTAssertEqual(state.lines.map(\.instruction.text), ["PUSH ESI", "RET"])
        state.selectFunction(1)
        XCTAssertEqual(state.line, 2)
    }
}
