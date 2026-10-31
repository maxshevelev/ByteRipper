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

    // MARK: - Orders

    /// A module of four functions: `entry` calls two, one of them calls the
    /// other again, and one is called by nothing the artifact shows.
    private func calledState() throws -> CodeReaderState {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,
         "functions":[
          {"entry":"0x220","name":"FUN_00000220","callers":["0x230"],
           "callees":["0x240"],"instructions":[
            {"address":"0x220","bytes":"C3","text":"RET"}]},
          {"entry":"0x230","name":"entry","callers":[],"callees":["0x220","0x240"],
           "instructions":[{"address":"0x230","bytes":"C3","text":"RET"}]},
          {"entry":"0x240","name":"FUN_00000240","callers":["0x220","0x230"],
           "callees":[],"instructions":[
            {"address":"0x240","bytes":"C3","text":"RET"}]},
          {"entry":"0x250","name":"FUN_00000250","callers":[],"callees":[],
           "instructions":[{"address":"0x250","bytes":"C3","text":"RET"}]}]}
        """.utf8))
        return CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
    }

    /// The review-state order puts a function under the level the artifact
    /// records; an artifact from before v7 records none, so every function
    /// sits under "not recorded".
    func testTheReviewOrderGroupsTheFunctionsByTheirReviewLevel() throws {
        var state = try state()
        XCTAssertTrue(state.show(.review))
        XCTAssertEqual(state.functionRows, [
            .group(.unknown), .function(1, level: 1), .function(0, level: 1),
            .function(2, level: 1)
        ], "entry reads before FUN_00000220 and FUN_00000240")
        XCTAssertEqual(state.rowCount, 4)
        XCTAssertNil(state.function(atRow: 0), "a heading is not a function")
        XCTAssertEqual(state.function(atRow: 1), 1)
        XCTAssertEqual(state.row(ofFunction: 2), 3)
        XCTAssertEqual(state.listedFunctions, [1, 0, 2], "the functions read alphabetically in the group")
        XCTAssertFalse(state.show(.review), "the same order twice changes nothing")
        XCTAssertEqual(state.groupCount(at: 0), 3, "the heading holds every function under it")
        XCTAssertNil(state.groupCount(at: 1), "a function row is not a heading")

        state.search("entry")
        XCTAssertEqual(state.functionRows, [.group(.unknown), .function(1, level: 1)],
                       "only the group with a match stays")
        XCTAssertEqual(state.groupCount(at: 0), 1, "the count follows the search")
    }

    /// A review group is a node: closing it keeps its own row and hides its
    /// functions, the heading still says how many it holds, and revealing a
    /// hidden function opens the group.
    func testTheReviewGroupsOpenAndClose() throws {
        var state = try state()
        state.show(.review)
        XCTAssertEqual(state.functionRows.count, 4)
        XCTAssertTrue(state.isGroupExpanded(.unknown))

        state.toggleGroupExpanded(.unknown)
        XCTAssertFalse(state.isGroupExpanded(.unknown))
        XCTAssertEqual(state.functionRows, [.group(.unknown)])
        XCTAssertEqual(state.groupCount(at: 0), 3, "a closed group still says how many it holds")

        XCTAssertTrue(state.reveal(function: 2), "revealing a hidden function opens its group")
        XCTAssertTrue(state.isGroupExpanded(.unknown))
        XCTAssertEqual(state.row(ofFunction: 2), 3)
    }

    /// The groups read in review order — full, partial, decompiled, library,
    /// no body, not recorded — and each group's functions read alphabetically.
    func testTheReviewOrderReadsTheReviewLevel() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":7,
         "functions":[
          {"entry":"0x100","name":"FullOne","review_level":"full","instructions":[]},
          {"entry":"0x150","name":"AlphaFull","review_level":"full","instructions":[]},
          {"entry":"0x200","name":"PartialOne","review_level":"partial",
           "review_gaps":["plate"],"instructions":[]},
          {"entry":"0x300","name":"DecompiledOne","review_level":"decompiled",
           "review_gaps":["name","plate","comments","params","locals"],"instructions":[]},
          {"entry":"0x400","name":"CopyMem","review_level":"library","instructions":[]},
          {"entry":"0x500","name":"ExternalRoutine","review_level":"no_body","instructions":[]},
          {"entry":"0x600","name":"NotRecorded","instructions":[]}]}
        """.utf8))
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        state.show(.review)
        XCTAssertEqual(state.functionRows, [
            .group(.full), .function(1, level: 1), .function(0, level: 1),
            .group(.partial), .function(2, level: 1),
            .group(.decompiled), .function(3, level: 1),
            .group(.library), .function(4, level: 1),
            .group(.noBody), .function(5, level: 1),
            .group(.unknown), .function(6, level: 1)
        ])
        XCTAssertEqual(state.groupCount(at: 0), 2)
        XCTAssertEqual(state.groupCount(at: 3), 1)
        XCTAssertEqual(state.groupCount(at: 11), 1)
    }

    /// The call tree starts at what nothing calls, and every function a call
    /// reaches hangs under that call — a module whose first function is a
    /// helper the entry calls is not a flat list.
    func testTheTreeHangsEveryCalledFunctionUnderItsCaller() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,
         "functions":[
          {"entry":"0x100","name":"CopyMem","callers":["0x180"],"callees":[],
           "instructions":[{"address":"0x100","bytes":"C3","text":"RET"}]},
          {"entry":"0x180","name":"SocFp6CznPeiEntry","callers":[],
           "callees":["0x100","0x1C0"],"instructions":[
            {"address":"0x180","bytes":"C3","text":"RET"}]},
          {"entry":"0x1C0","name":"ApplyTable","callers":["0x180"],"callees":[],
           "instructions":[{"address":"0x1C0","bytes":"C3","text":"RET"}]},
          {"entry":"0x200","name":"OnNotify","callers":[],"callees":["0x1C0"],
           "instructions":[{"address":"0x200","bytes":"C3","text":"RET"}]}]}
        """.utf8))
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        state.show(.calls)
        XCTAssertEqual(state.functionRows, [
            .function(3, level: 0),
            .function(2, level: 1),
            .function(1, level: 0),
            .function(0, level: 1)
        ], "the first function is a caller's, not a root; each set of trees reads alphabetically")
        XCTAssertEqual(state.listedFunctions, [3, 2, 1, 0])
    }

    /// The module's entry is the one the headers name, even when a review
    /// renamed it and something else calls it: the tree starts there.
    func testTheCallTreeStartsAtTheEntryTheHeadersName() throws {
        var module = Data(repeating: 0, count: 0x400)
        module[0] = 0x4D
        module[1] = 0x5A
        func u16(_ at: Int, _ value: UInt16) {
            module[at] = UInt8(value & 0xFF)
            module[at + 1] = UInt8(value >> 8)
        }
        func u32(_ at: Int, _ value: UInt32) {
            for index in 0..<4 { module[at + index] = UInt8((value >> (8 * index)) & 0xFF) }
        }
        u32(0x3C, 0x40)
        module[0x40] = 0x50
        module[0x41] = 0x45
        u16(0x44, 0x14C)
        u16(0x46, 1)
        u16(0x54, 0x60)             // SizeOfOptionalHeader
        u16(0x58, 0x10B)
        u32(0x58 + 16, 0x1200)              // AddressOfEntryPoint
        u32(0x58 + 28, 0x400000)            // ImageBase
        u32(0x58 + 32, 0x1000)              // SectionAlignment
        u32(0x58 + 36, 0x200)               // FileAlignment
        u32(0x58 + 60, 0x200)               // SizeOfHeaders
        let section = 0x58 + 0x60
        for (index, byte) in Array(".text".utf8).enumerated() { module[section + index] = byte }
        u32(section + 8, 0x200)             // VirtualSize
        u32(section + 12, 0x1000)           // VirtualAddress
        u32(section + 16, 0x200)            // SizeOfRawData
        u32(section + 20, 0x200)            // PointerToRawData
        u32(section + 36, 0x6000_0020)

        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,"program":{"image_base":"0x400000"},
         "functions":[
          {"entry":"0x401000","name":"Helper","callers":["0x401200"],"callees":[],
           "instructions":[{"address":"0x401000","bytes":"C3","text":"RET"}]},
          {"entry":"0x401200","name":"AmdModuleEntry","callers":["0x401300"],
           "callees":["0x401000"],"instructions":[
            {"address":"0x401200","bytes":"C3","text":"RET"}]},
          {"entry":"0x401300","name":"Dispatcher","callers":[],"callees":["0x401200"],
           "instructions":[{"address":"0x401300","bytes":"C3","text":"RET"}]}]}
        """.utf8))
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: module))
        state.show(.calls)
        XCTAssertEqual(state.functionRows, [
            .function(1, level: 0),
            .function(0, level: 1),
            .function(2, level: 0)
        ], "the header's entry point leads, and the caller that reaches it follows")
    }

    /// The groups and the calls inside them read alphabetically, whatever
    /// order the artifact keeps.
    func testTheGroupsAndTheirCallsReadAlphabetically() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,
         "functions":[
          {"entry":"0x100","name":"Zebra","review_level":"full",
           "callers":["0x400"],"callees":["0x300","0x200"],"instructions":[]},
          {"entry":"0x200","name":"Alpha","review_level":"full",
           "callers":["0x100"],"callees":[],"instructions":[]},
          {"entry":"0x300","name":"Middle","review_level":"full",
           "callers":["0x100"],"callees":[],"instructions":[]},
          {"entry":"0x400","name":"Zulu","review_level":"full",
           "callers":[],"callees":["0x100"],"instructions":[]}]}
        """.utf8))
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))

        state.show(.review)
        XCTAssertEqual(state.functionRows, [
            .group(.full),
            .function(1, level: 1),
            .function(2, level: 1),
            .function(0, level: 1),
            .function(3, level: 1)
        ], "Alpha, Middle, Zebra, Zulu")

        state.show(.calls)
        XCTAssertEqual(state.functionRows, [
            .function(3, level: 0),
            .function(0, level: 1),
            .function(1, level: 2),
            .function(2, level: 2)
        ], "the trees read Zulu before Zebra — no entry is named — and the calls beneath Zebra read Alpha before Middle")
    }

    /// A tree's rows fold: a closed row keeps its own place and hides what it
    /// calls; opening it brings them back, and revealing a hidden function
    /// opens the calls above it.
    func testTheTreeFoldsItsCalls() throws {
        var state = try calledState()
        state.show(.calls)
        XCTAssertEqual(state.functionRows.count, 4)
        XCTAssertTrue(state.hasCalls(1))
        XCTAssertTrue(state.isExpanded(1))

        state.toggleExpanded(1)
        XCTAssertFalse(state.isExpanded(1))
        XCTAssertEqual(state.functionRows, [.function(1, level: 0), .function(3, level: 0)],
                       "a closed row keeps its place; what it calls is hidden")

        XCTAssertTrue(state.reveal(function: 2), "revealing a hidden function opens its calls")
        XCTAssertTrue(state.isExpanded(1))
        XCTAssertNotNil(state.row(ofFunction: 2))

        state.toggleExpanded(1)
        state.toggleExpanded(1)
        XCTAssertTrue(state.isExpanded(1))
        XCTAssertFalse(state.hasCalls(3), "a function with no calls has nothing to fold")
        state.toggleExpanded(3)
        XCTAssertTrue(state.isExpanded(3))
    }

    /// The call tree starts at the entry, shows each function once, and puts
    /// what the tree does not reach under a heading of its own.
    func testTheCallTreeWalksTheCallsFromTheEntry() throws {
        var state = try calledState()
        XCTAssertTrue(state.show(.calls))
        XCTAssertEqual(state.functionRows, [
            .function(1, level: 0),
            .function(0, level: 1),
            .function(2, level: 2),
            .function(3, level: 0)
        ], "the second call to FUN_00000240 does not make a second row; a function nothing calls starts its own tree")
        XCTAssertEqual(state.listedFunctions, [1, 0, 2, 3])
        XCTAssertEqual(state.row(ofFunction: 2), 2)
    }

    /// A search in the call tree shows what it matches, flat: a match whose
    /// callers do not match would otherwise sit under a heading that is not
    /// there.
    func testASearchIsOneAlphabeticalList() throws {
        var state = try calledState()
        state.show(.calls)
        state.search("FUN_00000250")
        XCTAssertEqual(state.functionRows, [.function(3, level: 0)])
        state.search("FUN_00000240")
        XCTAssertEqual(state.functionRows, [.function(2, level: 0)])
        state.search("")
        XCTAssertEqual(state.functionRows.first, .function(1, level: 0))
    }

    /// A search's matches read alphabetically, not in the order the trees
    /// happen to walk them, and every row is flat.
    func testSearchResultsReadAlphabetically() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,
         "functions":[
          {"entry":"0x100","name":"Zebra","callers":["0x400"],"callees":["0x300","0x200"],
           "instructions":[]},
          {"entry":"0x200","name":"Alpha","callers":["0x100"],"callees":[],"instructions":[]},
          {"entry":"0x300","name":"Middle","callers":["0x100"],"callees":[],"instructions":[]},
          {"entry":"0x400","name":"Zulu","callers":[],"callees":["0x100"],"instructions":[]}]}
        """.utf8))
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        state.show(.calls)
        // "0x" is in every function's entry address, so every function matches.
        state.search("0x")
        XCTAssertEqual(state.functionRows, [
            .function(1, level: 0),
            .function(2, level: 0),
            .function(0, level: 0),
            .function(3, level: 0)
        ], "Alpha, Middle, Zebra, Zulu — the tree's own order was Zulu, Zebra, Alpha, Middle")
    }
}
