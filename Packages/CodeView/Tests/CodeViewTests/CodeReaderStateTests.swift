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
    /// Opens every place the tree can open, down to the bottom.
    private func sharedState() throws -> CodeReaderState {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,
         "functions":[
          {"entry":"0x100","name":"A","callers":[],"callees":["0x300"],"instructions":[]},
          {"entry":"0x200","name":"B","callers":[],"callees":["0x300"],"instructions":[]},
          {"entry":"0x300","name":"Shared","callers":["0x100","0x200"],"callees":["0x400"],"instructions":[]},
          {"entry":"0x400","name":"Leaf","callers":["0x300"],"callees":[],"instructions":[]}]}
        """.utf8))
        return CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
    }

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
        let artifact = try throughARegistry("""
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
        """)
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        state.show(.review)
        XCTAssertEqual(state.functionRows, [
            .group(.full), .function(1, level: 1), .function(0, level: 1),
            .group(.partial), .function(2, level: 1),
            .group(.decompiled), .function(3, level: 1),
            .group(.library), .section(.unrecorded), .function(4, level: 2),
            .group(.noBody), .function(5, level: 1),
            .group(.unknown), .function(6, level: 1)
        ], "an entry that says no kind")
        XCTAssertEqual(state.groupCount(at: 0), 2)
        XCTAssertEqual(state.groupCount(at: 3), 1)
        XCTAssertEqual(state.groupCount(at: 12), 1)
    }

    /// Library functions sit under their kinds — EDK2, AMD, Intel, then a
    /// library of no recorded kind — each kind a node of its own that says how
    /// many it holds, opens and closes, and opens again for a hidden function
    /// revealed. A kind with none is not shown.
    func testLibraryFunctionsSitUnderTheirKinds() throws {
        let artifact = try throughARegistry("""
        {"script_version":8,
         "functions":[
          {"entry":"0x100","name":"IoWrite","review_level":"library","library_kind":"amd","instructions":[]},
          {"entry":"0x200","name":"ZeroMem","review_level":"library","library_kind":"edk2","instructions":[]},
          {"entry":"0x300","name":"CopyMem","review_level":"library","library_kind":"edk2","instructions":[]},
          {"entry":"0x400","name":"OldTag","review_level":"library","instructions":[]},
          {"entry":"0x500","name":"Mine","review_level":"full","instructions":[]}]}
        """)
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        state.show(.review)
        XCTAssertEqual(state.functionRows, [
            .group(.full), .function(4, level: 1),
            .group(.library),
            .section(.edk2), .function(2, level: 2), .function(1, level: 2),
            .section(.amd), .function(0, level: 2),
            .section(.unrecorded), .function(3, level: 2)
        ], "no Intel heading without an Intel function")
        XCTAssertEqual(state.groupCount(at: 2), 4, "the group holds every kind")
        XCTAssertEqual(state.groupCount(at: 3), 2)
        XCTAssertEqual(state.librarySection(of: 0), .amd)
        XCTAssertNil(state.librarySection(of: 4))

        state.toggleSectionExpanded(.edk2)
        XCTAssertFalse(state.isSectionExpanded(.edk2))
        XCTAssertEqual(state.functionRows[3...4], [.section(.edk2), .section(.amd)])
        XCTAssertEqual(state.groupCount(at: 3), 2, "a closed kind still says how many it holds")
        XCTAssertTrue(state.reveal(function: 1))
        XCTAssertTrue(state.isSectionExpanded(.edk2), "revealing a hidden function opens its kind")
    }

    /// The call tree holds the ways down to the selected function and what it
    /// calls, and no other function: each way starts at what nothing calls.
    func testTheTreeHoldsTheWaysDownToTheSelectedFunction() throws {
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
        XCTAssertEqual(state.functionRows, [.function(1, level: 0), .function(0, level: 1)],
                       "the first function is the caller's helper; OnNotify leads nowhere near it")
        state.selectFunction(2)
        XCTAssertEqual(state.functionRows, [
            .function(3, level: 0),
            .function(2, level: 1),
            .function(1, level: 0),
            .function(2, level: 1)
        ], "both callers of ApplyTable, each set of ways reading alphabetically")
        XCTAssertEqual(state.listedFunctions, [3, 2, 1, 2])
        state.selectFunction(1)
        XCTAssertEqual(state.functionRows, [
            .function(1, level: 0),
            .function(2, level: 1),
            .function(0, level: 1)
        ], "a root with what it calls")
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
            .function(2, level: 0),
            .function(1, level: 1),
            .function(0, level: 2)
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

    /// Every place on the way down starts open and can be folded; a new
    /// selection opens every way down to it again.
    func testTheTreeFoldsAndASelectionOpensItAgain() throws {
        var state = try calledState()
        state.show(.calls)
        XCTAssertEqual(state.functionRows, [
            .function(1, level: 0), .function(0, level: 1), .function(2, level: 2)
        ], "open without being asked; FUN_00000250 is on no way and is not listed")
        XCTAssertTrue(state.isExpanded(path: [1]))
        XCTAssertTrue(state.isExpanded(path: [1, 0]))

        state.toggleExpanded(path: [1, 0])
        XCTAssertEqual(state.functionRows, [.function(1, level: 0), .function(0, level: 1)])
        state.toggleExpanded(path: [1])
        XCTAssertEqual(state.functionRows, [.function(1, level: 0)])

        state.selectFunction(2)
        XCTAssertEqual(state.functionRows, [
            .function(1, level: 0), .function(0, level: 1), .function(2, level: 2), .function(2, level: 1)
        ], "every way to FUN_00000240 is open")
        XCTAssertFalse(state.hasCalls(path: [1, 2]), "a function with no calls has nothing to fold")
        state.toggleExpanded(path: [1, 2])
        XCTAssertFalse(state.isExpanded(path: [1, 2]))

        XCTAssertFalse(state.reveal(function: 3), "a selection lays the tree out; the reveal opens nothing")
        state.selectFunction(3)
        XCTAssertEqual(state.functionRows, [.function(3, level: 0)])
    }

    /// The selected function's calls open under the place it was chosen at; its
    /// other places keep theirs behind the arrow, and each opens by itself.
    func testTheCallsOpenUnderTheChosenPlace() throws {
        var state = try sharedState()
        state.selectFunction(2)
        state.show(.calls)
        XCTAssertEqual(state.functionRows, [
            .function(0, level: 0), .function(2, level: 1), .function(3, level: 2),
            .function(1, level: 0), .function(2, level: 1)
        ], "Shared is open under A, the first place, and closed under B")
        XCTAssertEqual(state.row(ofFunction: 2), 1)
        XCTAssertFalse(state.isExpanded(path: [1, 2]))
        XCTAssertTrue(state.hasCalls(path: [1, 2]))

        state.toggleExpanded(path: [1, 2])
        XCTAssertEqual(state.rowCount, 6)
        state.toggleExpanded(path: [1, 2])

        state.chooseCallPlace(atRow: 4)
        XCTAssertEqual(state.functionRows, [
            .function(0, level: 0), .function(2, level: 1),
            .function(1, level: 0), .function(2, level: 1), .function(3, level: 2)
        ], "the place clicked has the calls now")
        XCTAssertEqual(state.row(ofFunction: 2), 3, "and the selection")
    }

    /// The selected function answers for all its places in the tree, a recursive
    /// call among them; a search and the other layouts have one row for it.
    func testEveryPlaceOfTheSelectedFunctionIsItsRow() throws {
        var state = try sharedState()
        state.selectFunction(2)
        XCTAssertEqual(Array(state.selectedFunctionRows), [state.row(ofFunction: 2)].compactMap { $0 })
        state.show(.calls)
        XCTAssertEqual(Array(state.selectedFunctionRows), [1, 4])
        state.search("Shared")
        XCTAssertEqual(Array(state.selectedFunctionRows), [0])
        state.search("")
        state.toggleExpanded(path: [0])
        XCTAssertEqual(Array(state.selectedFunctionRows), [2], "a folded place is not on screen")

        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,
         "functions":[
          {"entry":"0x100","name":"A","callers":["0x200"],"callees":["0x200"],"instructions":[]},
          {"entry":"0x200","name":"B","callers":["0x100"],"callees":["0x100"],"instructions":[]}]}
        """.utf8))
        var circle = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        circle.show(.calls)
        XCTAssertEqual(Array(circle.selectedFunctionRows), [0, 2], "the call that closes the circle too")
    }

    /// Another place of the selected function takes the calls over: they close
    /// at the place before, even one opened by hand, and nothing else moves.
    func testAnotherPlaceTakesTheCallsAndLeavesTheRestAsItWas() throws {
        var state = try sharedState()
        state.selectFunction(2)
        state.show(.calls)
        state.toggleExpanded(path: [1, 2])
        XCTAssertTrue(state.isExpanded(path: [1, 2]), "open by hand under B, and open under A by itself")
        XCTAssertTrue(state.isExpanded(path: [0, 2]))
        state.toggleExpanded(path: [1, 2])

        state.toggleExpanded(path: [0, 2])
        XCTAssertFalse(state.isExpanded(path: [0, 2]), "folded where its calls were")
        state.chooseCallPlace(atRow: state.row(ofCallPath: [1, 2]) ?? -1)
        XCTAssertTrue(state.isExpanded(path: [1, 2]))
        XCTAssertFalse(state.isExpanded(path: [0, 2]))
        state.chooseCallPlace(atRow: state.row(ofCallPath: [0, 2]) ?? -1)
        XCTAssertTrue(state.isExpanded(path: [0, 2]), "a place chosen opens, whatever was folded there")
        XCTAssertFalse(state.isExpanded(path: [1, 2]))
    }

    /// Keeping to the open way leaves the function's other ways out and its calls
    /// in; a new selection keeps to its own way, and the form can be left again.
    func testTheTreeCanKeepToTheOpenWay() throws {
        var state = try sharedState()
        state.selectFunction(2)
        state.show(.calls)
        state.chooseCallPlace(atRow: 4)
        state.showOnlyOpenWay(true)
        XCTAssertEqual(state.functionRows, [
            .function(1, level: 0), .function(2, level: 1), .function(3, level: 2)
        ], "B, the Shared chosen under it, and Leaf")
        XCTAssertEqual(Array(state.selectedFunctionRows), [1])
        state.selectFunction(3)
        XCTAssertEqual(state.functionRows, [
            .function(0, level: 0), .function(2, level: 1), .function(3, level: 2)
        ], "the first way to a function arrived at from elsewhere")
        state.selectFunction(2)
        state.showOnlyOpenWay(false)
        XCTAssertEqual(state.rowCount, 5)
    }

    /// The way that reads bold is the one down to the place the calls are open
    /// at, that place too, and it moves with them.
    func testTheWayDownFollowsTheOpenPlace() throws {
        var state = try sharedState()
        state.selectFunction(2)
        state.show(.calls)
        func marked() -> [Int] { (0..<state.rowCount).filter { state.isOnChosenWay(atRow: $0) } }
        XCTAssertEqual(marked(), [0, 1], "A and Shared under it; Leaf, B and the other Shared are not on it")
        state.chooseCallPlace(atRow: 4)
        XCTAssertEqual(marked(), [2, 3], "B and Shared under it now")
        state.selectFunction(3)
        XCTAssertEqual(marked(), [0, 1, 2], "down to Leaf through A")
        state.search("Leaf")
        XCTAssertEqual(marked(), [], "a search's list has no way down")
    }

    /// The call that closes a circle is a row of the function, not a place to
    /// read it from: choosing it moves nothing.
    func testChoosingTheCallThatClosesACircleMovesNothing() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,
         "functions":[
          {"entry":"0x100","name":"A","callers":["0x200"],"callees":["0x200"],"instructions":[]},
          {"entry":"0x200","name":"B","callers":["0x100"],"callees":["0x100"],"instructions":[]}]}
        """.utf8))
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        state.show(.calls)
        let rows = state.functionRows
        state.chooseCallPlace(atRow: 2)
        XCTAssertEqual(state.functionRows, rows)
        XCTAssertEqual(state.row(ofFunction: 0), 0)
    }

    /// A row clicked in the tree stays the place the next tree is about.
    func testAFunctionChosenInTheTreeKeepsItsPlace() throws {
        var state = try sharedState()
        state.selectFunction(2)
        state.show(.calls)
        state.chooseCallPlace(atRow: 2)
        state.selectFunction(3)
        XCTAssertEqual(state.functionRows, [
            .function(0, level: 0), .function(2, level: 1), .function(3, level: 2),
            .function(1, level: 0), .function(2, level: 1), .function(3, level: 2)
        ], "Leaf by both ways")
        XCTAssertEqual(state.row(ofFunction: 3), 2)
    }

    /// A recursive call shows, and goes no deeper: the tree has a bottom.
    func testARecursiveCallHasNoCallsToOpen() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,
         "functions":[
          {"entry":"0x100","name":"A","callers":["0x200"],"callees":["0x200"],"instructions":[]},
          {"entry":"0x200","name":"B","callers":["0x100"],"callees":["0x100"],"instructions":[]}]}
        """.utf8))
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        state.show(.calls)
        XCTAssertEqual(state.functionRows, [
            .function(0, level: 0), .function(1, level: 1), .function(0, level: 2)
        ], "a circle starts at its first and ends where it closes")
        XCTAssertFalse(state.hasCalls(path: [0, 1, 0]))
        XCTAssertTrue(state.isRecursiveCall(path: [0, 1, 0]))
        XCTAssertFalse(state.isRecursiveCall(path: [0, 1]))
        state.selectFunction(1)
        XCTAssertEqual(state.functionRows, [
            .function(0, level: 0), .function(1, level: 1), .function(0, level: 2)
        ])
    }

    /// A way down never passes a function twice, and a walk that a circle sends
    /// back leaves no row behind: every row above the function leads to it.
    func testACircleLeavesNoDeadWayBehind() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,
         "functions":[
          {"entry":"0x100","name":"Focus","callers":["0x300"],"callees":[],"instructions":[]},
          {"entry":"0x200","name":"Root","callers":[],"callees":["0x300","0x400"],"instructions":[]},
          {"entry":"0x300","name":"A","callers":["0x200","0x400"],"callees":["0x100","0x400"],"instructions":[]},
          {"entry":"0x400","name":"B","callers":["0x200","0x300"],"callees":["0x300"],"instructions":[]}]}
        """.utf8))
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        state.show(.calls)
        XCTAssertEqual(state.functionRows, [
            .function(1, level: 0),
            .function(2, level: 1), .function(0, level: 2),
            .function(3, level: 1), .function(2, level: 2), .function(0, level: 3)
        ], "Root → A → B comes back to A and is not listed; Root → B → A arrives")
    }

    /// Thirty levels of two functions each are 2^30 ways down: the list stops
    /// and says so instead of walking them.
    func testTooManyWaysStopTheListAndSaySo() throws {
        var functions = ["{\"entry\":\"0x10\",\"name\":\"Focus\",\"callers\":[],\"callees\":[],\"instructions\":[]}"]
        for level in 1...30 {
            let next = level == 1 ? "\"0x10\"" : "\"0x\(String((level - 1) * 256, radix: 16))\",\"0x\(String((level - 1) * 256 + 1, radix: 16))\""
            for side in 0...1 {
                functions.append("{\"entry\":\"0x\(String(level * 256 + side, radix: 16))\",\"name\":\"L\(level)_\(side)\",\"callers\":[],\"callees\":[\(next)],\"instructions\":[]}")
            }
        }
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data(
            "{\"script_version\":4,\"functions\":[\(functions.joined(separator: ","))]}".utf8))
        var state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        state.show(.calls)
        XCTAssertEqual(state.functionRows.last, .callsCut)
        XCTAssertLessThan(state.rowCount, 2_100)
        XCTAssertNotNil(state.row(ofFunction: 0), "the function itself is reached")
    }

    /// The places opened by hand go across a revision by their entries, since a
    /// function's index does not last; one with a function gone is let go.
    func testOpenPlacesCrossARevision() throws {
        var state = try sharedState()
        state.selectFunction(2)
        state.show(.calls)
        state.toggleExpanded(path: [1, 2])
        let carried = state.openCallEntries

        var next = try sharedState()
        next.selectFunction(2)
        next.show(.calls)
        next.openCallPlaces(carried + [[CodeAddress(0x999)]])
        XCTAssertEqual(next.functionRows, state.functionRows)
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
