import ALSplitView
import AppKit
import XCTest
import CodeAnalysis
import ToolModuleKit
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

    /// The module's name in the header can be selected and copied.
    func testTheModuleNameCanBeSelected() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        let name = try XCTUnwrap(all(NSTextField.self, in: view).first { $0.stringValue == manifest().module.name })
        XCTAssertTrue(name.isSelectable)
        XCTAssertFalse(name.isEditable)
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

    /// View ▸ Zoom In and Zoom Out move the code with the dump beside it:
    /// the C, the listing's rows and the list of functions, and the reader
    /// stays where they were.
    func testTheCodeFollowsTheZoom() throws {
        let suite = "CodePaneViewTests.zoom"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let saved = ToolPanelFont.defaults
        ToolPanelFont.defaults = defaults
        defer {
            ToolPanelFont.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(13.0, forKey: ToolPanelFont.zoomSizeKey)

        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 1, instruction: nil, showsC: true)
        let tables = tables(in: view)
        XCTAssertEqual(tables.count, 2)
        let smallRow = ToolPanelFont.rowHeight
        XCTAssertEqual(codeFontSize(of: view.decompiledAttributedText), 13)

        defaults.set(18.0, forKey: ToolPanelFont.zoomSizeKey)
        NotificationCenter.default.post(name: ToolPanelFont.zoomDidChangeNotification, object: nil)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(codeFontSize(of: view.decompiledAttributedText), 18, "the C is drawn at the new size")
        XCTAssertEqual(view.decompiledText, "return 0;")
        XCTAssertEqual(view.selectedFunction?.name, "entry", "the reader stays in the same function")
        XCTAssertGreaterThan(ToolPanelFont.rowHeight, smallRow)
        for table in tables {
            XCTAssertEqual(table.rowHeight, ToolPanelFont.rowHeight, "a row is as tall as the new size needs")
        }
        let functions = try XCTUnwrap(tables.first { $0.tableColumns.first?.identifier.rawValue == "function" })
        let cell = try XCTUnwrap(functions.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.font?.pointSize, 18, "a function's name is drawn at the new size")
    }

    private func tables(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView { found.append(table) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// The size the C's code is set in — the last character's, past any
    /// annotation heading it.
    private func codeFontSize(of text: NSAttributedString) -> CGFloat? {
        guard text.length > 0 else { return nil }
        return (text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont)?.pointSize
    }

    /// A click on a name highlights its every occurrence, as in Xcode: a
    /// local within its function, a call or a global wherever it leads to the
    /// same place. ⌘-click and a double click go there; Escape clears.
    func testAClickHighlightsTheNamesOccurrences() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try spannedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let c = textView.string as NSString
        func at(_ name: String, after: String = "") -> Int {
            let base = after.isEmpty ? 0 : c.range(of: after).location
            return c.range(of: name, options: [], range: NSRange(location: base, length: c.length - base)).location
        }
        func highlighted() -> [String] { textView.highlightedRanges.map { c.substring(with: $0) } }

        XCTAssertFalse(view.clickC(at: at("Total", after: "return"), event: try click(count: 1)))
        XCTAssertEqual(view.highlightedSymbol, .variable("Total"))
        XCTAssertEqual(highlighted(), Array(repeating: "Total", count: 5), "the declaration and every use")
        // Drawn, not only listed: Xcode's blue-grey shows behind a name.
        textView.appearance = NSAppearance(named: .aqua)
        let box = try XCTUnwrap(textView.layoutManager?.boundingRect(
            forGlyphRange: textView.highlightedRanges[0], in: textView.textContainer!))
        let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / textView.bounds.width
        let corner = NSPoint(x: box.minX + textView.textContainerOrigin.x,
                             y: box.minY + textView.textContainerOrigin.y + 1)
        let pixel = try XCTUnwrap(rep.colorAt(x: Int(corner.x * scale), y: Int(corner.y * scale))?
            .usingColorSpace(.sRGB))
        XCTAssertEqual(Int((pixel.redComponent * 255).rounded()), 0xEE, "\(pixel)")
        XCTAssertEqual(Int((pixel.blueComponent * 255).rounded()), 0xF9, "\(pixel)")

        XCTAssertFalse(view.clickC(at: at("Count", after: "Total ="), event: try click(count: 1)))
        XCTAssertEqual(highlighted(), ["Count", "Count"], "the parameter and its one use")

        // ⌘-click or a double click on a variable selects its definition.
        XCTAssertTrue(view.clickC(at: at("Total", after: "return"), event: try click(count: 1, flags: .command)))
        XCTAssertEqual(textView.selectedRange(), c.range(of: "Total"), "the local's declaration at the top")
        XCTAssertTrue(view.clickC(at: at("Count", after: "Total ="), event: try click(count: 2)))
        XCTAssertEqual(textView.selectedRange(), c.range(of: "Count"), "the parameter in the signature")
        XCTAssertEqual(highlighted(), ["Count", "Count"], "the occurrences stay highlighted")
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")

        XCTAssertFalse(view.clickC(at: at("int"), event: try click(count: 1)))
        XCTAssertNil(view.highlightedSymbol, "a type is not a name to highlight")
        XCTAssertTrue(highlighted().isEmpty)

        // A plain click on a call highlights it and stays.
        XCTAssertFalse(view.clickC(at: at("entry", after: "gValue"), event: try click(count: 1)))
        XCTAssertEqual(view.highlightedSymbol, .target(.function(1)))
        XCTAssertEqual(highlighted(), ["entry"])
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
        let listing = try XCTUnwrap(first(NSTableView.self, in: view) {
            $0.tableColumns.first?.identifier.rawValue == "instruction"
        })
        let call = try XCTUnwrap(listing.view(atColumn: 0, row: 1, makeIfNecessary: true) as? CodeLineCell)
        XCTAssertEqual(call.line.highlighted.map { (call.line.string as NSString).substring(with: $0) }, ["0x6A"],
                       "the listing highlights the instruction that calls it")

        // ⌘-click goes there; a double click too.
        XCTAssertTrue(view.clickC(at: at("entry", after: "gValue"), event: try click(count: 1, flags: .command)))
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        view.goBack()
        XCTAssertTrue(view.clickC(at: at("entry", after: "gValue"), event: try click(count: 2)))
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertEqual(view.highlightedSymbol, .target(.function(1)), "a function stays highlighted across a jump")

        // A local is its function's own: going elsewhere drops it.
        view.goBack()
        XCTAssertFalse(view.clickC(at: at("Total"), event: try click(count: 1)))
        view.goForward()
        XCTAssertNil(view.highlightedSymbol)

        view.goBack()
        XCTAssertFalse(view.clickC(at: at("gValue"), event: try click(count: 1)))
        XCTAssertEqual(highlighted(), ["gValue"])
        view.cancelOperation(nil)
        XCTAssertNil(view.highlightedSymbol)
        XCTAssertTrue(highlighted().isEmpty)
    }

    /// The code is drawn on the background of its own appearance: in Dark,
    /// a dark page, or the C's plain text — white — is white on white.
    func testTheCodeBackgroundFollowsTheViewsAppearance() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        func brightness() throws -> CGFloat {
            let page = try XCTUnwrap(all(NSView.self, in: view).first {
                $0.layer?.backgroundColor != nil && $0.subviews.contains { $0 is NSStackView }
            })
            let color = try XCTUnwrap(page.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?
                .usingColorSpace(.sRGB))
            return color.brightnessComponent
        }
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            view.appearance = NSAppearance(named: .darkAqua)
            view.viewDidChangeEffectiveAppearance()
        }
        XCTAssertLessThan(try brightness(), 0.3, "a dark page in Dark")
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            view.appearance = NSAppearance(named: .aqua)
            view.viewDidChangeEffectiveAppearance()
        }
        XCTAssertGreaterThan(try brightness(), 0.9, "a white page in Light")
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

        // The module is the title; the versions are the small grey line
        // under it, with no brackets.
        let name = try XCTUnwrap(first(NSTextField.self, in: view) {
            $0.stringValue == "CpuPei"
        })
        let versions = try XCTUnwrap(first(NSTextField.self, in: view) {
            $0.stringValue == "code-v2 · Ghidra 12.1.2"
        })
        XCTAssertEqual(versions.textColor, .secondaryLabelColor)
        XCTAssertLessThan(versions.font?.pointSize ?? 99, name.font?.pointSize ?? 0)
        let nameRect = view.convert(name.bounds, from: name)
        let versionsRect = view.convert(versions.bounds, from: versions)
        XCTAssertGreaterThan(nameRect.minY, versionsRect.maxY - 1, "the versions are under the name")
        XCTAssertEqual(nameRect.minX, versionsRect.minX, accuracy: 1)

        // Then, on one line and centred on it: Back, Forward, Callers; the
        // ASM/C switch at the right.
        let buttons = all(NSButton.self, in: view).filter { !($0 is NSPopUpButton) }
        let back = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Back" })
        let forward = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Forward" })
        let callers = try XCTUnwrap(all(NSPopUpButton.self, in: view).first {
            $0.menu?.items.first?.title.hasPrefix("Callers") == true
        })
        let rects = [back, forward, callers, mode].map { view.convert($0.bounds, from: $0) }
        let row = nameRect.union(versionsRect)
        for rect in rects {
            XCTAssertEqual(rect.midY, row.midY, accuracy: 1.5, "every control is centred on the header")
        }
        XCTAssertLessThan(nameRect.maxX, rects[0].minX)
        XCTAssertLessThan(rects[0].maxX, rects[1].minX + 1)
        XCTAssertLessThan(rects[1].maxX, rects[2].minX)
        XCTAssertLessThan(rects[2].maxX, rects[3].minX)
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
            $0.stringValue == "CpuPei"
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

    /// The side can be chosen without moving the reader — what `open_code`'s
    /// `view` asks for when the panel is opened on the C.
    func testTheSideCanBeChosenWithoutMovingTheReader() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()
        view.selectInstruction(at: 2)

        view.showDecompiledC(true)
        XCTAssertTrue(view.showsDecompiledC)
        XCTAssertEqual(view.decompiledText, "return 0;")
        XCTAssertEqual(view.selectedInstructionIndex, 2, "and the place is where it was")

        view.showDecompiledC(false)
        XCTAssertFalse(view.showsDecompiledC)
        XCTAssertEqual(view.selectedInstructionIndex, 2)
    }

    /// A place kept by address wins over indices that name another place —
    /// what an artifact numbered differently, another recipe or a re-run,
    /// does to them; a place this artifact lacks falls back to the indices.
    func testAPlaceByAddressWinsOverStaleIndices() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()
        view.selectInstruction(at: 2)
        let place = try XCTUnwrap(view.selectedLocation)
        XCTAssertEqual(place.address, CodeAddress(0x355))

        view.restore(at: place, function: 0, instruction: 0, showsC: false)
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x355))

        view.restore(at: CodeLocation(function: CodeAddress(0xDEAD)), function: 1, instruction: 2,
                     showsC: false)
        XCTAssertEqual(view.selectedInstructionIndex, 2, "the indices, when the address is gone")
    }

    /// A pane over a republished artifact takes the history by address.
    func testAPaneTakesOverAnotherPanesHistory() throws {
        let first = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                 moduleBytes: teModule(), hexView: NSView())
        first.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        first.layoutSubtreeIfNeeded()
        first.restore(function: 0, instruction: nil, showsC: false)
        first.go(to: CodeLocation(address: CodeAddress(0x355)))
        XCTAssertTrue(first.canGoBack)
        let carried = first.historyLocations
        XCTAssertEqual(carried.places.count, 2)

        let second = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                  moduleBytes: teModule(), hexView: NSView())
        second.frame = first.frame
        second.layoutSubtreeIfNeeded()
        second.restore(at: first.selectedLocation, function: nil, instruction: nil, showsC: false)
        second.adoptHistory(carried.places, index: carried.index)
        XCTAssertTrue(second.canGoBack)
        second.goBack()
        XCTAssertEqual(second.selectedFunctionIndex, 0)
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

    /// A v5 POST list is by value, the codes it could not tell last; a row
    /// says the code and who sends it, and a click goes to the call that
    /// sends it — in the listing and in the C — while the list stays.
    func testAPostCodeGoesToTheCallThatSendsIt() throws {
        let c = "void Caller(void)\n{\n  Halt(0x20320120);\n  Halt(0x10195);\n}\n"
        let first = (c as NSString).range(of: "Halt")
        let second = (c as NSString).range(of: "Halt", range: NSRange(location: NSMaxRange(first), length: (c as NSString).length - NSMaxRange(first)))
        let json: [String: Any] = [
            "script_version": 5, "ghidra": "12.1.2", "program": ["image_base": "0x0"],
            "functions": [
                ["entry": "0x220", "name": "Caller", "c": c,
                 "c_sites": [[first.location, first.length, "0x221"], [second.location, second.length, "0x222"]],
                 "instructions": [
                    ["address": "0x220", "bytes": "56", "mnemonic": "PUSH", "text": "PUSH ESI"],
                    ["address": "0x221", "bytes": "E8", "mnemonic": "CALL", "text": "CALL 0x355"],
                    ["address": "0x222", "bytes": "E8", "mnemonic": "CALL", "text": "CALL 0x355"]]],
                ["entry": "0x355", "name": "Halt", "c": "void Halt(int Code)\n{\n}\n",
                 "instructions": [["address": "0x355", "bytes": "EE", "mnemonic": "OUT", "text": "OUT DX,EAX"]]]
            ],
            "post_codes": [
                ["address": "0x221", "function": "0x220", "port": "0x80", "value": "0x20320120", "width": 4,
                 "via": [["function": "0x355", "name": "Halt"]], "text": "CALL 0x355"],
                ["address": "0x222", "function": "0x220", "port": "0x80", "value": "0x10195", "width": 4,
                 "via": [["function": "0x355", "name": "Halt"]], "text": "CALL 0x355"],
                ["address": "0x355", "function": "0x355", "port": "0x80", "width": 4,
                 "unresolved": "value-computed", "via": [], "text": "OUT DX,EAX"]
            ]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        var ranges: [Range<UInt64>] = []
        view.onSelectRange = { ranges.append($0) }

        view.selectList(.postCodes)
        XCTAssertEqual(view.listedPostCodeCount, 3)
        XCTAssertEqual((0..<3).map { view.navigatorRowText($0) },
                       ["0x00010195  Caller", "0x20320120  Caller", "Value unknown  Halt"],
                       "by value, the unknown last")
        XCTAssertEqual(view.selectedPostCode?.value, 0x10195)
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x222), "the call that sends it")
        XCTAssertEqual(view.selectedFunction?.name, "Caller")
        let code = try XCTUnwrap(all(CodeTextView.self, in: view).first)
        XCTAssertEqual(code.selectedRange(), second, "the call in the C")
        XCTAssertEqual(view.navigatorTitle, "POST codes", "the list stays in front")
        XCTAssertEqual(ranges.last, 0x6A..<0x6B, "the call's bytes")

        XCTAssertEqual(view.navigatorColumnTitles, ["Code", "Function", "Through", "Call address"],
                       "aligned columns under headers")
        XCTAssertEqual(view.postCell(1, .code), "0x20320120")
        XCTAssertEqual(view.postCell(1, .function), "Caller")
        XCTAssertEqual(view.postCell(1, .via), "Halt")
        XCTAssertEqual(view.postCell(1, .address), "0x69", "as the panel shows addresses: the byte in the module")
        XCTAssertEqual(view.postCell(2, .code), "Value unknown")
        view.selectList(.functions)
        XCTAssertEqual(view.navigatorColumnTitles, [], "the other lists stay one column")
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
        XCTAssertEqual(cell.line.onClick?(.function(1), try click(count: 1)), false,
                       "a plain click highlights and leaves the row to the table")
        XCTAssertEqual(view.highlightedSymbol, .target(.function(1)))
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
        XCTAssertEqual(cell.line.onClick?(.function(1), try click(count: 1, flags: .command)), true)
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertTrue(view.canGoBack)
    }

    /// An annotation on code shows at its place: beside the function in the
    /// list, at the end of the instruction's row, over the function's C; and
    /// the rows carry the menu Add Annotation… is offered in.
    func testAnnotationsShowAtTheirPlaceInTheCode() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try linkedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        view.setNotes([
            CodeNote(id: "a1", title: "Saves ESI", note: "", location: CodeLocation(address: CodeAddress(0x220)),
                     byPerson: false),
            CodeNote(id: "a2", title: "The caller", note: "Calls entry.",
                     location: CodeLocation(function: CodeAddress(0x220)), byPerson: true)
        ])
        let listing = try XCTUnwrap(first(NSTableView.self, in: view) {
            $0.tableColumns.first?.identifier.rawValue == "instruction"
        })
        let row = try XCTUnwrap(listing.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CodeLineCell)
        XCTAssertTrue(row.line.string.hasSuffix("◆ a1 Saves ESI"), row.line.string)
        view.restore(function: 0, instruction: nil, showsC: true)
        XCTAssertTrue(view.decompiledText.hasPrefix("// ◆ a1 Saves ESI @ 0x68\n// ◆ a2 The caller — Calls entry.\n"),
                      view.decompiledText)

        // A right-click is not simulated here; with no row clicked the menu
        // offers nothing rather than a place that is not there.
        view.onAnnotate = { _, _ in }
        let functions = try XCTUnwrap(first(NSTableView.self, in: view) {
            $0.tableColumns.first?.identifier.rawValue == "function"
        })
        let menu = try XCTUnwrap(functions.menu)
        XCTAssertNil(view.clickedPlace(in: functions))
        view.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.isEmpty)
    }

    /// Callers lists calls, not callers: a function that calls twice is
    /// two items, and choosing one goes to that call — its instruction in
    /// the listing, the call itself in the C.
    func testCallersListsEachCallAndGoesToIt() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,"program":{"image_base":"0x0"},
         "functions":[
          {"entry":"0x220","name":"FUN_00000220","callers":[],
           "c":"void FUN_00000220(void)\\n{\\n  entry();\\n  entry();\\n}\\n",
           "instructions":[
            {"address":"0x220","bytes":"E8 00","mnemonic":"CALL","text":"CALL 0x00000230",
             "references":[{"to":"0x230","type":"UNCONDITIONAL_CALL"}]},
            {"address":"0x222","bytes":"E8 00","mnemonic":"CALL","text":"CALL 0x00000230",
             "references":[{"to":"0x230","type":"UNCONDITIONAL_CALL"}]}]},
          {"entry":"0x230","name":"entry","callers":["0x220"],"c":"void entry(void)\\n{\\n}\\n",
           "instructions":[{"address":"0x230","bytes":"C3","mnemonic":"RET","text":"RET"}]}]}
        """.utf8))
        let view = CodePaneView(manifest: manifest(), artifact: artifact,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 1, instruction: nil, showsC: true)
        let callers = try XCTUnwrap(all(NSPopUpButton.self, in: view).first {
            $0.menu?.items.first?.title.hasPrefix("Callers") == true
        })
        let items = try XCTUnwrap(callers.menu?.items)
        XCTAssertEqual(items.map(\.title), ["Callers (2)", "FUN_00000220 @ 0x68", "FUN_00000220 @ 0x6A"])

        _ = items[2].target?.perform(items[2].action, with: items[2])
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x222))
        let textView = try XCTUnwrap(first(NSTextView.self, in: view) { _ in true })
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        XCTAssertEqual(selected, "entry")
        let second = (textView.string as NSString).range(of: "entry", options: .backwards)
        XCTAssertEqual(textView.selectedRange(), second, "the second call, not the first")
        XCTAssertTrue(view.canGoBack)
    }

    /// A link underlines under the pointer, in the listing and in the C.
    func testALinkUnderlinesUnderThePointer() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try linkedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        let listing = try XCTUnwrap(first(NSTableView.self, in: view) {
            $0.tableColumns.first?.identifier.rawValue == "instruction"
        })
        let cell = try XCTUnwrap(listing.view(atColumn: 0, row: 1, makeIfNecessary: true) as? CodeLineCell)
        cell.line.frame = NSRect(x: 0, y: 0, width: 600, height: 18)
        let text = cell.line.string as NSString
        let target = text.range(of: "0x6A", options: .backwards)
        let font = NSFont.monospacedSystemFont(ofSize: ToolPanelFont.size, weight: .regular)
        let x = NSAttributedString(string: text.substring(to: target.location + 1), attributes: [.font: font]).size().width
        cell.line.hover(at: NSPoint(x: x, y: 9))
        XCTAssertEqual(cell.line.hoveredLink, target)
        cell.line.hover(at: NSPoint(x: 1, y: 9))
        XCTAssertNil(cell.line.hoveredLink, "the address column is no link")

        view.restore(function: 0, instruction: nil, showsC: true)
        view.layoutSubtreeIfNeeded()
        let code = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let call = (code.string as NSString).range(of: "entry")
        let layout = try XCTUnwrap(code.layoutManager)
        let glyphs = layout.glyphRange(forCharacterRange: call, actualCharacterRange: nil)
        let box = layout.boundingRect(forGlyphRange: glyphs, in: try XCTUnwrap(code.textContainer))
        code.hover(at: NSPoint(x: box.midX + code.textContainerOrigin.x, y: box.midY + code.textContainerOrigin.y))
        XCTAssertEqual(code.hoveredLink, call)
        XCTAssertNotNil(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: call.location,
                                                  effectiveRange: nil))
        code.hover(at: nil)
        XCTAssertNil(code.hoveredLink)
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

    /// A v4 artifact whose C says what each name is: a parameter, a local
    /// used five times, a global, a call.
    private func spannedArtifact() throws -> CodeArtifact {
        let c = "int FUN_00000220(int Count)\n{\n  int Total;\n  Total = Count;\n"
            + "  Total = Total + gValue;\n  entry();\n  return Total;\n}\n"
        let text = c as NSString
        var spans: [[Any]] = []
        func span(_ name: String, _ kind: String, _ target: String? = nil) {
            var from = 0
            while true {
                let found = text.range(of: name, options: [], range: NSRange(location: from, length: text.length - from))
                guard found.location != NSNotFound else { return }
                spans.append([found.location, found.length, kind] + (target.map { [$0] } ?? []))
                from = found.location + found.length
            }
        }
        span("Count", "parameter")
        span("Total", "local")
        span("gValue", "global", "0x230")
        span("entry", "function", "0x222")
        span("int", "type")
        let json: [String: Any] = [
            "script_version": 4, "ghidra": "12.1.2", "program": ["image_base": "0x0"],
            "functions": [
                ["entry": "0x220", "name": "FUN_00000220", "c": c, "c_spans": spans,
                 "instructions": [
                    ["address": "0x220", "bytes": "56", "mnemonic": "PUSH", "text": "PUSH ESI"],
                    ["address": "0x221", "bytes": "E8 00", "mnemonic": "CALL", "text": "CALL 0x00000222",
                     "references": [["to": "0x222", "type": "UNCONDITIONAL_CALL"]]]]],
                ["entry": "0x222", "name": "entry", "c": "void entry(void)\n{\n}\n",
                 "instructions": [["address": "0x222", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]
            ]
        ]
        return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func click(count: Int, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: flags,
                                         timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                         clickCount: count, pressure: 1))
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
        XCTAssertTrue(view.isLoadingRecipe, "the dropdown waits while the app reads it")
        chosen = nil
        view.chooseRecipe(at: 1)
        XCTAssertNil(chosen, "a second choice waits for the first")
        view.recipeLoadFailed()
        XCTAssertFalse(view.isLoadingRecipe)
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
