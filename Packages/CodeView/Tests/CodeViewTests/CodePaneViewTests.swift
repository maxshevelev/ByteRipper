import AppKit
import XCTest
import CodeAnalysis
@testable import CodeView

/// The pane the app puts beside a module's bytes: functions, the disassembly,
/// the decompiled C, and the stale banner (`Design/CODE_PANEL_PLAN.md`).
@MainActor
final class CodePaneViewTests: XCTestCase {
    private let moduleBytes = Data([0x56, 0x5A] + [UInt8](repeating: 0, count: 14))

    private func manifest() -> AnalysisManifest {
        AnalysisManifest(
            module: ModuleIdentity(sha256: SHA256Digest(data: moduleBytes),
                                   size: moduleBytes.count, name: "CpuPei", kind: "TE",
                                   language: "x86:LE:32:default", imageBase: "0x0"),
            recipe: AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: AnalysisArtifact(
                sha256: SHA256Digest(data: Data("artifact".utf8)), size: 8,
                mediaType: "application/json"),
            analyzedAt: "2026-10-25T15:00:00+00:00",
            stats: AnalysisStats(functions: 2, instructions: 3))
    }

    private func artifact() throws -> CodeArtifact {
        try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":2,"ghidra":"12.1.2","program":{"image_base":"0x0"},
         "functions":[
          {"entry":"0x220","name":"FUN_00000220","instructions":[
            {"address":"0x220","bytes":"56","mnemonic":"PUSH","text":"PUSH ESI"},
            {"address":"0x221","bytes":"57","mnemonic":"PUSH","text":"PUSH EDI"}]},
          {"entry":"0x355","name":"entry","c":"return 0;","instructions":[
            {"address":"0x355","bytes":"8B 54 24 08","mnemonic":"MOV","text":"MOV EDX,dword ptr [ESP + 0x8]"}]}
         ]}
        """.utf8))
    }

    func testThePaneListsFunctionsAndInstructions() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.functionCount, 2)
        XCTAssertEqual(view.instructionCount, 3)
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x220))
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
        XCTAssertEqual(view.decompiledText, "No decompiled C for this function.")

        view.selectInstruction(at: 2)
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x355))
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertEqual(view.decompiledText, "return 0;")
        XCTAssertFalse(view.hasAmbiguousLayout)
    }

    func testTheFunctionsHeadingSitsAtTheLeftOfItsList() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()

        let heading = try XCTUnwrap(
            first(NSTextField.self, in: view) { $0.stringValue == "Functions" })
        XCTAssertEqual(heading.alignment, .left, "the heading reads from the left")
        let list = try XCTUnwrap(
            first(NSTableView.self, in: view) {
                $0.tableColumns.first?.identifier.rawValue == "function"
            })
        let headingLeft = view.convert(heading.alignmentRect(forFrame: heading.bounds),
                                       from: heading).minX
        let listLeft = view.convert(list.bounds, from: list).minX
        XCTAssertEqual(headingLeft, listLeft, accuracy: 0.5,
                       "and starts where the list does")
    }

    /// A screen that moved container opens where it was left: the function,
    /// the instruction and the ASM/C choice.
    func testARestoredScreenKeepsItsPlace() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()
        view.selectInstruction(at: 2)

        view.restore(function: 1, instruction: 2, showsC: true)
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x355))
        XCTAssertEqual(view.selectedFunctionIndex, 1)
        XCTAssertEqual(view.selectedInstructionIndex, 2)
        XCTAssertTrue(view.showsDecompiledC)
        XCTAssertEqual(view.decompiledText, "return 0;")
    }

    func testTheFunctionsSitLeftOfTheCodeAndTheBytesBelowIt() throws {
        let hex = NSView()
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: hex)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()

        let functions = try XCTUnwrap(
            first(NSTableView.self, in: view) {
                $0.tableColumns.first?.identifier.rawValue == "function"
            })
        let instructions = try XCTUnwrap(
            first(NSTableView.self, in: view) {
                $0.tableColumns.first?.identifier.rawValue == "instruction"
            })
        let functionsRect = view.convert(functions.bounds, from: functions)
        let instructionsRect = view.convert(instructions.bounds, from: instructions)
        let hexRect = view.convert(hex.bounds, from: hex)
        XCTAssertLessThan(functionsRect.maxX, instructionsRect.minX,
                          "the function list is the left pane")
        XCTAssertGreaterThan(instructionsRect.maxY, hexRect.maxY,
                             "the code is above the hex view")
        XCTAssertEqual(hexRect.height, 220, accuracy: 0.5,
                       "the hex view is the reference strip below")
    }

    func testTheStaleBannerIsSaidOutLoud() throws {        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()
        view.setStale(true)
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(labels(in: view).contains("The module changed after this analysis."))
        view.setStale(false)
        XCTAssertFalse(labels(in: view).contains("The module changed after this analysis."))
    }

    /// The instruction and the bytes are two views of one selection: the pane
    /// reports the module range of the chosen instruction, and a selection from
    /// the hex side picks the instruction that holds it.
    func testSelectionCrossesBetweenTheListingAndTheBytes() throws {
        let module = teModule()
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: module, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()

        var ranges: [Range<UInt64>] = []
        var focused: [Range<UInt64>] = []
        view.onSelectRange = { ranges.append($0) }
        view.onFocusRange = { focused.append($0) }
        view.selectInstruction(at: 0)
        XCTAssertEqual(ranges.last, 0x68..<0x69, "the first byte of the address 0x220")
        view.selectInstruction(at: 1)
        XCTAssertEqual(ranges.last, 0x69..<0x6A)

        view.selectModuleRange(0x68..<0x69)
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x220))

        let selected = ranges.last
        view.selectFunction(at: 0)
        XCTAssertEqual(focused.last, 0x68..<0x6A,
                       "a function's whole stored range is the main zone")
        XCTAssertEqual(ranges.last, selected,
                       "and choosing a function does not take the byte selection")
    }

    /// The real CpuPei artifact, when the machine has one: 13 functions, 508
    /// instructions, and the status-code candidate at 0x535. The path is an
    /// environment variable so the suite does not depend on a store that is not
    /// in the repository.
    func testTheRealCpuPeiArtifactWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["BYTERIPPER_CPUPEI_ARTIFACT"] else {
            throw XCTSkip("set BYTERIPPER_CPUPEI_ARTIFACT to a CpuPei code.json")
        }
        let artifact = try JSONDecoder().decode(
            CodeArtifact.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(artifact.functions.count, 13)
        XCTAssertEqual(artifact.functions.reduce(0) { $0 + $1.instructions.count }, 508)
        XCTAssertTrue(artifact.statusCodeCalls.contains { $0.address == CodeAddress(0x535) })

        let view = CodePaneView(manifest: manifest(), artifact: artifact,
                                hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.instructionCount, 508)
    }

    private func first<T: NSView>(_ type: T.Type, in view: NSView,
                                  where matches: (T) -> Bool) -> T? {
        if let view = view as? T, matches(view) { return view }
        for subview in view.subviews {
            if let found = first(type, in: subview, where: matches) { return found }
        }
        return nil
    }

    private func labels(in view: NSView) -> [String] {
        view.subviews.flatMap { subview in
            (subview as? NSTextField).map { [$0.stringValue] } ?? []
        } + view.subviews.flatMap(labels)
    }

    /// A minimal TE image whose .text is at RVA 0x220 and file offset 0x68,
    /// with the two bytes the artifact's first instructions name.
    private func teModule() -> Data {
        var data = Data(repeating: 0, count: 0x100)
        data[0] = 0x56
        data[1] = 0x5A
        write16(&data, 2, 0x14C)
        data[4] = 1
        data[5] = 0x0B
        write16(&data, 6, 0x200)
        write32(&data, 8, 0x220)
        write32(&data, 12, 0x220)
        write64(&data, 16, 0)
        let section = 40
        for (index, byte) in Array(".text".utf8).enumerated() {
            data[section + index] = byte
        }
        write32(&data, section + 8, 0x40)
        write32(&data, section + 12, 0x220)
        write32(&data, section + 16, 0x40)
        write32(&data, section + 20, 0x240)
        write32(&data, section + 36, 0x6000_0020)
        data[0x68] = 0x56
        data[0x69] = 0x57
        return data
    }

    private func write16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        for index in 0..<2 {
            data[offset + index] = UInt8((value >> (8 * UInt16(index))) & 0xFF)
        }
    }

    private func write32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for index in 0..<4 {
            data[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF)
        }
    }

    private func write64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
        for index in 0..<8 {
            data[offset + index] = UInt8((value >> (8 * UInt64(index))) & 0xFF)
        }
    }
}
