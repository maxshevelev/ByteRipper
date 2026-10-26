import ALSplitView
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
         "strings":[{"address":"0x220","type":"string","value":"ABC"}],
         "post_codes":[{"address":"0x221","function":"0x220","port":"0x80","text":"OUT 0x80, AL"}],
         "status_code_calls":[{"address":"0x222","function":"0x220","text":"call [ebx+0x10]","context":["ReportStatusCode"]}],
         "functions":[
          {"entry":"0x220","name":"FUN_00000220","callers":["0x355"],"callees":["0x355"],"instructions":[
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
        XCTAssertEqual(view.listedInstructionCount, 2,
                       "the ASM listing is the selected function, not the whole block")
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x220))
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
        XCTAssertEqual(view.decompiledText, "No decompiled C for this function.")

        view.selectInstruction(at: 2)
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x355))
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertEqual(view.listedInstructionCount, 1,
                       "choosing another function replaces the listing")
        XCTAssertEqual(view.decompiledText, "return 0;")
        XCTAssertFalse(view.hasAmbiguousLayout)
    }

    func testTheHeaderKeepsTheVersionsInOneLine() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()

        let mode = try XCTUnwrap(first(NSSegmentedControl.self, in: view) {
            $0.label(forSegment: 0) == "ASM"
        })
        XCTAssertEqual((0..<mode.segmentCount).map { mode.label(forSegment: $0) ?? "" },
                       ["ASM", "C"])
        let modeRect = view.convert(mode.bounds, from: mode)
        XCTAssertGreaterThan(modeRect.minX, view.bounds.midX,
                             "the switch is on the code side")
        XCTAssertGreaterThan(modeRect.minY, view.bounds.maxY - 80,
                             "and at the top")

        let name = try XCTUnwrap(first(NSTextField.self, in: view) {
            $0.stringValue == "CpuPei"
        })
        let versions = try XCTUnwrap(first(NSTextField.self, in: view) {
            $0.stringValue == "(code-v2 · Ghidra 12.1.2)"
        })
        XCTAssertEqual(versions.textColor, .secondaryLabelColor)
        let nameRect = view.convert(name.bounds, from: name)
        let versionsRect = view.convert(versions.bounds, from: versions)
        XCTAssertEqual(nameRect.midY, versionsRect.midY, accuracy: 1,
                       "the name and the versions share one line")
        XCTAssertLessThan(nameRect.maxX, versionsRect.minX)
    }


    /// The dump bar is the screen's control strip: ASM/C on its left, the
    /// analysis dropdown and the fold button on its right.
    func testTheDumpBarCarriesTheControls() throws {
        var second = manifest()
        second.recipe = AnalysisRecipe(id: "code-v3-ghidra-12.2", exporter: 3,
                                       ghidra: "12.2", script: "ExportCode.java")
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView(),
                                recipes: [manifest(), second])
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()

        let analysis = try XCTUnwrap(first(NSPopUpButton.self, in: view) {
            $0.accessibilityLabel() == "Analysis"
        })
        let fold = try XCTUnwrap(first(NSButton.self, in: view) {
            $0.accessibilityLabel() == "Hide hex dump"
        })
        let analysisRect = view.convert(analysis.bounds, from: analysis)
        let foldRect = view.convert(fold.bounds, from: fold)
        XCTAssertEqual(analysisRect.midY, foldRect.midY, accuracy: 1,
                       "the controls share the bar")
        XCTAssertLessThan(analysisRect.maxX, foldRect.minX, "the dropdown before the fold button")
        XCTAssertGreaterThan(analysisRect.minX, view.bounds.midX,
                             "the dropdown is on the right")
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
        let cell = try XCTUnwrap(list.view(atColumn: 0, row: 0, makeIfNecessary: true)
                                    as? NSTableCellView)
        let field = try XCTUnwrap(cell.textField)
        let headingLeft = view.convert(heading.alignmentRect(forFrame: heading.bounds),
                                       from: heading).minX
        let rowTextLeft = view.convert(field.alignmentRect(forFrame: field.bounds),
                                       from: field).minX
        XCTAssertEqual(headingLeft, rowTextLeft, accuracy: 0.5,
                       "and starts where the row text does")

        let codeTitle = try XCTUnwrap(first(NSTextField.self, in: view) {
            $0.stringValue == "Code analysis"
        })
        let headingY = view.convert(heading.alignmentRect(forFrame: heading.bounds),
                                    from: heading).midY
        let codeTitleY = view.convert(codeTitle.alignmentRect(forFrame: codeTitle.bounds),
                                      from: codeTitle).midY
        XCTAssertEqual(headingY, codeTitleY, accuracy: 0.5,
                       "and reads on the same line as the code title")
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


    /// The navigator's other lists read the same artifact: strings, POST
    /// writes and status candidates, each selectable into the bytes.
    func testTheNavigatorListsStringsPostAndStatus() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()
        var ranges: [Range<UInt64>] = []
        view.onSelectRange = { ranges.append($0) }

        view.selectList(.strings)
        XCTAssertEqual(view.listedStringCount, 1)
        XCTAssertEqual(view.selectedString?.value, "ABC")
        XCTAssertEqual(ranges.last, 0x68..<0x6C, "the value and its terminator")

        view.selectList(.postCodes)
        XCTAssertEqual(view.listedPostCodeCount, 1)
        XCTAssertEqual(view.selectedPostCode?.text, "OUT 0x80, AL")
        XCTAssertEqual(ranges.last, 0x69..<0x6A)

        view.selectList(.statusCodes)
        XCTAssertEqual(view.listedStatusCodeCount, 1)
        XCTAssertEqual(view.selectedStatusCode?.text, "call [ebx+0x10]")
        XCTAssertEqual(ranges.last, 0x6A..<0x6B)

        view.selectList(.functions)
        XCTAssertEqual(view.listedFunctionCount, 2)
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
    }

    /// Search narrows functions by their instructions as well as their names,
    /// and the two reference lists by their text.
    func testSearchNarrowsTheListInFront() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()

        view.filter(by: "MOV")
        XCTAssertEqual(view.listedFunctionCount, 1)
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220",
                       "the selected function stayed; the list narrowed around it")

        view.selectList(.strings)
        view.filter(by: "ABC")
        XCTAssertEqual(view.listedStringCount, 1)
        view.filter(by: "nothing here")
        XCTAssertEqual(view.listedStringCount, 0)
    }

    /// A function's callers and callees are one click from it.
    func testACalleeLeadsToItsFunction() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()

        let popup = try XCTUnwrap(first(NSPopUpButton.self, in: view) { _ in true })
        let item = try XCTUnwrap(popup.menu?.items.first { $0.title == "entry" })
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(view.selectedFunction?.name, "entry")
    }


    /// The listing's first column is the byte's offset in the module — the
    /// same 0x68 the hex view shows — not Ghidra's 0x220 virtual address.
    func testTheListingShowsTheModuleOffset() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()
        let listing = try XCTUnwrap(first(NSTableView.self, in: view) {
            $0.tableColumns.first?.identifier.rawValue == "instruction"
        })
        let cell = try XCTUnwrap(listing.view(atColumn: 0, row: 0, makeIfNecessary: true)
                                    as? CodeLineCell)
        XCTAssertTrue(cell.line.string.hasPrefix("0x68"), "the module offset, as in the hex view")
    }

    /// The callees are in the code, not in a menu: only Callers is offered.
    func testThereIsNoCalleesMenu() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView())
        let titles = all(NSPopUpButton.self, in: view).compactMap { $0.menu?.items.first?.title }
        XCTAssertTrue(titles.contains { $0.hasPrefix("Callers") })
        XCTAssertFalse(titles.contains { $0.hasPrefix("Callees") })
    }

    /// A call in the C is a link: clicking it opens the called function, and
    /// Back returns to the caller.
    func testACallInTheCLeadsToItsFunctionAndBackReturns() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try linkedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        let text = view.decompiledAttributedText
        let call = (text.string as NSString).range(of: "entry")
        XCTAssertNotEqual(call.location, NSNotFound)
        let link = try XCTUnwrap(text.attribute(.link, at: call.location, effectiveRange: nil) as? String)
        let textView = try XCTUnwrap(first(NSTextView.self, in: view) { _ in true })
        XCTAssertTrue(view.textView(textView, clickedOnLink: link, at: call.location))
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertTrue(view.canGoBack)

        view.goBack()
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
        XCTAssertTrue(view.canGoForward)
        view.goForward()
        XCTAssertEqual(view.selectedFunction?.name, "entry")
    }

    /// A call in the listing is a link too.
    func testACallInTheListingLeadsToItsFunction() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try linkedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        let listing = try XCTUnwrap(first(NSTableView.self, in: view) {
            $0.tableColumns.first?.identifier.rawValue == "instruction"
        })
        let cell = try XCTUnwrap(listing.view(atColumn: 0, row: 1, makeIfNecessary: true)
                                    as? CodeLineCell)
        XCTAssertTrue(cell.line.string.hasSuffix("CALL 0x6A"), cell.line.string)
        cell.line.onLink?(.function(1))
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertTrue(view.canGoBack)
    }

    private func linkedArtifact() throws -> CodeArtifact {
        try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":3,"ghidra":"12.1.2","program":{"image_base":"0x0"},
         "functions":[
          {"entry":"0x220","name":"FUN_00000220","c":"void FUN_00000220(void)\\n{\\n  entry();\\n}\\n",
           "instructions":[
            {"address":"0x220","bytes":"56","mnemonic":"PUSH","text":"PUSH ESI"},
            {"address":"0x221","bytes":"E8 00","mnemonic":"CALL","text":"CALL 0x00000222",
             "references":[{"to":"0x222","type":"UNCONDITIONAL_CALL"}]}]},
          {"entry":"0x222","name":"entry","c":"void entry(void)\\n{\\n}\\n","instructions":[
            {"address":"0x222","bytes":"C3","mnemonic":"RET","text":"RET"}]}
         ]}
        """.utf8))
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }


    /// The header lists the module's other readable analyses, and choosing
    /// one asks the app for its artifact.
    func testTheHeaderOffersAnotherAnalysis() throws {
        let first = manifest()
        var second = first
        second.recipe = AnalysisRecipe(id: "code-v3-ghidra-12.2", exporter: 3,
                                       ghidra: "12.2", script: "ExportCode.java")
        let view = CodePaneView(manifest: first, artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView(),
                                recipes: [first, second])
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.offeredRecipes.map(\.recipe.id),
                       ["code-v2-ghidra-12.1.2", "code-v3-ghidra-12.2"])

        var chosen: AnalysisManifest?
        view.onChooseRecipe = { chosen = $0 }
        view.chooseRecipe(at: 1)
        XCTAssertEqual(chosen?.recipe.id, "code-v3-ghidra-12.2")
        view.chooseRecipe(at: 0)
        XCTAssertEqual(chosen?.recipe.id, "code-v3-ghidra-12.2",
                       "the one already open is not chosen again")
    }


    /// The bar above the hex view folds it away and brings it back, leaving
    /// the bar and its button in place.
    func testTheBarFoldsTheHexDumpAway() throws {
        let hex = NSView()
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: hex)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.isHexDumpVisible)
        XCTAssertEqual(hex.frame.height, 220, accuracy: 0.5)
        let hide = try XCTUnwrap(first(NSButton.self, in: view) {
            $0.accessibilityLabel() == "Hide hex dump"
        })
        XCTAssertEqual(hide.state, .on, "open is the selected state")

        view.setHexDumpVisible(false, animated: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isHexDumpVisible)
        XCTAssertEqual(hex.frame.height, 0, accuracy: 0.5)
        XCTAssertEqual(hide.accessibilityLabel(), "Show hex dump")
        XCTAssertEqual(hide.state, .off)
        XCTAssertFalse(hide.isHidden, "the bar stays to bring it back")

        view.setHexDumpVisible(true, animated: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(hex.frame.height, 220, accuracy: 0.5)
        XCTAssertEqual(hide.state, .on)
    }


    /// Dragging the divider to the bottom folds the dump; the bar stays, and
    /// the button turns unselected and offers to open again.
    func testDraggingTheDividerToTheBottomTurnsTheButtonOff() throws {
        let hex = NSView()
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: hex)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(first(ALSplitView.self, in: view) { !$0.isVertical })
        let button = try XCTUnwrap(first(NSButton.self, in: view) {
            $0.accessibilityLabel() == "Hide hex dump"
        })

        split.setDividerPosition(split.maximumDividerPosition(at: 0), at: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(hex.frame.height, 0, accuracy: 0.5)
        XCTAssertFalse(view.isHexDumpVisible)
        XCTAssertEqual(button.state, .off)
        XCTAssertEqual(button.accessibilityLabel(), "Show hex dump")
        XCTAssertFalse(button.isHidden, "the bar did not go with the dump")
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
