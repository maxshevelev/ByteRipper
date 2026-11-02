import ALSplitView
import AppKit
import XCTest
import CodeAnalysis
import HelpBook
import HelpUI
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

    /// The same manifest, published as the given revision of a reading — a
    /// pane that can tell one revision of its module from another.
    private func manifest(revision: Int) -> AnalysisManifest {
        var manifest = manifest()
        manifest.reading = AnalysisReading(project: "p", rev: revision)
        return manifest
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

    /// ⌘C with the list of functions in focus copies the selected
    /// function's name; with anything else in focus it is not offered here.
    func testCopyTakesTheSelectedFunctionsName() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.copyableFunctionName, "the list does not have the keyboard")
        let list = try XCTUnwrap(all(NSTableView.self, in: view).first { $0.numberOfRows == view.listedFunctionCount && $0.tableColumns.contains { $0.identifier.rawValue == "function" } })
        window.makeFirstResponder(list)
        view.selectFunction(at: 1)
        XCTAssertEqual(view.copyableFunctionName, "entry")
        let item = NSMenuItem(title: "Copy", action: #selector(CodePaneView.copy(_:)), keyEquivalent: "c")
        XCTAssertTrue(view.validateMenuItem(item))
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
        let functions = try XCTUnwrap(tables.first { $0.tableColumns.contains { $0.identifier.rawValue == "function" } })
        for table in tables {
            XCTAssertEqual(table.rowHeight,
                           table === functions ? CodePaneView.navigatorRowHeight : CodePaneView.codeLineHeight,
                           "a row is as tall as the new size needs")
        }
        let cell = try XCTUnwrap(functions.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.font?.pointSize, 16.5,
                       "a function's name is drawn at the new size, a step under the code's")
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
        // Drawn, not only listed: the box is the panel's blue-grey, laid at
        // one alpha so a diff row's tint shows through it.
        XCTAssertEqual(textView.highlightFill.alphaComponent, CodeTextView.highlightAlpha, accuracy: 0.001)

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

    /// The header reads where the reader is: Back and Forward first, then
    /// the module, its review's revision, ▸ and the function; the versions
    /// are the small grey line under them, ASM/C/Description at the right.
    func testTheHeaderReadsModuleRevisionAndFunction() throws {
        var reviewed = manifest()
        reviewed.reading = AnalysisReading(project: "p", rev: 14)
        let view = CodePaneView(manifest: reviewed, artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        // The code side 500 points wide, beside the navigator.
        view.frame = NSRect(x: 0, y: 0, width: 500 + CodePaneView.defaultNavigatorWidth, height: 360)
        view.layoutSubtreeIfNeeded()

        let mode = try XCTUnwrap(first(NSSegmentedControl.self, in: view) {
            $0.label(forSegment: 0) == "ASM"
        })
        XCTAssertEqual((0..<mode.segmentCount).map { mode.label(forSegment: $0) ?? "" },
                       ["ASM", "C", "Description"])
        let modeRect = view.convert(mode.bounds, from: mode)
        XCTAssertGreaterThan(modeRect.minX, view.bounds.midX,
                             "the switch is on the code side")
        XCTAssertGreaterThan(modeRect.minY, view.bounds.maxY - 80,
                             "and at the top")

        func field(_ text: String) throws -> NSTextField {
            try XCTUnwrap(first(NSTextField.self, in: view) { $0.stringValue == text && !$0.isHidden }, text)
        }
        let name = try field("CpuPei")
        let revision = try field("(r14)")
        let mark = try field("▸")
        let function = try XCTUnwrap(first(CodeTitleField.self, in: view) { _ in true })
        XCTAssertEqual(function.stringValue, "FUN_00000220")
        XCTAssertTrue(name.isSelectable)
        XCTAssertTrue(function.isSelectable, "the function's name can be copied too")
        XCTAssertFalse(function.isEditable)
        XCTAssertEqual(revision.textColor, .secondaryLabelColor)
        let versions = try field("code-v2 · Ghidra 12.1.2")
        XCTAssertEqual(versions.textColor, .secondaryLabelColor)
        XCTAssertLessThan(versions.font?.pointSize ?? 99, name.font?.pointSize ?? 0)

        let buttons = all(NSButton.self, in: view).filter { !($0 is NSPopUpButton) }
        let back = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Back" })
        let forward = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Forward" })
        let rects = [back, forward, name, revision, mark, function, mode].map { view.convert($0.bounds, from: $0) }
        for (left, right) in zip(rects, rects.dropFirst()) {
            XCTAssertLessThan(left.maxX, right.minX + 1, "left to right in reading order")
        }
        for field in [name, revision, mark, function] {
            XCTAssertGreaterThanOrEqual(field.frame.width, field.intrinsicContentSize.width - 1,
                                        "\(field.stringValue) is shown whole while there is room")
        }
        let nameRect = rects[2]
        // The versions line is anchored by its archive box, so the box — not
        // the text after it — stands under the module's name.
        let versionsLine = try XCTUnwrap(all(CodeVersionsLine.self, in: view).first)
        let versionsRect = view.convert(versionsLine.bounds, from: versionsLine)
        XCTAssertGreaterThan(nameRect.minY, versionsRect.maxY - 1, "the versions are under the name")
        // The text fields carry a bezel inset of their own; the line and the
        // name are compared where the layout puts them.
        let nameEdge = view.convert(name.alignmentRect(forFrame: name.bounds), from: name)
        let versionsEdge = view.convert(versionsLine.alignmentRect(forFrame: versionsLine.bounds),
                                        from: versionsLine)
        XCTAssertEqual(nameEdge.minX, versionsEdge.minX, accuracy: 1,
                       "the line's icon stands under the module's name")
        for rect in rects[3...5] {
            XCTAssertEqual(rect.midY, nameRect.midY, accuracy: 1.5, "one line with the module's name")
        }
        let block = nameRect.union(versionsRect)
        for rect in [rects[0], rects[1], rects[6]] {
            XCTAssertEqual(rect.midY, block.midY, accuracy: 1.5, "the controls are centred on the header")
        }

        view.selectFunction(at: 1)
        XCTAssertEqual(function.stringValue, "entry", "the function follows the selection")
        XCTAssertTrue(all(NSPopUpButton.self, in: view).allSatisfy {
            $0.menu?.items.first?.title.hasPrefix("Callers") != true
        }, "no Callers dropdown: Show Callers is the function's menu")
    }

    /// A module with no published review has no revision to show.
    func testTheHeaderHasNoRevisionWithoutAReview() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(all(NSTextField.self, in: view).contains {
            $0.stringValue.hasPrefix("(r") && !$0.isHidden
        })
    }


    /// Where the store holds more than one analysis, the versions line under
    /// the module's name is the menu that chooses among them: each named as
    /// the line names the one shown. The dump bar keeps only the fold button.
    func testTheVersionsLineIsTheAnalysisMenu() throws {
        var second = manifest()
        second.recipe = AnalysisRecipe(id: "code-v3-ghidra-12.2", exporter: 3,
                                       ghidra: "12.2", script: "ExportCode.java")
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView(),
                                recipes: [manifest(), second])
        // A window wide enough for the header's two rows: in a narrow one the
        // line gives way, truncated, as the plain line did.
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 400)
        view.layoutSubtreeIfNeeded()

        let analysis = try XCTUnwrap(all(CodeVersionsLine.self, in: view).first {
            $0.accessibilityLabel() == "Analysis"
        })
        let fold = try XCTUnwrap(first(NSButton.self, in: view) {
            $0.accessibilityLabel() == "Hide hex dump"
        })
        let name = try XCTUnwrap(first(NSTextField.self, in: view) {
            $0.stringValue == "CpuPei" && !$0.isHidden
        })
        let analysisRect = view.convert(analysis.bounds, from: analysis)
        let nameRect = view.convert(name.bounds, from: name)
        let foldRect = view.convert(fold.bounds, from: fold)
        XCTAssertLessThan(analysisRect.midY, nameRect.midY, "the menu is under the name")
        // The bezel's own alignment inset puts its frame a couple of points
        // left of the label's, so the text inside lines up with the name.
        XCTAssertEqual(analysisRect.minX, nameRect.minX, accuracy: 3, "left with the name")
        XCTAssertGreaterThan(analysisRect.minY, view.bounds.midY,
                             "in the header, not in the bar at the bottom")
        XCTAssertLessThan(foldRect.maxY, analysisRect.minY,
                          "the dump bar is below the menu, with only its fold button")

        XCTAssertEqual(analysis.title, "code-v2 · Ghidra 12.1.2",
                       "the line reads as the plain versions line does")
        XCTAssertGreaterThan(analysis.frame.width, 100,
                             "the line keeps its text beside the chevron")
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
                $0.tableColumns.contains { $0.identifier.rawValue == "function" }
            })
        let cell = try XCTUnwrap(list.view(atColumn: 0, row: 0, makeIfNecessary: true)
                                    as? NSTableCellView)
        let field = try XCTUnwrap(cell.textField)
        let headingLeft = view.convert(heading.alignmentRect(forFrame: heading.bounds),
                                       from: heading).minX
        let rowTextLeft = view.convert(field.alignmentRect(forFrame: field.bounds),
                                       from: field).minX
        // The by-address table sets its first cell half an intercell gap in
        // from the pane's edge; the heading keeps to the pane's.
        XCTAssertEqual(headingLeft, rowTextLeft, accuracy: 3.5,
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
        let carried = first.carriedHistory
        XCTAssertEqual(carried.places.count, 2)

        let second = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                  moduleBytes: teModule(), hexView: NSView())
        second.frame = first.frame
        second.layoutSubtreeIfNeeded()
        second.restore(at: first.selectedLocation, function: nil, instruction: nil, showsC: false)
        second.adoptHistory(carried)
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
                $0.tableColumns.contains { $0.identifier.rawValue == "function" }
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
        XCTAssertEqual(view.navigatorColumnTitles, ["Address", "Function"],
                       "the by-address list is a table of the address and the name")
    }

    /// Strings are a table like POST: the address and the text under
    /// headers, each title where its column's text starts, and a string's
    /// line breaks written as C writes them so a row never runs onto the next.
    func testStringsAreATableOfOneLineRows() throws {
        let json: [String: Any] = [
            "script_version": 5, "ghidra": "12.1.2", "program": ["image_base": "0x0"],
            "strings": [["address": "0x220", "type": "string", "value": "\n!!!! IA32 Exception\tType\r\n"]],
            "functions": [["entry": "0x220", "name": "F", "instructions": [
                ["address": "0x220", "bytes": "56", "mnemonic": "PUSH", "text": "PUSH ESI"]]]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        view.selectList(.strings)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.navigatorColumnTitles, ["Location", "Text"])
        XCTAssertEqual(view.navigatorRowText(0), "0x68  \\n!!!! IA32 Exception\\tType\\r\\n")
        XCTAssertEqual(CodePaneView.oneLine("a\u{1B}b\u{2028}"), "a\\x1Bb\\u2028")

        let navigator = try XCTUnwrap(tables(in: view).first { $0.headerView is CodeNavigatorHeader })
        let header = try XCTUnwrap(navigator.headerView as? CodeNavigatorHeader)
        for column in 0..<navigator.numberOfColumns {
            let cell = try XCTUnwrap(navigator.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)
            let field = try XCTUnwrap(cell.textField)
            XCTAssertFalse(field.stringValue.contains("\n"), "one line")
            cell.layoutSubtreeIfNeeded()
            // A label's alignment rect starts at its first glyph; its frame
            // is two points further out.
            let textX = cell.convert(field.alignmentRect(forFrame: field.frame), to: navigator).minX
            let titleX = header.headerRect(ofColumn: column).minX + CodeNavigatorHeader.titleInset(in: navigator)
            XCTAssertEqual(titleX, textX, accuracy: 0.5, "the title of column \(column) over its text")
        }
        let text = try XCTUnwrap(navigator.tableColumn(withIdentifier: .init("string-text")))
        XCTAssertEqual(navigator.rect(ofColumn: 1).maxX, navigator.bounds.maxX, accuracy: 1,
                       "the text takes the pane's remaining width")
        XCTAssertGreaterThan(text.width, 200)
    }

    /// An empty list says why; Status, empty for any module but a 32-bit
    /// PEI one, says where the analysis looks.
    func testAnEmptyListSaysWhy() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.selectList(.statusCodes)
        XCTAssertNil(view.emptyListText, "the list has a row")
        view.filter(by: "nothing like this")
        XCTAssertEqual(view.emptyListText, "Nothing matches the search.")

        let json: [String: Any] = [
            "script_version": 5, "ghidra": "12.1.2", "program": ["image_base": "0x0"],
            "functions": [["entry": "0x220", "name": "F", "instructions": [
                ["address": "0x220", "bytes": "56", "mnemonic": "PUSH", "text": "PUSH ESI"]]]]
        ]
        let bare = CodePaneView(manifest: manifest(),
                                artifact: try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json)),
                                moduleBytes: teModule(), hexView: NSView())
        bare.selectList(.statusCodes)
        XCTAssertTrue(bare.emptyListText?.contains("32-bit PEI") ?? false)
        bare.selectList(.strings)
        XCTAssertEqual(bare.emptyListText, "The analysis found none in this module.")
        let table = try XCTUnwrap(tables(in: bare).first { $0.headerView is CodeNavigatorHeader })
        XCTAssertTrue(try XCTUnwrap(table.enclosingScrollView).isHidden,
                      "no headers over an empty list: the sentence stands alone")
        bare.selectList(.functions)
        XCTAssertNil(bare.emptyListText)
        XCTAssertFalse(try XCTUnwrap(table.enclosingScrollView).isHidden, "a list with rows shows them")
    }

    /// The navigator opens wide enough for a POST row, and at the width the
    /// reader last dragged it to after that.
    func testTheNavigatorKeepsTheWidthItWasDraggedTo() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "CodePaneViewTests.navigatorWidth"))
        suite.removePersistentDomain(forName: "CodePaneViewTests.navigatorWidth")
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: "CodePaneViewTests.navigatorWidth")
            CodePaneView.defaults = .standard
        }
        func navigatorWidth(_ view: CodePaneView) throws -> (split: ALSplitView, width: CGFloat) {
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
            view.layoutSubtreeIfNeeded()
            let split = try XCTUnwrap(all(ALSplitView.self, in: view).first { $0.isVertical })
            return (split, split.panes[0].frame.width)
        }
        let first = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                 moduleBytes: teModule(), hexView: NSView())
        let (split, width) = try navigatorWidth(first)
        XCTAssertEqual(width, CodePaneView.defaultNavigatorWidth)

        split.setDividerPosition(420)
        XCTAssertEqual(suite.double(forKey: CodePaneView.navigatorWidthKey), 420)
        let second = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                  moduleBytes: teModule(), hexView: NSView())
        XCTAssertEqual(try navigatorWidth(second).width, 420, "the next pane opens at it")

        split.setDividerPosition(990)
        XCTAssertLessThanOrEqual(split.panes[0].frame.width, 1000 - 320, "the code keeps room")
    }

    /// The switch under the list lays the functions out in the chosen order,
    /// keeps the choice for the next panel, and a group heading is a row of
    /// its own that is not selectable.
    func testTheFunctionOrderSwitchGroupsTheList() throws {
        let suiteName = "CodePaneViewTests.navigatorOrder"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        view.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(all(NSTableView.self, in: view).first {
            $0.tableColumns.contains { $0.identifier.rawValue == "function" }
        })
        XCTAssertEqual(view.functionOrder, .address)
        XCTAssertEqual(list.numberOfRows, view.listedFunctionCount)

        view.setFunctionOrder(.review)
        XCTAssertEqual(view.functionOrder, .review)
        XCTAssertEqual(suite.integer(forKey: CodePaneView.navigatorOrderKey),
                       CodeReaderState.FunctionOrder.review.rawValue, "the choice is kept")
        XCTAssertEqual(list.numberOfRows, view.listedFunctionCount + 1,
                       "the one heading takes a row of its own")
        XCTAssertFalse(view.tableView(list, shouldSelectRow: 0), "a group's node is not selected")
        XCTAssertTrue(view.tableView(list, shouldSelectRow: 1))

        // The group is a tree node: its triangle closes and opens its rows.
        let headingCell = try XCTUnwrap(list.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let triangle = try XCTUnwrap(all(NSButton.self, in: headingCell).first)
        XCTAssertFalse(triangle.isHidden)
        triangle.performClick(nil)
        XCTAssertEqual(list.numberOfRows, 1, "a closed group keeps only its own row")
        XCTAssertEqual((list.view(atColumn: 0, row: 0, makeIfNecessary: true)
            as? NSTableCellView)?.textField?.stringValue,
                       "Review level not recorded (2)", "and still says how many it holds")
        let reopened = try XCTUnwrap(all(NSButton.self, in: try XCTUnwrap(
            list.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSView)).first)
        reopened.performClick(nil)
        XCTAssertEqual(list.numberOfRows, 3)
        let heading = try XCTUnwrap(list.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(heading.textField?.stringValue, "Review level not recorded (2)",
                       "a heading says how many functions it holds")
        XCTAssertEqual(CodePaneView.title(of: .full), "Fully reviewed")
        XCTAssertEqual(CodePaneView.title(of: .partial), "Partly reviewed")
        XCTAssertEqual(CodePaneView.title(of: .decompiled), "Decompiler only")
        XCTAssertEqual(CodePaneView.title(of: .library), "Library functions")
        XCTAssertEqual(CodePaneView.title(of: .noBody), "No body")
        XCTAssertEqual(CodePaneView.title(of: .unknown), "Review level not recorded")

        let next = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        XCTAssertEqual(next.functionOrder, .review, "the next panel opens in it")
    }

    /// The layouts are three separate flat buttons, not the segments of one
    /// control: the one in front carries the plate, and a click on another
    /// moves it.
    func testTheFunctionViewIsThreeSeparateButtons() throws {
        let suiteName = "CodePaneViewTests.orderButtons"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        view.layoutSubtreeIfNeeded()

        let buttons = view.navigatorOrderButtons.compactMap { $0 as? CodeOrderButton }
        XCTAssertEqual(buttons.count, 3, "each layout is a button of its own")
        XCTAssertEqual(buttons.map(\.isChosen), [true, false, false])
        XCTAssertEqual(buttons.map(\.toolTip), [
            "List the functions in the order they lie in the module",
            "Hang each function under the one that calls it",
            "Gather the functions by how far the review has got with each"
        ])
        for button in buttons {
            XCTAssertFalse(button.isBordered, "a flat symbol, not a boxed control")
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertEqual(button.state, button.isChosen ? .on : .off,
                           "the choice is a state, not only a plate")
        }

        buttons[2].performClick(nil)
        XCTAssertEqual(view.functionOrder, .review)
        XCTAssertEqual(buttons.map(\.isChosen), [false, false, true], "the colour moves")
        XCTAssertEqual(buttons.map(\.contentTintColor),
                       [.secondaryLabelColor, .secondaryLabelColor, .controlAccentColor],
                       "the chosen one differs by its symbol's colour")
        XCTAssertTrue(buttons.allSatisfy { !$0.isBordered }, "flat: a symbol and nothing around it")
        XCTAssertEqual(buttons.map(\.state), [.off, .off, .on])
    }

    /// In the grouped order a function's hover says where its review stands:
    /// the level, and what still keeps it from full.
    func testTheGroupedRowsSayWhereTheReviewStands() throws {
        let suiteName = "CodePaneViewTests.reviewDetail"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        let art = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":8,"program":{"image_base":"0x0"},
         "functions":[
          {"entry":"0x100","name":"Partly","review_level":"partial",
           "review_gaps":["plate","locals"],"instructions":[]},
          {"entry":"0x200","name":"CopyMem","review_level":"library","library_kind":"edk2",
           "instructions":[]}]}
        """.utf8))
        let view = CodePaneView(manifest: manifest(), artifact: art,
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        view.setFunctionOrder(.review)
        view.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(all(NSTableView.self, in: view).first {
            $0.tableColumns.contains { $0.identifier.rawValue == "function" }
        })
        func tooltip(_ row: Int) throws -> String? {
            try XCTUnwrap(list.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView).toolTip
        }
        // The partial group reads before the library one; a library function
        // sits under its kind's heading and says whose library it is.
        XCTAssertEqual(try tooltip(1), "Review: partly reviewed — missing plate comment, unnamed locals")
        XCTAssertNil(try tooltip(3), "the kind's heading")
        XCTAssertEqual(try tooltip(4), "Review: library function: EDK2")
    }

    /// Every function's name carries the function mark, a call in the tree
    /// as much as its root; a review group's heading carries its level's.
    func testFunctionsCarryTheFunctionMarkAndGroupsTheirLevels() throws {
        let suiteName = "CodePaneViewTests.navigatorIcons"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,"program":{"image_base":"0x0"},
         "functions":[
          {"entry":"0x100","name":"Leaf","callers":["0x200"],"callees":[],
           "instructions":[{"address":"0x100","bytes":"C3","text":"RET"}]},
          {"entry":"0x200","name":"Root","callers":[],"callees":["0x100"],
           "instructions":[{"address":"0x200","bytes":"C3","text":"RET"}]},
          {"entry":"0x300","name":"ZOther","callers":[],"callees":[],
           "instructions":[{"address":"0x300","bytes":"C3","text":"RET"}]}]}
        """.utf8))
        let view = CodePaneView(manifest: manifest(), artifact: artifact,
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        view.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(all(NSTableView.self, in: view).first {
            $0.tableColumns.contains { $0.identifier.rawValue == "function" }
        })
        func cell(_ table: NSTableView, _ column: Int, _ row: Int) throws -> CodeNavigatorCell {
            try XCTUnwrap(table.view(atColumn: column, row: row, makeIfNecessary: true)
                as? CodeNavigatorCell)
        }
        let code = "function"

        // By address: the name column carries the code mark, the address none.
        let nameColumn = try XCTUnwrap(list.tableColumns.firstIndex {
            $0.identifier.rawValue == "function"
        })
        XCTAssertEqual(try cell(list, nameColumn, 0).iconName, code)
        XCTAssertNil(try cell(list, 0, 0).iconName, "an address is not a function")

        // Call tree: the root and its call carry the same mark.
        view.setFunctionOrder(.calls)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try cell(list, 0, 0).textField?.stringValue, "Root")
        XCTAssertEqual(try cell(list, 0, 0).iconName, code)
        try XCTUnwrap(all(NSButton.self, in: try cell(list, 0, 0)).first).performClick(nil)
        XCTAssertEqual(try cell(list, 0, 1).textField?.stringValue, "Leaf")
        XCTAssertEqual(try cell(list, 0, 1).iconName, code, "a call is a function too")

        // A search result is not a call of anything on screen.
        view.filter(by: "Leaf")
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.numberOfRows, 1)
        XCTAssertEqual(try cell(list, 0, 0).iconName, code)

        // The grouped order indents its members but they are not calls.
        view.filter(by: "")
        view.setFunctionOrder(.review)
        view.layoutSubtreeIfNeeded()
        let member = try cell(list, 0, 1)
        XCTAssertEqual(member.iconName, code, "a group's member is a function")
        // A heading carries its level's mark.
        let heading = try cell(list, 0, 0)
        XCTAssertTrue(heading.iconName?.hasPrefix("group.") == true)
        XCTAssertNotNil(heading.icon.image)

        // A selected row draws its mark again — on a light plate, keeping its
        // colour — and gives it back when it is let go.
        let plain = member.icon.image
        member.backgroundStyle = .emphasized
        XCTAssertFalse(member.icon.image === plain, "the selection redraws the mark")
        member.backgroundStyle = .normal
        XCTAssertNotNil(member.icon.image)
    }

    /// On a selected row a mark keeps its own colour on a light plate, as a
    /// library badge draws there: the `f` no longer turns white on a coloured
    /// square, which read as another kind of mark on the highlight.
    func testASelectedRowsMarkKeepsItsColourOnALightPlate() throws {
        let side = CodeNavigatorIcon.side(forFontSize: 12)
        let plain = CodeNavigatorIcon.image(.letter("f"), color: .systemTeal, side: side)
        let selected = CodeNavigatorIcon.image(.letter("f"), color: .systemTeal, side: side, inverted: true)
        let middle = (side / 2).rounded(.down)
        // Inside the square, left of the letter's ink.
        let inside = NSPoint(x: 2.5, y: middle)
        let plainInside = try colour(of: plain, at: inside)
        let selectedInside = try colour(of: selected, at: inside)
        XCTAssertEqual(selectedInside.redComponent, plainInside.redComponent, accuracy: 1.0 / 255)
        XCTAssertEqual(selectedInside.greenComponent, plainInside.greenComponent, accuracy: 1.0 / 255)
        XCTAssertEqual(selectedInside.blueComponent, plainInside.blueComponent, accuracy: 1.0 / 255)

        // The plate shows at the edge, as the frame a badge has there.
        let edge = try colour(of: selected, at: NSPoint(x: 0.5, y: middle))
        XCTAssertGreaterThan(edge.redComponent, 0.9)
        XCTAssertGreaterThan(edge.greenComponent, 0.9)
        XCTAssertGreaterThan(edge.blueComponent, 0.9)
    }

    /// The colour `image` draws at `point` in its own coordinates, as sRGB.
    private func colour(of image: NSImage, at point: NSPoint) throws -> NSColor {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                 pixelsWide: Int(image.size.width),
                                                 pixelsHigh: Int(image.size.height),
                                                 bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.colorAt(x: Int(point.x), y: Int(point.y)))
            .usingColorSpace(.sRGB) ?? NSColor.clear
    }

    /// A function's mark says how far its review has got: the filled `f` for
    /// full and for a level without a mark of its own, the framed `f` for
    /// partial in orange and for decompiler only in red, the badge of whose
    /// library it is for a library routine.
    func testAFunctionsMarkFollowsItsReviewLevel() {
        XCTAssertEqual(CodePaneView.functionMark(.full), "function")
        XCTAssertEqual(CodePaneView.functionMark(.partial), "function.partial")
        XCTAssertEqual(CodePaneView.functionMark(.decompiled), "function.decompiled")
        XCTAssertEqual(CodePaneView.functionMark(.library, library: .edk2), "library.edk2")
        XCTAssertEqual(CodePaneView.functionMark(.library, library: .amd), "library.amd")
        XCTAssertEqual(CodePaneView.functionMark(.library, library: .intel), "library.intel")
        XCTAssertEqual(CodePaneView.functionMark(.library), "library.unrecorded")
        XCTAssertEqual(CodePaneView.functionMark(.library, library: .amd, registry: .entry), "library.amd.entry")
        XCTAssertEqual(CodePaneView.functionMark(.library, library: .amd, registry: .matched), "library.amd.matched")
        XCTAssertEqual(CodePaneView.functionMark(.noBody), "function.noBody")
        XCTAssertEqual(CodePaneView.functionMark(.unknown), "function")

        // The two framed marks read apart by their colour alone: an `f` in a
        // frame either way, orange for a review under way, red for one that
        // has not gone past the decompiler.
        XCTAssertEqual(CodeNavigatorIcon.partialFunction.glyph, .framedLetter("f"))
        XCTAssertEqual(CodeNavigatorIcon.decompiledFunction.glyph, .framedLetter("f"))
        XCTAssertEqual(CodeNavigatorIcon.partialFunction.color, .systemOrange)
        XCTAssertEqual(CodeNavigatorIcon.decompiledFunction.color, .systemRed)

        // A function with no body takes the group heading's grey, in the frame
        // the other two levels' marks wear.
        XCTAssertEqual(CodeNavigatorIcon.bodylessFunction.glyph, .framedLetter("f"))
        XCTAssertEqual(CodeNavigatorIcon.bodylessFunction.color, .systemGray)
        XCTAssertEqual(CodeNavigatorIcon.group(.noBody).color, .systemGray)
    }

    /// The library heading's sign is a building with columns — the classical
    /// form where SF Symbols has it, the plain columned building where it does
    /// not, and a name the running macOS resolves either way.
    func testTheLibraryHeadingDrawsAColumnedBuilding() {
        XCTAssertNotNil(NSImage(systemSymbolName: CodeNavigatorIcon.libraryGroupSymbol,
                                accessibilityDescription: nil))
        let mark = CodeNavigatorIcon.group(.library)
        XCTAssertEqual(mark.glyph, .symbol(CodeNavigatorIcon.libraryGroupSymbol))
        XCTAssertEqual(mark.color, .systemBlue)
    }

    /// Every open group's chevron in the panel's list points down, whichever
    /// group it is and however the row was configured.
    func testEveryOpenGroupsChevronPointsTheSameWay() throws {
        let suiteName = "CodePaneViewTests.groupChevrons"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        let art = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":8,"program":{"image_base":"0x0"},
         "functions":[
          {"entry":"0x100","name":"Done","review_level":"full","instructions":[]},
          {"entry":"0x200","name":"Partly","review_level":"partial",
           "review_gaps":["plate"],"instructions":[]},
          {"entry":"0x300","name":"FUN_00000300","review_level":"decompiled","instructions":[]}]}
        """.utf8))
        let view = CodePaneView(manifest: manifest(), artifact: art,
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        view.setFunctionOrder(.review)
        view.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(all(NSTableView.self, in: view).first {
            $0.tableColumns.contains { $0.identifier.rawValue == "function" }
        })
        var turns: [(String, CGAffineTransform, CGFloat)] = []
        for row in 0..<list.numberOfRows {
            // A row on demand, as scrolling asks for one: the rows that came
            // out of configuration turned one way and the row asked for later
            // the other, which is what the reader saw as groups open upward.
            guard let cell = list.view(atColumn: 0, row: row, makeIfNecessary: true)
                    as? CodeNavigatorCell,
                  let name = cell.iconName, name.hasPrefix("group."),
                  cell.window != nil else { continue }
            let button = cell.disclosure
            let zero = button.convert(CGPoint(x: 0, y: 0), to: nil)
            let one = button.convert(CGPoint(x: 0, y: 1), to: nil)
            let expected: CGFloat = one.y < zero.y ? 1 : -1   // sin of the quarter turn
            turns.append((name, button.chevronTurn, expected))
        }
        XCTAssertEqual(turns.count, 3, "three groups are open")
        for (name, turn, expected) in turns {
            XCTAssertFalse(turn.isIdentity, "\(name) is open and turned")
            XCTAssertEqual(turn, turns[0].1, "\(name) turns the way the first group does")
            XCTAssertEqual(turn.b, expected, accuracy: 0.0001,
                           "\(name) turns the way its row is drawn, so its point is down")
        }
    }

    /// An open row's chevron points down, and a row configured while it is
    /// out of the table turns it the same way: a layer out of a window
    /// answers `contentsAreFlipped` with yes whatever its table would say,
    /// and a reused row is configured out of the table.
    func testAChevronTurnsTheSameOutOfTheTableAsInIt() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let document = FlippedTestView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = document
        // The layer answers about its flip only in a window that is on screen,
        // which is where the panel draws its rows.
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        let button = CodeDisclosureButton(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        document.addSubview(button)
        button.needsLayout = true
        button.layoutSubtreeIfNeeded()
        button.setOpen(true, animated: false)
        let inTheTable = button.chevronTurn
        XCTAssertFalse(inTheTable.isIdentity, "an open chevron is turned from the `>` it is drawn as")

        button.removeFromSuperview()
        button.setOpen(true, animated: false)
        button.needsLayout = true
        button.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.chevronTurn, inTheTable, "a row out of the table turns it the same way")

        button.setOpen(false, animated: false)
        XCTAssertTrue(button.chevronTurn.isIdentity, "a closed chevron points right")
    }

    /// A library function the registry holds says so on its badge — filled
    /// for the entry, dotted when matched otherwise — in its hover and on the
    /// header beside its name, and its kind says how many it holds.
    func testTheLibraryRegistryShowsOnTheBadgeTheHoverAndTheHeader() throws {
        let suiteName = "CodePaneViewTests.registry"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        let art = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":9,"program":{"image_base":"0x0"},
         "functions":[
          {"entry":"0x100","name":"CopyGuid","review_level":"library","library_kind":"edk2",
           "library_entry":{"id":"a-1","version":3,"state":"entry"},"instructions":[]},
          {"entry":"0x200","name":"CopyMem","review_level":"library","library_kind":"edk2",
           "library_entry":{"id":"b-1","version":2,"state":"differs","differences":["plate"]},"instructions":[]},
          {"entry":"0x300","name":"ZeroMem","review_level":"library","library_kind":"edk2","instructions":[]},
          {"entry":"0x400","name":"ReadSmn","review_level":"library","library_kind":"amd",
           "library_entry":{"id":"c-1","version":1,"state":"entry","codes":["0x10199"]},"instructions":[]}]}
        """.utf8))
        let view = CodePaneView(manifest: manifest(), artifact: art,
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.setFunctionOrder(.review)
        view.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(all(NSTableView.self, in: view).first {
            $0.tableColumns.contains { $0.identifier.rawValue == "function" }
        })
        func cell(_ row: Int) throws -> CodeNavigatorCell {
            try XCTUnwrap(list.view(atColumn: 0, row: row, makeIfNecessary: true) as? CodeNavigatorCell)
        }
        // Library functions, EDK2 — CopyGuid, CopyMem, ZeroMem — then AMD.
        XCTAssertEqual(try cell(1).textField?.stringValue, "EDK2 (3, 1 in the registry)")
        XCTAssertEqual(try cell(2).iconName, "library.edk2.entry")
        XCTAssertEqual(try cell(3).iconName, "library.edk2.matched")
        XCTAssertEqual(try cell(4).iconName, "library.edk2")
        // Every function of the kind is the registry's entry: the badge there is
        // the entry's own, filled, and the count says it in words.
        XCTAssertEqual(try cell(5).textField?.stringValue, "AMD AGESA (1 all in registry)")
        XCTAssertEqual(try cell(5).iconName, "library.amd.entry")
        XCTAssertTrue(try cell(2).toolTip?.contains("Library registry entry, version 3") == true)
        XCTAssertTrue(try cell(3).toolTip?.contains(
            "Matches library registry entry version 2; this module's review differs: plate") == true)
        XCTAssertFalse(try cell(4).toolTip?.contains("registry") == true)
        XCTAssertTrue(try cell(6).toolTip?.contains("A variant: assert codes 0x10199") == true)

        view.selectFunction(at: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.registryMark.isHidden, "the header carries the badge of a library function")
        XCTAssertEqual(view.registryMark.toolTip, "Library registry entry, version 3")
        view.selectFunction(at: 2)
        XCTAssertEqual(view.registryMark.toolTip, "Library function: EDK2. The library registry does not hold it.")
    }

    /// A revision the panel receives marks the functions it changed: they read
    /// bold with a New badge, and the mark is taken by moving off the function,
    /// not by arriving at it.
    func testARevisionMarksChangedFunctionsUntilTheReaderMovesOn() throws {
        let suiteName = "CodePaneViewTests.revisionMarks"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        view.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(all(NSTableView.self, in: view).first {
            $0.tableColumns.contains { $0.identifier.rawValue == "function" }
        })
        let nameColumn = try XCTUnwrap(list.tableColumns.firstIndex {
            $0.identifier.rawValue == "function"
        })
        func cell(_ row: Int) throws -> NSTableCellView {
            try XCTUnwrap(list.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? NSTableCellView)
        }
        func isBold(_ cell: NSTableCellView) -> Bool {
            guard let font = cell.textField?.font else { return false }
            return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }
        func badge(_ cell: NSTableCellView) -> PartBadgeView? {
            all(PartBadgeView.self, in: cell).first
        }

        XCTAssertFalse(isBold(try cell(1)), "nothing changed yet")
        XCTAssertTrue(badge(try cell(1))?.isHidden ?? true)

        let previous = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":2,"ghidra":"12.1.2","program":{"image_base":"0x0"},
         "strings":[{"address":"0x220","type":"string","value":"ABC"}],
         "post_codes":[{"address":"0x221","function":"0x220","port":"0x80","text":"OUT 0x80, AL"}],
         "status_code_calls":[{"address":"0x222","function":"0x220","text":"call [ebx+0x10]","context":["ReportStatusCode"]}],
         "functions":[
          {"entry":"0x220","name":"FUN_00000220","callers":["0x355"],"callees":["0x355"],"instructions":[
            {"address":"0x220","bytes":"56","mnemonic":"PUSH","text":"PUSH ESI"},
            {"address":"0x221","bytes":"57","mnemonic":"PUSH","text":"PUSH EDI"}]},
          {"entry":"0x355","name":"entry","c":"return 1;","instructions":[
            {"address":"0x355","bytes":"8B 54 24 08","mnemonic":"MOV","text":"MOV EDX,dword ptr [ESP + 0x8]"}]}
         ]}
        """.utf8))
        view.markRevisionChange(from: previous)

        let changed = try cell(1)
        XCTAssertTrue(isBold(changed), "a changed function reads bold")
        XCTAssertEqual(badge(changed)?.text, "New")
        XCTAssertFalse(badge(changed)?.isHidden ?? true, "and carries the New badge")
        XCTAssertFalse(isBold(try cell(0)), "a function the revision left alone does not")

        // On a selected row the badge keeps its word white, as a dock pill's
        // does: the accent on the selection's own colour does not read.
        changed.backgroundStyle = .emphasized
        XCTAssertEqual(badge(changed)?.ink, .alternateSelectedControlTextColor)
        changed.backgroundStyle = .normal
        XCTAssertEqual(badge(changed)?.ink, .controlAccentColor)

        view.selectFunction(at: 1)
        let arrived = try cell(1)
        XCTAssertTrue(isBold(arrived), "arriving at it does not take the mark")
        XCTAssertEqual(badge(arrived)?.text, "New")

        view.selectFunction(at: 0)
        let left = try cell(1)
        XCTAssertFalse(isBold(left), "moving off it takes the mark")
        XCTAssertTrue(badge(left)?.isHidden ?? true)
    }

    /// Diff shows the C of the function on screen against the earlier
    /// revision's: what the revision removed on red, what it added on green,
    /// and the lines both keep as they were — with the two line numbers.
    func testTheDiffShowsWhatTheRevisionChanged() throws {
        let suiteName = "CodePaneViewTests.diff"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        func artifact(_ c: String) throws -> CodeArtifact {
            try JSONDecoder().decode(CodeArtifact.self, from: Data("""
            {"script_version":2,"program":{"image_base":"0x0"},
             "functions":[{"entry":"0x220","name":"F","c":\(String(data: try JSONSerialization.data(withJSONObject: c, options: .fragmentsAllowed), encoding: .utf8)!) ,
                           "instructions":[{"address":"0x220","bytes":"C3","mnemonic":"RET","text":"RET"}]}]}
            """.utf8))
        }
        let previous = try artifact("void F(void)\n{\n  A();\n}\n")
        let current = try artifact("void F(void)\n{\n  B();\n}\n")
        let view = CodePaneView(manifest: manifest(), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.canShowRevisionDiff, "nothing to compare with yet")
        XCTAssertFalse(view.showsRevisionDiff)

        view.markRevisionChange(from: previous, revision: 66)
        XCTAssertTrue(view.canShowRevisionDiff)
        view.setComparisonRevision(66, artifact: previous)
        XCTAssertTrue(view.showsRevisionDiff, "the C side shows the comparison at once")
        XCTAssertEqual(view.diffCounts?.added, 1)
        XCTAssertEqual(view.diffCounts?.removed, 1)
        let shown = view.diffText
        XCTAssertTrue(shown.contains("-   A();"), shown)
        XCTAssertTrue(shown.contains("+   B();"), shown)
        XCTAssertTrue(shown.contains("void F(void)"), shown)
        func components(_ color: NSColor?) -> [CGFloat]? {
            color?.usingColorSpace(.sRGB).map { [$0.redComponent, $0.greenComponent, $0.blueComponent] }
        }
        XCTAssertEqual(components(view.diffBackground(ofLineContaining: "-   A();")),
                       components(CodeColors.diffRemoved))
        XCTAssertEqual(components(view.diffBackground(ofLineContaining: "+   B();")),
                       components(CodeColors.diffAdded))
        XCTAssertNil(view.diffBackground(ofLineContaining: "void F(void)"), "an unchanged line is not tinted")
        // The code in the diff is the artifact's own, drawn by its tokens.
        XCTAssertEqual(components(view.diffInk(ofWord: "void")), components(CodeColors.type))
        XCTAssertEqual(components(view.diffInk(ofWord: "F(void)")), components(CodeColors.function))

        // The comparison is the C side's alone: the listing is this revision's.
        view.showDecompiledC(false)
        XCTAssertFalse(view.showsRevisionDiff, "no comparison in the listing")
        view.showDecompiledC(true)
        XCTAssertTrue(view.showsRevisionDiff, "and it is back with the C")

        view.setComparisonRevision(nil, artifact: nil)
        XCTAssertFalse(view.showsRevisionDiff)
        XCTAssertTrue(view.showsDecompiledC, "back to the code this revision's")

        // A function the revision changed is the one its change is about:
        // opening it puts the comparison with the revision before back on.
        view.selectFunction(at: 0)
        XCTAssertEqual(view.comparisonRevision, 66)
        XCTAssertTrue(view.showsRevisionDiff, "the change of this function, without a pick")
    }

    /// Another function's diff is read from its top. A short function opened
    /// where a long one was left arrived scrolled past its end — the pane
    /// looked empty until the reader scrolled, and then showed the function
    /// from above.
    func testTheDiffOfAnotherFunctionStartsAtItsTop() throws {
        func artifact(_ long: String, _ short: String) throws -> CodeArtifact {
            let json: [String: Any] = [
                "script_version": 2, "program": ["image_base": "0x0"],
                "functions": [
                    ["entry": "0x100", "name": "Long", "c": long,
                     "instructions": [["address": "0x100", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]],
                    ["entry": "0x200", "name": "Short", "c": short,
                     "instructions": [["address": "0x200", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]
                ]
            ]
            return try JSONDecoder().decode(CodeArtifact.self,
                                            from: JSONSerialization.data(withJSONObject: json))
        }
        let longBody = (1...60).map { "  Step\($0)();\n" }.joined()
        let current = try artifact("void Long(void)\n{\n" + longBody + "}\n",
                                   "void Short(void)\n{\n  A();\n}\n")
        let baseline = try artifact("void Long(void)\n{\n" + longBody + "  Old();\n}\n",
                                    "void Short(void)\n{\n  B();\n}\n")
        let view = CodePaneView(manifest: manifest(), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        view.layoutSubtreeIfNeeded()
        view.setComparisonRevision(54, artifact: baseline, pinned: true)

        view.selectFunction(at: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.showsRevisionDiff)
        view.diffScrollOrigin = NSPoint(x: 0, y: 400)
        XCTAssertEqual(view.diffScrollOrigin.y, 400, "the long function's diff is scrolled down")

        view.selectFunction(at: 1)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.showsRevisionDiff, "the short function differs too")
        XCTAssertEqual(view.diffScrollOrigin, .zero, "another function's diff is read from its top")
        XCTAssertTrue(view.diffText.contains("void Short(void)"), view.diffText)
    }

    private func artifactForLines(_ long: String, _ short: String) throws -> CodeArtifact {
        let json: [String: Any] = [
            "script_version": 2, "program": ["image_base": "0x0"],
            "functions": [
                ["entry": "0x100", "name": "Long", "c": long,
                 "instructions": [["address": "0x100", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]],
                ["entry": "0x200", "name": "Short", "c": short,
                 "instructions": [["address": "0x200", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]
            ]
        ]
        return try JSONDecoder().decode(CodeArtifact.self,
                                        from: JSONSerialization.data(withJSONObject: json))
    }

    /// Each function keeps the line it was left at and is read again from it,
    /// whichever function came in between.
    func testAFunctionIsReadFromTheLineItWasLeftAt() throws {
        let longBody = (1...60).map { "  Step\($0)();\n" }.joined()
        let shortBody = (1...30).map { "  Small\($0)();\n" }.joined()
        let current = try artifactForLines("void Long(void)\n{\n" + longBody + "}\n",
                                           "void Short(void)\n{\n" + shortBody + "}\n")
        let view = CodePaneView(manifest: manifest(), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        view.layoutSubtreeIfNeeded()

        view.selectFunction(at: 0)
        view.layoutSubtreeIfNeeded()
        view.scrollCForTest(toLine: 20)
        XCTAssertEqual(view.topLinePositions["0x100"], 20, "the C is read from line 20")

        view.selectFunction(at: 1)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.topLinePositions["0x100"], 20, "kept while another function is read")
        XCTAssertEqual(view.topLinePositions["0x200"], 0, "a function never read opens at its top")

        view.selectFunction(at: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.topLinePositions["0x100"], 20, "read again from the line it was left at")
    }

    /// A line the function no longer has — it came back shorter — shows its
    /// last part instead of an empty view below the text.
    func testALinePastAShorterFunctionsEndShowsItsLastPart() throws {
        let longBody = (1...60).map { "  Step\($0)();\n" }.joined()
        let shortBody = (1...30).map { "  Small\($0)();\n" }.joined()
        let current = try artifactForLines("void Long(void)\n{\n" + longBody + "}\n",
                                           "void Short(void)\n{\n" + shortBody + "}\n")
        let view = CodePaneView(manifest: manifest(), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        view.layoutSubtreeIfNeeded()

        view.restoreTopLines(["0x200": 500])
        view.selectFunction(at: 1)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.cMaxScroll, 0, "the function is taller than the view")
        XCTAssertEqual(view.cScrollOrigin.y, view.cMaxScroll, accuracy: 0.5,
                       "the bottom of the function is shown")
    }

    /// The line kept is the new revision's line, so a comparison opens the
    /// function at the line the C would call its own.
    func testAComparisonOpensAtTheLineTheCodeWasLeftAt() throws {
        let longBody = (1...60).map { "  Step\($0)();\n" }.joined()
        let current = try artifactForLines("void Long(void)\n{\n" + longBody + "}\n",
                                           "void Short(void)\n{\n  A();\n}\n")
        let baseline = try artifactForLines("void Long(void)\n{\n" + longBody + "  Old();\n}\n",
                                            "void Short(void)\n{\n  B();\n}\n")
        let view = CodePaneView(manifest: manifest(), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        view.layoutSubtreeIfNeeded()
        view.setComparisonRevision(54, artifact: baseline, pinned: true)

        view.restoreTopLines(["0x100": 30])
        view.selectFunction(at: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.showsRevisionDiff)
        XCTAssertEqual(view.topLinePositions["0x100"], 30,
                       "the comparison opens at line 30 of the code")
    }

    private func oneFunction(name: String, signature: String, c: String?,
                             entry: String = "0x220") throws -> CodeArtifact {
        var function: [String: Any] = [
            "entry": entry, "name": name, "signature": signature,
            "instructions": [["address": entry, "bytes": "C3", "mnemonic": "RET", "text": "RET"]]
        ]
        if let c { function["c"] = c }
        return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: [
            "script_version": 2, "program": ["image_base": "0x0"], "functions": [function]
        ]))
    }

    /// The plate over the code says what the mark is about besides the code:
    /// another name and signature, while the code itself reads the same — the
    /// case the comparison has nothing to show.
    func testThePlateSaysWhatChangedBesidesTheCode() throws {
        let before = try oneFunction(name: "FUN_0012AB40", signature: "void FUN_0012AB40(void)",
                                     c: "{\n  A();\n}")
        let after = try oneFunction(name: "PspSmmFatalError",
                                    signature: "void PspSmmFatalError(UINT32 ErrorCode)",
                                    c: "{\n  A();\n}")
        let view = CodePaneView(manifest: manifest(), artifact: after,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        view.markRevisionChange(from: before, revision: 23)
        view.selectFunction(at: 0)

        XCTAssertTrue(view.newBannerIsShown)
        XCTAssertEqual(view.newBannerTitle, "New against r23")
        XCTAssertEqual(view.newBannerBullets, [
            "Renamed: FUN_0012AB40 → PspSmmFatalError",
            "Signature: void FUN_0012AB40(void) → void PspSmmFatalError(UINT32 ErrorCode)",
            "The code reads the same in both revisions, so the comparison has nothing to show."
        ])
        XCTAssertFalse(view.showsRevisionDiff, "the comparison has nothing to draw")
        XCTAssertTrue(view.newBannerWordsAreSelectable, "the notice can be selected and copied")
        XCTAssertEqual(view.newBannerWordFontPoints, [12],
                       "the field editor keeps the words at their size when one is selected")
    }

    /// A function whose only difference is its code needs no plate: the
    /// comparison is the explanation.
    func testACodeOnlyChangeNeedsNoPlate() throws {
        let before = try oneFunction(name: "F", signature: "void F(void)", c: "{\n  A();\n}")
        let after = try oneFunction(name: "F", signature: "void F(void)", c: "{\n  B();\n}")
        let view = CodePaneView(manifest: manifest(), artifact: after,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        view.markRevisionChange(from: before, revision: 23)
        view.selectFunction(at: 0)
        XCTAssertFalse(view.newMarks.isEmpty, "the code changed, so the function is New")
        XCTAssertTrue(view.showsRevisionDiff)
        XCTAssertFalse(view.newBannerIsShown, "the diff says it, the plate would repeat it")
    }

    /// A function the revision added says so, in one line.
    func testThePlateSaysAFunctionWasAdded() throws {
        let before = try oneFunction(name: "G", signature: "void G(void)", c: "{\n}", entry: "0x260")
        let after = try oneFunction(name: "F", signature: "void F(void)", c: "{\n}", entry: "0x220")
        let view = CodePaneView(manifest: manifest(), artifact: after,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        view.markRevisionChange(from: before, revision: 23)
        view.selectFunction(at: 0)
        XCTAssertEqual(view.newBannerBullets, ["The function is not in r23: this revision added it."])
    }

    /// A record made against another copy of the revision leaves the same
    /// code, the same name and the same signature on both sides: nothing
    /// changed, so nothing is marked, and the reader is taken to be as far
    /// along as the code is.
    func testARecordMadeAgainstAnotherCopyMarksNothing() throws {
        let current = try oneFunction(name: "F", signature: "void F(void)", c: "{\n  A();\n}")
        let view = CodePaneView(manifest: manifest(revision: 54), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        view.selectFunction(at: 0)
        view.restoreSeen(["0x220": SeenRecord(revision: 53, fingerprint: "another copy")],
                         baselines: [53: current])

        XCTAssertTrue(view.newMarks.isEmpty, "nothing changed, so nothing is new")
        XCTAssertEqual(view.seenRecords["0x220"]?.revision, 54,
                       "the record moves on with the code")
        XCTAssertFalse(view.newBannerIsShown)
    }

    /// A function with no record of its own was never opened — the review
    /// made it after the records were begun. It is New against the newest
    /// kept revision that does not read as it does now, and the plate says
    /// why: the newest of them all is usually the one on screen, and New
    /// against itself is a mark with no comparison and nothing to say.
    func testAFunctionWithNoRecordIsNewAgainstARevisionThatDiffers() throws {
        let current = try oneFunction(name: "F", signature: "void F(void)", c: "{\n  A();\n}")
        let older = try oneFunction(name: "G", signature: "void G(void)", c: "{\n}", entry: "0x260")
        let view = CodePaneView(manifest: manifest(revision: 113), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        view.selectFunction(at: 0)
        view.restoreSeen(["0x260": SeenRecord(revision: 108, fingerprint: "the other function")],
                         baselines: [113: current, 108: older])

        XCTAssertEqual(view.newMarks.map(\.baseline.revision), [108], "not against itself")
        XCTAssertTrue(view.newBannerIsShown)
        XCTAssertEqual(view.newBannerBullets, ["The function is not in r108: this revision added it."])
    }

    /// A function with no record that reads the same in every kept revision
    /// has changed against nothing the panel can show: no mark, and the record
    /// starts where the code is.
    func testAFunctionWithNoRecordReadingTheSameEverywhereIsNotNew() throws {
        let current = try oneFunction(name: "F", signature: "void F(void)", c: "{\n  A();\n}")
        let view = CodePaneView(manifest: manifest(revision: 113), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        view.selectFunction(at: 0)
        view.restoreSeen(["0x260": SeenRecord(revision: 113, fingerprint: "the other function")],
                         baselines: [113: current])

        XCTAssertTrue(view.newMarks.isEmpty, "New against itself says nothing")
        XCTAssertEqual(view.seenRecords["0x220"]?.revision, 113)
        XCTAssertFalse(view.newBannerIsShown)
    }

    /// A mark carried from the pane before whose revision reads as the code
    /// does now — changed and changed back — has nothing to compare, and does
    /// not take the place of one that has.
    func testACarriedMarkWhoseRevisionReadsTheSameIsDropped() throws {
        let current = try oneFunction(name: "F", signature: "void F(void)", c: "{\n  A();\n}")
        let between = try oneFunction(name: "F", signature: "void F(void)", c: "{\n  B();\n}")
        let view = CodePaneView(manifest: manifest(revision: 3), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        view.setNewMarks([.init(entry: current.functions[0].entry,
                                baseline: .init(revision: 1, artifact: current))])
        XCTAssertTrue(view.newMarks.isEmpty, "the code is back where the mark began")

        view.markRevisionChange(from: between, revision: 2)
        view.setNewMarks([.init(entry: current.functions[0].entry,
                                baseline: .init(revision: 1, artifact: current))])
        XCTAssertEqual(view.newMarks.map(\.baseline.revision), [2], "the real change stays")
    }

    /// The button in the bar takes every mark at once, as leaving each function
    /// would: the rows, the comparison a mark put up and the plate go, and the
    /// next launch does not put them up again. With nothing to clear it is dim.
    func testTheBarsButtonClearsEveryNewMark() throws {
        let before = try oneFunction(name: "F", signature: "void F(void)", c: "{\n  A();\n}")
        let after = try oneFunction(name: "F2", signature: "void F2(void)", c: "{\n  B();\n}")
        let view = CodePaneView(manifest: manifest(revision: 54), artifact: after,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.clearNewMarksButton.isEnabled, "nothing wears the mark yet")
        var kept: [String: SeenRecord] = [:]
        view.onSeenChanged = { kept = $0 }
        view.restoreSeen(["0x220": SeenRecord(revision: 53, fingerprint: "the code as it read")],
                         baselines: [53: before])
        view.selectFunction(at: 0)
        XCTAssertFalse(view.newMarks.isEmpty)
        XCTAssertTrue(view.clearNewMarksButton.isEnabled)
        XCTAssertEqual(view.comparisonRevision, 53)
        XCTAssertTrue(view.newBannerIsShown)

        view.clearNewMarksButton.performClick(nil)

        XCTAssertTrue(view.newMarks.isEmpty)
        XCTAssertFalse(view.clearNewMarksButton.isEnabled)
        XCTAssertNil(view.comparisonRevision, "the mark's comparison goes with it")
        XCTAssertFalse(view.newBannerIsShown)
        XCTAssertEqual(kept["0x220"]?.revision, 54)

        let next = CodePaneView(manifest: manifest(revision: 54), artifact: after,
                                moduleBytes: teModule(), hexView: NSView())
        next.restoreSeen(kept, baselines: [54: after])
        XCTAssertTrue(next.newMarks.isEmpty, "the next launch does not put them up again")
    }

    /// Marks cleared while the last launch's records are still on their way
    /// stay cleared when the records come.
    func testClearingBeforeTheRecordsArriveHolds() throws {
        let before = try oneFunction(name: "F", signature: "void F(void)", c: "{\n  A();\n}")
        let after = try oneFunction(name: "F", signature: "void F(void)", c: "{\n  B();\n}")
        let view = CodePaneView(manifest: manifest(revision: 54), artifact: after,
                                moduleBytes: teModule(), hexView: NSView())
        view.markRevisionChange(from: before, revision: 53)
        view.clearNewMarks()
        view.restoreSeen(["0x220": SeenRecord(revision: 53, fingerprint: "the code as it read")],
                         baselines: [53: before])
        XCTAssertTrue(view.newMarks.isEmpty)
        XCTAssertEqual(view.seenRecords["0x220"]?.revision, 54)
    }

    /// The button goes with the Functions list, as the layouts beside it do.
    func testTheClearButtonGoesWithTheFunctionsList() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.clearNewMarksButton.isHidden)
        view.selectList(.strings)
        XCTAssertTrue(view.clearNewMarksButton.isHidden)
    }

    /// A comparison put up before the store's list arrives — a New mark's —
    /// keeps its place in the bar when the list comes, and is named even when
    /// the list does not hold it; a list that does hold it keeps the choice.
    func testAComparisonStaysNamedWhenTheRevisionListArrives() throws {
        func artifact(_ c: String) throws -> CodeArtifact {
            try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: [
                "script_version": 2, "program": ["image_base": "0x0"],
                "functions": [["entry": "0x220", "name": "F", "c": c,
                               "instructions": [["address": "0x220", "bytes": "C3",
                                                 "mnemonic": "RET", "text": "RET"]]]]
            ]))
        }
        let current = try artifact("void F(void)\n{\n  B();\n}\n")
        let previous = try artifact("void F(void)\n{\n  A();\n}\n")
        let view = CodePaneView(manifest: manifest(), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()

        // The mark puts the comparison up first; the history arrives after it.
        view.markRevisionChange(from: previous, revision: 54)
        view.selectFunction(at: 0)
        XCTAssertTrue(view.showsRevisionDiff)
        view.setRevisionChoices([CodePaneView.RevisionChoice(revision: 55, title: "r55", hasCode: true)],
                                current: 56)
        XCTAssertEqual(view.selectedRevisionTitle, "r54", "the bar still names what the diff shows")
        XCTAssertTrue(view.revisionChoiceTitles.contains("r54"), view.revisionChoiceTitles.joined(separator: ", "))

        // A revision the list holds is chosen again when the list is rebuilt.
        view.setComparisonRevision(55, artifact: previous, pinned: true)
        view.setRevisionChoices([CodePaneView.RevisionChoice(revision: 55, title: "r55 — the list", hasCode: true)],
                                current: 56)
        XCTAssertEqual(view.selectedRevisionTitle, "r55 — the list")
    }

    /// The dump bar's picker lists the module's revisions the app read, says
    /// which one the code is compared against, and Reset clears it — as
    /// Xcode's bar does for a file's history.
    func testTheDumpBarComparesWithARevisionChosen() throws {
        func artifact(_ c: String) throws -> CodeArtifact {
            let json: [String: Any] = [
                "script_version": 2, "program": ["image_base": "0x0"],
                "functions": [["entry": "0x220", "name": "F", "c": c,
                               "instructions": [["address": "0x220", "bytes": "C3",
                                                 "mnemonic": "RET", "text": "RET"]]]]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let view = CodePaneView(manifest: manifest(), artifact: try artifact("void F(void)\n{\n  B();\n}\n"),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.comparisonIsHidden, "nothing read yet, nothing to compare with")
        XCTAssertFalse(view.canShowRevisionDiff)

        view.setRevisionChoices([
            .init(revision: 54, title: "r54 — 31.10.2026, agent", hasCode: true),
            .init(revision: 53, title: "r53 — 30.10.2026, agent", hasCode: false)
        ], current: 55)
        XCTAssertFalse(view.comparisonIsHidden)
        XCTAssertEqual(view.revisionChoiceTitles,
                       ["No comparison", "r54 — 31.10.2026, agent", "r53 — 30.10.2026, agent"])
        // A menu would enable every item with a target of its own; a revision
        // with no code in the store is listed greyed and cannot be picked.
        XCTAssertEqual(view.revisionChoiceIsEnabled(54), true)
        XCTAssertEqual(view.revisionChoiceIsEnabled(53), false, "the store holds no code for it")
        XCTAssertFalse(view.revisionPickerIsBordered, "the picker sits on the bar, as Xcode's does")
        // Reset stays where it is, enabled only while there is something to
        // reset: a control that comes and goes moves the picker under the
        // pointer.
        XCTAssertFalse(view.comparisonResetIsHidden)
        XCTAssertFalse(view.comparisonResetIsEnabled)
        XCTAssertEqual(view.comparisonResetTint, .secondaryLabelColor, "grey while it cannot act")

        var chosen: [Int?] = []
        view.onChooseRevision = { chosen.append($0) }
        view.chooseRevisionMenuTag(54)
        XCTAssertEqual(chosen, [54], "the app is asked for that revision's code")
        view.chooseRevisionMenuTag(-1)
        XCTAssertEqual(chosen, [54, nil], "and for none when Reset is picked")

        view.setComparisonRevision(54, artifact: try artifact("void F(void)\n{\n  A();\n}\n"))
        XCTAssertTrue(view.canShowRevisionDiff)
        XCTAssertTrue(view.comparisonResetIsEnabled, "something to reset now")
        XCTAssertEqual(view.comparisonResetTint, .controlAccentColor, "and blue while it can")
        XCTAssertTrue(view.showsRevisionDiff, "the comparison is on as soon as it is chosen")
        XCTAssertTrue(view.diffText.contains("-   A();"), view.diffText)

        view.setComparisonRevision(nil, artifact: nil)
        XCTAssertFalse(view.canShowRevisionDiff, "Reset leaves nothing to compare with")
        XCTAssertFalse(view.comparisonResetIsEnabled, "and nothing to reset again")
        XCTAssertFalse(view.comparisonResetIsHidden, "the button itself stays")
        XCTAssertEqual(view.comparisonResetTint, .secondaryLabelColor)

        // A module whose history holds no comparable revision keeps the bar
        // where the reader expects it, with nothing to pick yet.
        view.setRevisionChoices([], current: 55, knowsRevisions: true)
        XCTAssertFalse(view.comparisonIsHidden, "the history is there, so the bar is")
        XCTAssertEqual(view.revisionChoiceTitles, ["No comparison"])
        XCTAssertFalse(view.comparisonResetIsEnabled)
        XCTAssertFalse(view.showsRevisionDiff, "and the code comes back")
    }

    /// The revision picker is borderless and draws a rounded plate under the
    /// pointer, as Xcode's bar does.
    func testTheRevisionPickerLightsUnderThePointer() {
        let popup = CodeRevisionPopup(frame: .zero, pullsDown: false)
        XCTAssertFalse(popup.showsPlate)
        popup.setPointerOnIt(true)
        XCTAssertTrue(popup.showsPlate)
        popup.setPointerOnIt(false)
        XCTAssertFalse(popup.showsPlate)
    }

    /// A New mark outlives the revisions that follow it: it keeps the revision
    /// it was new against, opening the function compares with that one rather
    /// than with whatever came after, and the mark travels into the pane drawn
    /// after the next revision.
    func testANewMarkKeepsTheRevisionItWasNewAgainst() throws {
        func artifact(_ c: String) throws -> CodeArtifact {
            let json: [String: Any] = [
                "script_version": 2, "program": ["image_base": "0x0"],
                "functions": [["entry": "0x220", "name": "F", "c": c,
                               "instructions": [["address": "0x220", "bytes": "C3",
                                                 "mnemonic": "RET", "text": "RET"]]]]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let a = try artifact("void F(void)\n{\n  A();\n}\n")
        let b = try artifact("void F(void)\n{\n  B();\n}\n")
        let c = try artifact("void F(void)\n{\n  C();\n}\n")
        let view = CodePaneView(manifest: manifest(), artifact: c, moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        view.markRevisionChange(from: b, revision: 54)
        view.markRevisionChange(from: a, revision: 53)
        XCTAssertEqual(view.newMarks.count, 1)
        XCTAssertEqual(view.newMarks.first?.baseline.revision, 54,
                       "the earliest revision it was new against stays the mark's")

        view.selectFunction(at: 0)
        XCTAssertEqual(view.comparisonRevision, 54, "opening it compares with that revision")
        XCTAssertTrue(view.showsRevisionDiff)

        // The next revision changes nothing here: the fresh pane marks no
        // function, and the mark carried from the last pane is what shows.
        let next = CodePaneView(manifest: manifest(), artifact: c, moduleBytes: teModule(), hexView: NSView())
        next.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        next.layoutSubtreeIfNeeded()
        next.markRevisionChange(from: b, revision: 55)
        XCTAssertEqual(next.newMarks.first?.baseline.revision, 55, "the fresh pane marks the change at 55")
        next.setNewMarks(view.newMarks)
        XCTAssertEqual(next.newMarks.first?.baseline.revision, 54,
                       "and the mark carried from before keeps the earlier revision it was new against")

        // A revision the reader picks in the bar is theirs: it holds, and an
        // open mark does not take it away.
        next.selectFunction(at: 0)
        XCTAssertEqual(next.comparisonRevision, 54)
        next.setComparisonRevision(55, artifact: b, pinned: true)
        XCTAssertEqual(next.comparisonRevision, 55, "the reader's pick holds")
        XCTAssertTrue(next.showsRevisionDiff)
    }

    /// A revision that changed a function while the app was closed still puts
    /// it up as New: every function keeps the revision it was last seen at,
    /// and the ones that read otherwise than they did then are marked against
    /// that revision — with its code for the comparison.
    func testAFunctionChangedWhileTheAppWasClosedComesUpNew() throws {
        func artifact(_ f: String, _ g: String) throws -> CodeArtifact {
            let json: [String: Any] = [
                "script_version": 2, "program": ["image_base": "0x0"],
                "functions": [
                    ["entry": "0x220", "name": "F", "c": f,
                     "instructions": [["address": "0x220", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]],
                    ["entry": "0x260", "name": "G", "c": g,
                     "instructions": [["address": "0x260", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]
                ]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let g = "void G(void)\n{\n  Same();\n}\n"
        let before = try artifact("void F(void)\n{\n  A();\n}\n", g)
        let after = try artifact("void F(void)\n{\n  B();\n}\n", g)
        // What the last launch left: both functions seen at revision 53.
        let records = [
            "0x220": SeenRecord(revision: 53,
                                fingerprint: SeenRecord.fingerprint(name: "F", signature: nil,
                                                                    c: before.functions[0].c)),
            "0x260": SeenRecord(revision: 53,
                                fingerprint: SeenRecord.fingerprint(name: "G", signature: nil,
                                                                    c: before.functions[1].c))
        ]
        let view = CodePaneView(manifest: manifest(revision: 54), artifact: after,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        view.restoreSeen(records, baselines: [53: before])

        XCTAssertEqual(view.newMarks.count, 1, "only the function the revision changed")
        XCTAssertEqual(view.newMarks.first?.entry, CodeAddress(0x220))
        XCTAssertEqual(view.newMarks.first?.baseline.revision, 53,
                       "shown against the revision the reader last saw it at")
        XCTAssertEqual(view.seenRecords["0x220"]?.revision, 53, "unread: still where it was seen")
        XCTAssertEqual(view.seenRecords["0x260"]?.revision, 54,
                       "unchanged: the reader is that much further along with it")

        // Opening it is seeing it — and shows the change the mark is about.
        var saved: [String: SeenRecord] = [:]
        view.onSeenChanged = { saved = $0 }
        view.selectFunction(at: 0)
        XCTAssertEqual(view.comparisonRevision, 53)
        XCTAssertTrue(view.showsRevisionDiff)
        XCTAssertEqual(view.seenRecords["0x220"]?.revision, 54, "read now")
        XCTAssertEqual(saved["0x220"]?.revision, 54, "and kept for the next launch")
    }

    /// A function the records never had is new to the reader, and shown
    /// against the newest revision anything was seen at; the first open of a
    /// module has nothing behind it, and marks nothing.
    func testANeverSeenFunctionIsNewAndTheFirstOpenIsSeen() throws {
        func artifact(_ f: String) throws -> CodeArtifact {
            let json: [String: Any] = [
                "script_version": 2, "program": ["image_base": "0x0"],
                "functions": [
                    ["entry": "0x220", "name": "F", "c": f,
                     "instructions": [["address": "0x220", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]],
                    ["entry": "0x260", "name": "G", "c": "void G(void) {}",
                     "instructions": [["address": "0x260", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]
                ]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let current = try artifact("void F(void) {}")
        let view = CodePaneView(manifest: manifest(revision: 54), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()

        var saved: [[String: SeenRecord]] = []
        view.onSeenChanged = { saved.append($0) }
        view.restoreSeen([:], baselines: [:])
        XCTAssertTrue(view.newMarks.isEmpty, "nothing has been seen here, so nothing is new")
        XCTAssertEqual(view.seenRecords.count, 2, "every function is seen now")
        XCTAssertEqual(Set(view.seenRecords.values.map(\.revision)), [54])
        XCTAssertEqual(saved.count, 1, "and what was seen is kept")

        // A later launch that knows only G: F appeared in between, and is
        // shown against that revision — as all added.
        let older = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: [
            "script_version": 2, "program": ["image_base": "0x0"],
            "functions": [["entry": "0x260", "name": "G", "c": "void G(void) {}",
                           "instructions": [["address": "0x260", "bytes": "C3",
                                             "mnemonic": "RET", "text": "RET"]]]]
        ]))
        let g = SeenRecord(revision: 53,
                           fingerprint: SeenRecord.fingerprint(name: "G", signature: nil,
                                                               c: current.functions[1].c))
        let next = CodePaneView(manifest: manifest(revision: 54), artifact: current,
                                moduleBytes: teModule(), hexView: NSView())
        next.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        next.layoutSubtreeIfNeeded()
        next.restoreSeen(["0x260": g], baselines: [53: older])
        XCTAssertEqual(next.newMarks.map(\.entry), [CodeAddress(0x220)])
        XCTAssertEqual(next.newMarks.first?.baseline.revision, 53,
                       "new since the newest revision anything was seen at")
        next.selectFunction(at: 0)
        XCTAssertEqual(next.comparisonRevision, 53)
        XCTAssertTrue(next.showsRevisionDiff)
        XCTAssertEqual(next.diffCounts?.added, 1, "a function the earlier revision did not have")
        XCTAssertEqual(next.diffCounts?.removed, 0)
    }

    /// The records are kept by module and reading, and a reading with none
    /// left is taken out of the store.
    func testSeenRecordsAreKeptByModuleAndRecipe() throws {
        let suiteName = "CodePaneViewTests.seen"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        let module = SHA256Digest(data: Data("module".utf8))
        let record = SeenRecord(revision: 54, fingerprint: "abc")
        CodeRevisionSeen.save(["0x220": record], module: module, recipe: "code-v2")
        XCTAssertEqual(CodeRevisionSeen.records(module: module, recipe: "code-v2"), ["0x220": record])
        XCTAssertTrue(CodeRevisionSeen.records(module: module, recipe: "code-v3").isEmpty,
                      "another reading is another set")
        CodeRevisionSeen.save([:], module: module, recipe: "code-v2")
        XCTAssertTrue(CodeRevisionSeen.records(module: module, recipe: "code-v2").isEmpty)
    }

    /// A comparison a New mark puts up belongs to that function: moving to a
    /// function the revision did not change takes it away, and only a
    /// revision the reader picks in the bar holds for every function.
    func testAComparisonFromANewMarkIsThatFunctionsAlone() throws {
        func artifact(_ first: String, _ second: String) throws -> CodeArtifact {
            let json: [String: Any] = [
                "script_version": 2, "program": ["image_base": "0x0"],
                "functions": [
                    ["entry": "0x220", "name": "F", "c": first,
                     "instructions": [["address": "0x220", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]],
                    ["entry": "0x260", "name": "G", "c": second,
                     "instructions": [["address": "0x260", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]
                ]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let g = "void G(void)\n{\n  Same();\n}\n"
        let previous = try artifact("void F(void)\n{\n  A();\n}\n", g)
        let current = try artifact("void F(void)\n{\n  B();\n}\n", g)
        let view = CodePaneView(manifest: manifest(), artifact: current, moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        view.markRevisionChange(from: previous, revision: 54)

        view.selectFunction(at: 0)
        XCTAssertEqual(view.comparisonRevision, 54, "the changed function compares with its mark")
        XCTAssertTrue(view.showsRevisionDiff)
        view.selectFunction(at: 1)
        XCTAssertNil(view.comparisonRevision, "an unchanged function is not compared")
        XCTAssertFalse(view.showsRevisionDiff)

        // The reader's own pick holds across functions until Reset — but a
        // function the revision did not change is shown as the code, not as a
        // diff of nothing.
        view.setComparisonRevision(54, artifact: previous, pinned: true)
        view.selectFunction(at: 0)
        XCTAssertTrue(view.showsRevisionDiff)
        view.selectFunction(at: 1)
        XCTAssertEqual(view.comparisonRevision, 54, "the pick still holds")
        XCTAssertFalse(view.showsRevisionDiff, "no change here: the code is shown")
        let noComparison: (Int?, CodeArtifact?) = (nil, nil)
        view.setComparisonRevision(noComparison.0, artifact: noComparison.1)
        XCTAssertFalse(view.showsRevisionDiff)
    }

    /// A click in the diff works as in the C: a name highlights its every
    /// occurrence there, and a name that explains itself opens its popover —
    /// from the revision whose line it is, either side.
    func testAClickInTheDiffHighlightsAndExplains() throws {
        func artifact(_ call: String) throws -> CodeArtifact {
            let c = "void F(void)\n{\n  Port = mPort + \(call);\n}\n"
            let at = (c as NSString).range(of: "mPort")
            let json: [String: Any] = [
                "script_version": 5, "program": ["image_base": "0x0"],
                "functions": [["entry": "0x220", "name": "F", "c": c,
                               "c_spans": [[at.location, at.length, "global", "0x230"]],
                               "instructions": [["address": "0x220", "bytes": "C3",
                                                 "mnemonic": "RET", "text": "RET"]]]],
                "symbols": [["address": "0x230", "name": "mPort", "type": "UINT16",
                             "source": "USER_DEFINED", "comment": "The port the board's EC answers on."]]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let view = CodePaneView(manifest: manifest(), artifact: try artifact("1"),
                                moduleBytes: teModule(), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.setComparisonRevision(54, artifact: try artifact("2"))
        XCTAssertTrue(view.showsRevisionDiff)

        let shown = view.diffText as NSString
        let at = shown.range(of: "mPort").location + 1
        XCTAssertFalse(view.clickDiff(at: at, event: try click(count: 1)))
        XCTAssertEqual(view.diffHighlightedRanges.count, 2, "the name on both sides, highlighted")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(view.shownExplanation?.subject, .global(CodeAddress(0x230)))
        // The first of the two is on the removed line: the earlier revision's
        // model explains it, so its uses name that revision's functions.
        let model = try XCTUnwrap(view.shownExplanationModel)
        XCTAssertEqual(model.functions.first?.c, view.diffBaselineModelForTest?.functions.first?.c,
                       "a removed line is explained from the earlier revision's model")
        XCTAssertNotEqual(model.functions.first?.c, view.currentModelForTest.functions.first?.c)
        view.shownExplanationClose()
    }

    /// A field of a structure has no token of its own in the C: the diff finds
    /// it by its place, on either side, and marks it as the C does.
    func testAFieldInTheDiffExplainsItself() throws {
        func artifact(_ value: String) throws -> CodeArtifact {
            let c = "void F(GROUP *Group)\n{\n  Use(Group->SequenceCount);\n  Set(\(value),Group->SequenceCount);\n}\n"
            let text = c as NSString
            var fields: [[Any]] = []
            var from = 0
            while true {
                let found = text.range(of: "SequenceCount", range: NSRange(location: from, length: text.length - from))
                guard found.location != NSNotFound else { break }
                fields.append([found.location, found.length, "GROUP", 4])
                from = found.location + found.length
            }
            let structC = "struct GROUP {\n    /* 0x00 */ UINT32 Base;\n"
                + "    /* 0x04 */ UINT32 SequenceCount; // how many follow\n} /* size 0x8 */;"
            let json: [String: Any] = [
                "script_version": 5, "program": ["image_base": "0x0"],
                "functions": [["entry": "0x220", "name": "F", "c": c, "c_fields": fields,
                               "instructions": [["address": "0x220", "bytes": "C3",
                                                 "mnemonic": "RET", "text": "RET"]]]],
                "types": [["name": "GROUP", "kind": "struct", "size": 8, "c": structC]]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let view = CodePaneView(manifest: manifest(), artifact: try artifact("1"),
                                moduleBytes: teModule(), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.setComparisonRevision(54, artifact: try artifact("2"))
        XCTAssertTrue(view.showsRevisionDiff)

        let shown = view.diffText as NSString
        XCTAssertEqual(view.diffExplainableRanges.map { shown.substring(with: $0) },
                       Array(repeating: "SequenceCount", count: 3),
                       "the shared line once, and the changed line on each side")
        func ask(_ range: NSRange, count: Int) throws -> CodeExplanation? {
            view.shownExplanationClose()
            XCTAssertFalse(view.clickDiff(at: range.location + 1, event: try click(count: count)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return view.shownExplanation
        }
        let removed = shown.range(of: "Set(2,Group->SequenceCount)")
        let added = shown.range(of: "Set(1,Group->SequenceCount)")
        XCTAssertNotEqual(removed.location, NSNotFound)
        XCTAssertNotEqual(added.location, NSNotFound)
        let onRemoved = try XCTUnwrap(view.diffExplainableRanges.first { NSIntersectionRange($0, removed).length > 0 })
        let onAdded = try XCTUnwrap(view.diffExplainableRanges.first { NSIntersectionRange($0, added).length > 0 })
        XCTAssertNotNil(try ask(onAdded, count: 1), "the current revision's line")
        XCTAssertEqual(view.shownExplanationModel?.functions.first?.c, view.currentModelForTest.functions.first?.c)
        XCTAssertNotNil(try ask(onRemoved, count: 1), "the earlier revision's line")
        XCTAssertEqual(view.shownExplanationModel?.functions.first?.c, view.diffBaselineModelForTest?.functions.first?.c)
        XCTAssertNotNil(try ask(onAdded, count: 2), "a double click asks too, as in the C")
        view.shownExplanationClose()
    }

    /// ⌘-click or a double click on a variable selects where its revision
    /// defines it: a local declared only on the other side is not its place.
    func testAJumpOnAVariableInTheDiffSelectsItsDefinition() throws {
        func artifact(_ declaration: String, _ last: String) throws -> CodeArtifact {
            let c = "void F(int Count)\n{\n  \(declaration);\n  Use(Count);\n  Use(value);\n  \(last);\n}\n"
            let text = c as NSString
            var spans: [[Any]] = []
            for (word, kind) in [("value", "local"), ("Count", "parameter")] {
                var from = 0
                while true {
                    let found = text.range(of: word, range: NSRange(location: from, length: text.length - from))
                    guard found.location != NSNotFound else { break }
                    spans.append([found.location, found.length, kind])
                    from = found.location + found.length
                }
            }
            let json: [String: Any] = [
                "script_version": 5, "program": ["image_base": "0x0"],
                "functions": [["entry": "0x220", "name": "F", "c": c, "c_spans": spans,
                               "instructions": [["address": "0x220", "bytes": "C3",
                                                 "mnemonic": "RET", "text": "RET"]]]]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let view = CodePaneView(manifest: manifest(), artifact: try artifact("UINT8 value = 1", "Free(value)"),
                                moduleBytes: teModule(), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.setComparisonRevision(54, artifact: try artifact("UINT16 value = 2", "Free(value)"))
        XCTAssertTrue(view.showsRevisionDiff)

        let shown = view.diffText as NSString
        let oldDeclaration = NSRange(location: shown.range(of: "UINT16 value").location + 7, length: 5)
        let newDeclaration = NSRange(location: shown.range(of: "UINT8 value").location + 6, length: 5)
        XCTAssertLessThan(oldDeclaration.location, newDeclaration.location, "the removed line is drawn first")
        let use = shown.range(of: "Use(value)").location + 4
        let parameterUse = shown.range(of: "Use(Count)").location + 4

        XCTAssertTrue(view.clickDiff(at: use + 1, event: try click(count: 1, flags: .command)))
        XCTAssertEqual(view.diffSelectedRange, newDeclaration,
                       "a line both revisions share reads the current one: not the removed line above")
        XCTAssertTrue(view.clickDiff(at: parameterUse + 1, event: try click(count: 2)))
        XCTAssertEqual(shown.substring(with: view.diffSelectedRange), "Count")
        XCTAssertEqual(view.diffSelectedRange.location, shown.range(of: "int Count").location + 4,
                       "a double click goes to the parameter in the signature")
        XCTAssertFalse(view.clickDiff(at: use + 1, event: try click(count: 1)),
                       "a plain click still only highlights")
    }

    /// A variable clicked in the diff highlights its every occurrence there,
    /// as a global's name does.
    func testAClickOnAVariableInTheDiffHighlightsIt() throws {
        func artifact(_ call: String) throws -> CodeArtifact {
            let c = "void F(void)\n{\n  UINT8 value = 0;\n  value = value + 1;\n  Helper(\(call));\n}\n"
            var spans: [[Any]] = []
            var search = c.startIndex
            while let found = c.range(of: "value", range: search..<c.endIndex) {
                let at = c.utf16.distance(from: c.startIndex, to: found.lowerBound)
                spans.append([at, 5, "local"])
                search = found.upperBound
            }
            let json: [String: Any] = [
                "script_version": 5, "program": ["image_base": "0x0"],
                "functions": [["entry": "0x220", "name": "F", "c": c, "c_spans": spans,
                               "instructions": [["address": "0x220", "bytes": "C3",
                                                 "mnemonic": "RET", "text": "RET"]]]]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let view = CodePaneView(manifest: manifest(), artifact: try artifact("0x10"),
                                moduleBytes: teModule(), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.setComparisonRevision(54, artifact: try artifact("0x20"))
        XCTAssertTrue(view.showsRevisionDiff)

        let shown = view.diffText as NSString
        let at = shown.range(of: "value").location + 1
        XCTAssertFalse(view.clickDiff(at: at, event: try click(count: 1)))
        XCTAssertEqual(view.diffHighlightedRanges.count, 3, "the declaration and both uses")
        view.shownExplanationClose()
    }

    /// A variable whose occurrences are on lines the revision changed —
    /// tinted red and green — is still seen where it is highlighted: the
    /// box is drawn over the row's tint, not under it.
    func testAVariableOnChangedLinesIsVisiblyHighlighted() throws {
        func artifact(_ value: String) throws -> CodeArtifact {
            let c = "void F(void)\n{\n  value = \(value);\n  value = value + 1;\n}\n"
            var spans: [[Any]] = []
            var search = c.startIndex
            while let found = c.range(of: "value", range: search..<c.endIndex) {
                let at = c.utf16.distance(from: c.startIndex, to: found.lowerBound)
                spans.append([at, 5, "local"])
                search = found.upperBound
            }
            let json: [String: Any] = [
                "script_version": 5, "program": ["image_base": "0x0"],
                "functions": [["entry": "0x220", "name": "F", "c": c, "c_spans": spans,
                               "instructions": [["address": "0x220", "bytes": "C3",
                                                 "mnemonic": "RET", "text": "RET"]]]]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        // Both lines with `value` differ between the revisions.
        let view = CodePaneView(manifest: manifest(), artifact: try artifact("0"),
                                moduleBytes: teModule(), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.setComparisonRevision(54, artifact: try artifact("1"))
        XCTAssertTrue(view.showsRevisionDiff)

        let shown = view.diffText as NSString
        let at = shown.range(of: "value").location + 1
        XCTAssertFalse(view.clickDiff(at: at, event: try click(count: 1)))
        XCTAssertEqual(view.diffHighlightedRanges.count, 4, "two sides, two lines")
        view.shownExplanationClose()

        // The row's tint and the click's box are drawn in one background pass,
        // the tint first: a tint set as a text attribute would be drawn over
        // the box and the name would look unhighlighted on a changed line.
        let before = CodeTextView.backgroundDraws
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertGreaterThan(CodeTextView.backgroundDraws, before, "the background pass ran")
        // The line the earlier revision held is the removed one.
        let removed = try XCTUnwrap(view.diffBackground(ofLineContaining: "value = 1;"))
        XCTAssertEqual(removed.usingColorSpace(.sRGB).map { [$0.redComponent, $0.greenComponent, $0.blueComponent] },
                       CodeColors.diffRemoved.usingColorSpace(.sRGB).map {
                           [$0.redComponent, $0.greenComponent, $0.blueComponent]
                       })
        let added = try XCTUnwrap(view.diffBackground(ofLineContaining: "value = 0;"))
        XCTAssertEqual(added.usingColorSpace(.sRGB).map { [$0.redComponent, $0.greenComponent, $0.blueComponent] },
                       CodeColors.diffAdded.usingColorSpace(.sRGB).map {
                           [$0.redComponent, $0.greenComponent, $0.blueComponent]
                       })
    }

    /// One alpha everywhere: the fill over the code's background reproduces
    /// the box the panel always drew, and the same fill over a tinted row
    /// adds its colour to the row's.
    func testTheHighlightIsOneBlendOverTintAndPlainCode() throws {
        let text = CodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        text.rowTints = [(range: NSRange(location: 0, length: 10), color: .systemRed)]
        let fill = try XCTUnwrap(text.highlightFill.usingColorSpace(.sRGB))
        XCTAssertEqual(fill.alphaComponent, CodeTextView.highlightAlpha, accuracy: 0.001)

        let back = try XCTUnwrap(NSColor.textBackgroundColor.usingColorSpace(.sRGB))
        let box = try XCTUnwrap(CodeColors.symbolHighlight.usingColorSpace(.sRGB))
        func mixed(_ fill: CGFloat, _ back: CGFloat) -> CGFloat {
            fill * CodeTextView.highlightAlpha + back * (1 - CodeTextView.highlightAlpha)
        }
        XCTAssertEqual(mixed(fill.redComponent, back.redComponent), box.redComponent, accuracy: 0.01)
        XCTAssertEqual(mixed(fill.greenComponent, back.greenComponent), box.greenComponent, accuracy: 0.01)
        XCTAssertEqual(mixed(fill.blueComponent, back.blueComponent), box.blueComponent, accuracy: 0.01)

        // And over a tint it is a blend of the two, not either alone.
        let tint = try XCTUnwrap(CodeColors.diffAdded.usingColorSpace(.sRGB))
        let overTint = mixed(fill.redComponent, tint.redComponent)
        XCTAssertGreaterThan(overTint, tint.redComponent - 0.2)
        XCTAssertLessThan(overTint, tint.redComponent + 0.2)
    }

    /// A name on a line the revisions share explains itself as one on a
    /// changed line does, and the popover sits beside the word — not at the
    /// top of the text's document, which is where a rect in the document's
    /// coordinates put it.
    func testAClickInAnUnchangedDiffLineExplainsItsName() throws {
        func artifact(_ call: String) throws -> CodeArtifact {
            // The name sits on a line both revisions share, near the top of a
            // document tall enough that the document's coordinates are not the
            // view's.
            var body = ["  Port = mPort + 1;"]
            body += (1...40).map { "  Step\($0)();" }
            body.append("  Helper(\(call));")
            let c = "void F(void)\n{\n" + body.joined(separator: "\n") + "\n}\n"
            let at = (c as NSString).range(of: "mPort")
            let json: [String: Any] = [
                "script_version": 5, "program": ["image_base": "0x0"],
                "functions": [["entry": "0x220", "name": "F", "c": c,
                               "c_spans": [[at.location, at.length, "global", "0x230"]],
                               "instructions": [["address": "0x220", "bytes": "C3",
                                                 "mnemonic": "RET", "text": "RET"]]]],
                "symbols": [["address": "0x230", "name": "mPort", "type": "UINT16",
                             "source": "USER_DEFINED", "comment": "The port the board's EC answers on."]]
            ]
            return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let view = CodePaneView(manifest: manifest(), artifact: try artifact("0x10"),
                                moduleBytes: teModule(), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.setComparisonRevision(54, artifact: try artifact("0x20"))
        XCTAssertTrue(view.showsRevisionDiff)

        let shown = view.diffText as NSString
        let at = shown.range(of: "mPort").location + 1
        XCTAssertFalse(view.clickDiff(at: at, event: try click(count: 1)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(view.shownExplanation?.subject, .global(CodeAddress(0x230)),
                       "the name on a line both revisions share")
        let rect = try XCTUnwrap(view.shownExplanationRect)
        XCTAssertTrue(view.diffBounds.contains(rect),
                      "the popover sits beside the word: \(rect) in the diff's \(view.diffBounds)")
        view.shownExplanationClose()
    }

    /// The call tree's rows open and close with the triangle in front of them.
    func testTheTreeOpensAndClosesItsCalls() throws {
        let suiteName = "CodePaneViewTests.treeFolds"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,"program":{"image_base":"0x0"},
         "functions":[
          {"entry":"0x100","name":"Leaf","callers":["0x200"],"callees":[],
           "instructions":[{"address":"0x100","bytes":"C3","text":"RET"}]},
          {"entry":"0x200","name":"Root","callers":[],"callees":["0x100"],
           "instructions":[{"address":"0x200","bytes":"C3","text":"RET"}]},
          {"entry":"0x300","name":"ZOther","callers":[],"callees":[],
           "instructions":[{"address":"0x300","bytes":"C3","text":"RET"}]}]}
        """.utf8))
        let view = CodePaneView(manifest: manifest(), artifact: artifact,
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        view.layoutSubtreeIfNeeded()
        view.setFunctionOrder(.calls)
        view.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(all(NSTableView.self, in: view).first {
            $0.tableColumns.contains { $0.identifier.rawValue == "function" }
        })
        func cell(_ row: Int) throws -> NSTableCellView {
            try XCTUnwrap(list.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        }
        XCTAssertEqual(list.numberOfRows, 2, "every place starts closed: the two roots")
        XCTAssertEqual(try cell(0).textField?.stringValue, "Root", "the roots read alphabetically")

        let triangle = try XCTUnwrap(all(NSButton.self, in: try cell(0)).first)
        triangle.performClick(nil)
        XCTAssertEqual(list.numberOfRows, 3, "Root, its call, and the other root")
        XCTAssertEqual(try cell(1).textField?.stringValue, "Leaf")

        let closing = try XCTUnwrap(all(NSButton.self, in: try cell(0)).first)
        closing.performClick(nil)
        XCTAssertEqual(list.numberOfRows, 2, "a closed row keeps its place and hides what it calls")

        let reopened = try XCTUnwrap(all(NSButton.self, in: try cell(0)).first)
        reopened.performClick(nil)
        XCTAssertEqual(list.numberOfRows, 3)

        // A search result is one alphabetical row, not a tree to open.
        view.filter(by: "Leaf")
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.numberOfRows, 1)
        let found = try cell(0)
        XCTAssertEqual(found.textField?.stringValue, "Leaf")
        XCTAssertTrue(all(NSButton.self, in: found).first?.isHidden ?? true,
                      "no triangle on a search result")
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

    /// A caller the analysis knows but whose call it could not place is
    /// still listed, and leads to the caller's entry.
    func testAnUnplacedCallerLeadsToItsFunction() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()

        let sheet = try XCTUnwrap(view.showCallers(of: 0))
        XCTAssertEqual(sheet.callers, [CodeCaller(function: 1, use: nil)])
        XCTAssertEqual(sheet.text(sheet.callers[0], .address), "—")
        XCTAssertEqual(sheet.text(sheet.callers[0], .kind), "Call site unknown")
        sheet.choose(row: 0)
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

    /// The function's name — in the header, in the C — has a menu of its
    /// own: Show Callers, off when nothing calls the function. The text
    /// view's own menu (Open Link, Font, Speech) is not offered.
    func testAFunctionsNameOffersShowCallers() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try selfNamedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 1, instruction: nil, showsC: true)
        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let c = textView.string as NSString

        let own = try XCTUnwrap(view.cMenu(at: c.range(of: "entry").location))
        XCTAssertEqual(own.items.map(\.title), ["Show Callers…"])
        XCTAssertTrue(own.items[0].isEnabled)
        XCTAssertNil(view.cMenu(at: c.range(of: "void").location), "nothing to offer off a name")
        textView.setSelectedRange(c.range(of: "void"))
        XCTAssertEqual(view.cMenu(at: c.range(of: "void").location)?.items.map(\.title), ["Copy"])

        let header = try XCTUnwrap(first(CodeTitleField.self, in: view) { _ in true })
        XCTAssertEqual(header.stringValue, "entry")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertEqual(header.menu(for: event)?.items.map(\.title), ["Show Callers…"])
        // Selected, the name is the field editor's: Copy, then the function's.
        let editor = NSTextView()
        editor.string = "entry"
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertEqual(header.textView(editor, menu: NSMenu(), for: event, at: 0)?.items.map(\.title),
                       ["Copy", "", "Show Callers…"])

        // Nothing calls FUN_00000220: the item is there, and off.
        view.selectFunction(at: 0)
        XCTAssertEqual(view.functionMenu(for: 0)?.items.first?.isEnabled, false)
    }

    /// The function's own name in its signature is not a link: a click,
    /// ⌘-click or a double click shows who calls it, in a popover off the
    /// name, rather than reopen the function. Under the pointer it
    /// underlines as a call does.
    func testTheFunctionsOwnNameShowsItsCallers() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try selfNamedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.restore(function: 1, instruction: nil, showsC: true)
        // A popover shows only off a window on screen.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let text = view.decompiledAttributedText
        let signature = (text.string as NSString).range(of: "entry")
        XCTAssertNil(text.attribute(.link, at: signature.location, effectiveRange: nil),
                     "drawn as a name, not a link")

        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        XCTAssertEqual(textView.callable, signature)
        let glyphs = textView.layoutManager!.glyphRange(forCharacterRange: signature, actualCharacterRange: nil)
        let box = textView.layoutManager!.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
        textView.hover(at: NSPoint(x: box.midX + textView.textContainerOrigin.x,
                                   y: box.midY + textView.textContainerOrigin.y))
        XCTAssertEqual(textView.hoveredLink, signature, "underlined under the pointer")

        XCTAssertFalse(view.clickC(at: signature.location, event: try click(count: 1)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let shown = try XCTUnwrap(view.shownCallers, "a click shows the callers")
        XCTAssertEqual(shown.rowText(shown.callers[0]), "FUN_00000220 · 0x68 · CALL 0x00000222")
        // The table fits: every cell inside the popover, none cut.
        shown.view.layoutSubtreeIfNeeded()
        let cells = all(NSButton.self, in: shown.view)
        XCTAssertEqual(cells.map(\.title), ["FUN_00000220", "0x68", "CALL 0x00000222"])
        for cell in cells {
            let frame = cell.convert(cell.bounds, to: shown.view)
            XCTAssertTrue(shown.view.bounds.contains(frame), "\(cell.title) inside the popover")
            XCTAssertGreaterThanOrEqual(cell.frame.width, cell.fittingSize.width, "\(cell.title) not cut")
        }
        shown.close()
        for event in [try click(count: 1, flags: .command), try click(count: 2)] {
            XCTAssertTrue(view.clickC(at: signature.location, event: event))
            XCTAssertNotNil(view.shownCallers, "Show Callers…")
            view.shownCallers?.close()
        }
        XCTAssertFalse(view.canGoBack, "no jump was made")
        XCTAssertEqual(view.highlightedSymbol, .target(.function(1)), "the name is highlighted, as a click does")
    }

    /// A call's menu leads with Jump to Definition — what ⌘-click does — and
    /// then Show Callers… of the function called.
    func testACallsMenuJumpsToTheDefinition() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try selfNamedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        let c = view.decompiledAttributedText.string as NSString
        let call = c.range(of: "entry")
        let menu = try XCTUnwrap(view.cMenu(at: call.location))
        XCTAssertEqual(menu.items.map(\.title), ["Jump to Definition", "Show Callers…"])
        let signature = try XCTUnwrap(view.cMenu(at: c.range(of: "FUN_00000220").location))
        XCTAssertEqual(signature.items.map(\.title), ["Show Callers…"], "the function's own name is no call")

        let jump = menu.items[0]
        _ = (jump.target as? NSObject)?.perform(jump.action, with: jump)
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        view.goBack()
        XCTAssertEqual(view.lastFlash, .c(call), "Back returns to the call")
    }

    /// FUN_00000220 calls entry; entry's C names itself in its signature.
    private func selfNamedArtifact() throws -> CodeArtifact {
        let caller = "void FUN_00000220(void)\n{\n  entry();\n}\n"
        let callee = "void entry(void)\n{\n}\n"
        let json: [String: Any] = [
            "script_version": 4, "ghidra": "12.1.2", "program": ["image_base": "0x0"],
            "functions": [
                ["entry": "0x220", "name": "FUN_00000220", "c": caller,
                 "c_spans": [[5, 12, "function", "0x220"], [28, 5, "function", "0x222"]],
                 "instructions": [
                    ["address": "0x220", "bytes": "E8 00", "mnemonic": "CALL", "text": "CALL 0x00000222",
                     "references": [["to": "0x222", "type": "UNCONDITIONAL_CALL"]]]]],
                ["entry": "0x222", "name": "entry", "callers": ["0x220"], "c": callee,
                 "c_spans": [[5, 5, "function", "0x222"], [0, 4, "type"]],
                 "instructions": [["address": "0x222", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]
            ]
        ]
        return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
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

    /// FUN_00000220 is sixty PUSHes and a call to entry at its end, in the
    /// listing and in the C: far enough down that both scroll.
    private func longCallerArtifact() throws -> CodeArtifact {
        var c = "void FUN_00000220(void)\n{\n"
        for index in 0..<60 { c += "  Value\(index) = \(index);\n" }
        let call = c.utf16.count + 2
        c += "  entry();\n}\n"
        var instructions: [[String: Any]] = (0..<60).map { index in
            ["address": String(format: "0x%X", 0x220 + index), "bytes": "56", "mnemonic": "PUSH", "text": "PUSH ESI"]
        }
        instructions.append(["address": "0x25C", "bytes": "E8 00", "mnemonic": "CALL", "text": "CALL 0x00000300",
                             "references": [["to": "0x300", "type": "UNCONDITIONAL_CALL"]]])
        let json: [String: Any] = [
            "script_version": 4, "ghidra": "12.1.2", "program": ["image_base": "0x0"],
            "functions": [
                ["entry": "0x220", "name": "FUN_00000220", "c": c,
                 "c_spans": [[5, 12, "function", "0x220"], [call, 5, "function", "0x300"]],
                 "instructions": instructions],
                ["entry": "0x300", "name": "entry", "c": "void entry(void)\n{\n}\n",
                 "c_spans": [[5, 5, "function", "0x300"]],
                 "instructions": [["address": "0x300", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]
            ]
        ]
        return try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func scrollOrigin(of document: NSView) throws -> CGFloat {
        try XCTUnwrap(document.enclosingScrollView).contentView.bounds.origin.y
    }

    /// Back returns to the listing where it was scrolled, not to its top, and
    /// flashes the row the jump left from; the function arrived at flashes its
    /// first row.
    func testBackKeepsTheListingWhereItWasAndFlashesTheRow() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try longCallerArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: false)
        let listing = try XCTUnwrap(first(NSTableView.self, in: view) {
            $0.tableColumns.first?.identifier.rawValue == "instruction"
        })
        listing.scrollRowToVisible(60)
        let scrolled = try scrollOrigin(of: listing)
        XCTAssertGreaterThan(scrolled, 0)
        let cell = try XCTUnwrap(listing.view(atColumn: 0, row: 60, makeIfNecessary: true) as? CodeLineCell)
        XCTAssertEqual(cell.line.onClick?(.function(1), try click(count: 1, flags: .command)), true)
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertEqual(view.lastFlash, .row(0), "where the jump arrived")

        view.goBack()
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
        XCTAssertEqual(view.selectedInstructionIndex, 60, "the row the jump left from")
        XCTAssertEqual(try scrollOrigin(of: listing), scrolled, accuracy: 0.5)
        XCTAssertEqual(view.lastFlash, .row(60))

        view.goForward()
        XCTAssertEqual(view.lastFlash, .row(0))
        view.goBack()
        XCTAssertEqual(try scrollOrigin(of: listing), scrolled, accuracy: 0.5, "again after Forward")
    }

    /// In the C, the function arrived at reads from its top with its name
    /// flashed; Back puts the caller's C where it was scrolled and flashes the
    /// call that was followed.
    func testBackKeepsTheCWhereItWasAndFlashesTheCall() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try longCallerArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let call = (textView.string as NSString).range(of: "entry")
        textView.scrollRangeToVisible(call)
        let scrolled = try scrollOrigin(of: textView)
        XCTAssertGreaterThan(scrolled, 0)

        XCTAssertTrue(view.clickC(at: call.location, event: try click(count: 1, flags: .command)))
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertEqual(try scrollOrigin(of: textView), 0, "another function reads from its top")
        XCTAssertEqual(view.lastFlash, .c(NSRange(location: 5, length: 5)), "its name in the signature")

        view.goBack()
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
        XCTAssertEqual(try scrollOrigin(of: textView), scrolled, accuracy: 0.5)
        XCTAssertEqual(view.lastFlash, .c(call))
        XCTAssertEqual(textView.selectedRange(), call)
    }

    /// A pane over a republished artifact takes each place's scroll along.
    func testTheCarriedHistoryKeepsWhereEachPlaceWasScrolled() throws {
        let first = CodePaneView(manifest: manifest(), artifact: try longCallerArtifact(),
                                 moduleBytes: teModule(), hexView: NSView())
        first.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        first.layoutSubtreeIfNeeded()
        first.restore(function: 0, instruction: nil, showsC: true)
        let firstText = try XCTUnwrap(self.first(CodeTextView.self, in: first) { _ in true })
        let call = (firstText.string as NSString).range(of: "entry")
        firstText.scrollRangeToVisible(call)
        let scrolled = try scrollOrigin(of: firstText)
        XCTAssertTrue(first.clickC(at: call.location, event: try click(count: 1, flags: .command)))
        let carried = first.carriedHistory

        let second = CodePaneView(manifest: manifest(), artifact: try longCallerArtifact(),
                                  moduleBytes: teModule(), hexView: NSView())
        second.frame = first.frame
        second.layoutSubtreeIfNeeded()
        second.restore(at: first.selectedLocation, function: nil, instruction: nil, showsC: true)
        let secondText = try XCTUnwrap(self.first(CodeTextView.self, in: second) { _ in true })
        secondText.scrollRangeToVisible(NSRange(location: 0, length: 0))
        let entryOrigin = try scrollOrigin(of: firstText)
        second.adoptHistory(carried)
        XCTAssertEqual(try scrollOrigin(of: secondText), entryOrigin, accuracy: 0.5, "the place on screen too")
        second.goBack()
        XCTAssertEqual(try scrollOrigin(of: secondText), scrolled, accuracy: 0.5)
        XCTAssertEqual(second.lastFlash, .c(call), "the same C, so the same mark")
    }

    // MARK: - The module's description

    private let sampleDescription = """
        # CpuPei

        Initialises the **CPU** in PEI; *probably* AMD's.

        ## Interfaces

        | Interface | Kind |
        |---|---|
        | gEfiPeiStallPpiGuid | consumes |

        ## Flow

        1. [The caller](0x220) runs first.
           - then `entry` returns
        2. See <https://example.com> and [a file](notes.md).
        """

    private func describedPane() throws -> CodePaneView {
        let view = CodePaneView(manifest: manifest(), artifact: try longCallerArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 1, instruction: nil, showsC: true)
        return view
    }

    private func link(in text: NSAttributedString, at words: String) -> Any? {
        let range = (text.string as NSString).range(of: words)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(.link, at: range.location, effectiveRange: nil)
    }

    /// The Markdown is set as a document: a table, a list with its markers,
    /// links to the code by address and by a function's name, a link to the
    /// web; a link to a file leads nowhere.
    func testTheDescriptionIsDrawnWithItsLinks() throws {
        let view = try describedPane()
        view.setModuleDescription(sampleDescription)
        view.showDescription(true)
        XCTAssertTrue(view.showsDescription)
        XCTAssertTrue(view.showsDecompiledC, "the code side it goes back to")
        let text = view.descriptionAttributedText
        XCTAssertTrue(text.string.hasPrefix("CpuPei\nInitialises the CPU in PEI"), text.string)
        XCTAssertFalse(text.string.contains("|"), "the table is a table")
        XCTAssertTrue(text.string.contains("1.\tThe caller runs first."), text.string)
        let cell = (text.string as NSString).range(of: "gEfiPeiStallPpiGuid")
        let style = try XCTUnwrap(text.attribute(.paragraphStyle, at: cell.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertTrue(style.textBlocks.first is NSTextTableBlock)
        XCTAssertEqual((link(in: text, at: "The caller") as? URL)?.absoluteString, "code-address:0x220")
        XCTAssertEqual((link(in: text, at: "entry") as? URL)?.absoluteString, "code-address:0x300")
        XCTAssertEqual((link(in: text, at: "https://example.com") as? URL)?.host, "example.com")
        XCTAssertNil(link(in: text, at: "a file"))
        XCTAssertEqual(view.descriptionPlaceholder, "")
    }

    /// A tile that crosses a tall table row — scrolling draws the view a
    /// tile at a time — is drawn as the whole row, so a cell with no line
    /// inside the tile still gets its text, background and borders.
    func testATileThatCutsATableRowDrawsTheWholeRow() throws {
        let view = CodeDescriptionView()
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
        view.layoutSubtreeIfNeeded()
        view.show("""
            | Sees | When | Where |
            |---|---|---|
            | short | one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty | x |
            | next | row | y |
            """)
        let text = try XCTUnwrap(view.textView as? DescriptionTextView)
        let layout = try XCTUnwrap(text.layoutManager)
        let string = text.string as NSString
        func line(of words: String) -> NSRect {
            let glyph = layout.glyphIndexForCharacter(at: string.range(of: words).location)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        }
        let first = line(of: "short"), last = line(of: "twenty"), next = line(of: "next")
        XCTAssertGreaterThan(last.minY, first.maxY, "the middle cell wraps below the others")

        let tile = NSRect(x: 0, y: last.minY, width: 760, height: last.height)
        let drawn = text.tableRows(crossing: tile)
        XCTAssertLessThanOrEqual(drawn.minY, first.minY, "the row's top, where its short cells have their only line")
        XCTAssertLessThanOrEqual(drawn.minX, first.minX)
        XCTAssertLessThan(drawn.maxY, next.minY, "not the next row")
        let margin = NSRect(x: 0, y: 0, width: 760, height: 2)
        XCTAssertEqual(text.tableRows(crossing: margin), margin, "the inset above the table stays as it is")
    }

    func testAModuleWithoutADescriptionSaysSo() throws {
        let view = try describedPane()
        view.showDescription(true)
        XCTAssertEqual(view.descriptionPlaceholder, "", "nothing while the store has not answered")
        view.setModuleDescription(nil)
        XCTAssertTrue(view.descriptionPlaceholder.hasPrefix("No description of this module yet"))
        XCTAssertEqual(view.descriptionText, "")
    }

    /// A link in the description opens the function in the code; Back
    /// returns to the description where it was scrolled.
    func testALinkInTheDescriptionLeadsToTheCodeAndBackReturns() throws {
        let view = try describedPane()
        view.setModuleDescription(sampleDescription + String(repeating: "\n\nMore words.", count: 60))
        view.showDescription(true)
        view.layoutSubtreeIfNeeded()
        view.scrollDescription(to: NSPoint(x: 0, y: 40))
        let scrolled = view.descriptionScrollOrigin.y
        XCTAssertGreaterThan(scrolled, 0)
        let at = (view.descriptionText as NSString).range(of: "The caller").location
        XCTAssertTrue(view.followDescriptionLink(at: at))
        XCTAssertFalse(view.showsDescription)
        XCTAssertTrue(view.showsDecompiledC)
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")

        view.goBack()
        XCTAssertTrue(view.showsDescription)
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        XCTAssertEqual(view.descriptionScrollOrigin.y, scrolled, accuracy: 0.5)
        view.goForward()
        XCTAssertFalse(view.showsDescription)
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
    }

    /// The code's own function named in the description is a move too: Back
    /// returns from its C to the description.
    func testFollowingTheFunctionOnScreenFromTheDescriptionCanBeUndone() throws {
        let view = try describedPane()
        view.setModuleDescription(sampleDescription)
        view.showDescription(true)
        let at = (view.descriptionText as NSString).range(of: "entry").location
        XCTAssertTrue(view.followDescriptionLink(at: at))
        XCTAssertFalse(view.showsDescription)
        XCTAssertTrue(view.canGoBack)
        view.goBack()
        XCTAssertTrue(view.showsDescription)
    }

    /// A republished review keeps the reader in the description, scrolled
    /// where they were, even when its text arrives after the history.
    func testTheCarriedHistoryKeepsTheDescriptionOnScreen() throws {
        let first = try describedPane()
        let long = sampleDescription + String(repeating: "\n\nMore words.", count: 60)
        first.setModuleDescription(long)
        first.showDescription(true)
        first.layoutSubtreeIfNeeded()
        first.scrollDescription(to: NSPoint(x: 0, y: 40))
        let scrolled = first.descriptionScrollOrigin.y
        let carried = first.carriedHistory

        let second = try describedPane()
        second.adoptHistory(carried)
        XCTAssertTrue(second.showsDescription)
        second.setModuleDescription(long)
        XCTAssertEqual(second.descriptionScrollOrigin.y, scrolled, accuracy: 0.5)
    }

    /// A click on a function in the list leaves the description for its code.
    func testChoosingAFunctionLeavesTheDescription() throws {
        let view = try describedPane()
        view.setModuleDescription(sampleDescription)
        view.showDescription(true)
        let list = try XCTUnwrap(first(NSTableView.self, in: view) {
            $0.tableColumns.contains { $0.identifier.rawValue == "function" }
        })
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertFalse(view.showsDescription)
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
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
            $0.tableColumns.contains { $0.identifier.rawValue == "function" }
        })
        let menu = try XCTUnwrap(functions.menu)
        XCTAssertNil(view.clickedPlace(in: functions))
        view.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.isEmpty)
    }

    /// Show Callers lists calls, not callers: a function that calls twice
    /// is two rows, and choosing one goes to that call — its instruction in
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
        let sheet = try XCTUnwrap(view.showCallers(of: 1))
        XCTAssertEqual(sheet.callers.map { sheet.text($0, .caller) }, ["FUN_00000220", "FUN_00000220"])
        XCTAssertEqual(sheet.callers.map { sheet.text($0, .address) }, ["0x68", "0x6A"])
        XCTAssertEqual(sheet.callers.map { sheet.text($0, .instruction) }, ["CALL 0x00000230", "CALL 0x00000230"])
        XCTAssertEqual(sheet.callers.map { sheet.text($0, .kind) }, ["Call", "Call"])

        sheet.choose(row: 1)
        XCTAssertEqual(view.selectedFunction?.name, "FUN_00000220")
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x222))
        let textView = try XCTUnwrap(first(NSTextView.self, in: view) { _ in true })
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        XCTAssertEqual(selected, "entry")
        let second = (textView.string as NSString).range(of: "entry", options: .backwards)
        XCTAssertEqual(textView.selectedRange(), second, "the second call, not the first")
        XCTAssertTrue(view.canGoBack)

        // Back returns where the callers were asked: the function's own
        // name in its signature, selected.
        view.goBack()
        XCTAssertEqual(view.selectedFunction?.name, "entry")
        let back = textView.string as NSString
        XCTAssertEqual(back.substring(with: textView.selectedRange()), "entry")
        XCTAssertEqual(textView.selectedRange(), back.range(of: "entry"), "the signature's name")
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
    /// With a name highlighted, ⌘G and ⇧⌘G — or the arrows beside the
    /// counter — step through its uses in the C, going round at the ends;
    /// the counter says which one the reader is at.
    func testTheHighlightedNamesUsesAreSteppedThrough() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try spannedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        var wraps: [Bool] = []
        view.onWrapOccurrences = { wraps.append($0) }
        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let c = textView.string as NSString
        XCTAssertNil(view.occurrenceCounterText, "nothing highlighted, no counter")
        XCTAssertFalse(view.responds(to: #selector(CodePaneView.findNextMatch)),
                       "⌘G goes on to the find in the dump")

        let last = c.range(of: "Total", options: .backwards)
        XCTAssertFalse(view.clickC(at: last.location, event: try click(count: 1)))
        XCTAssertEqual(view.occurrenceCounterText, "5 of 5", "the use clicked is the current one")
        XCTAssertTrue(view.responds(to: #selector(CodePaneView.findNextMatch)))

        view.findNextMatch()
        let first = c.range(of: "Total")
        XCTAssertEqual(textView.selectedRange(), first, "from the last round to the first")
        XCTAssertEqual(view.occurrenceCounterText, "1 of 5")
        XCTAssertEqual(wraps, [true])
        view.findNextMatch()
        XCTAssertEqual(view.occurrenceCounterText, "2 of 5")
        XCTAssertEqual(c.substring(with: textView.selectedRange()), "Total")
        view.findPreviousMatch()
        view.findPreviousMatch()
        XCTAssertEqual(textView.selectedRange(), last)
        XCTAssertEqual(wraps, [true, false])

        view.highlight(nil)
        XCTAssertNil(view.occurrenceCounterText)
        XCTAssertFalse(view.responds(to: #selector(CodePaneView.findPreviousMatch)))
    }

    /// In the listing the steps go row by row: a call to a function is a use
    /// of its name, and a step selects the instruction.
    func testAStepInTheListingSelectsTheRow() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try spannedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 360)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: 0, showsC: false)
        view.highlight(.target(.function(1)))
        XCTAssertEqual(view.occurrenceCounterText, "1")
        view.goToOccurrence(forward: true)
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x221), "the CALL")
        XCTAssertEqual(view.occurrenceCounterText, "1 of 1")
    }

    /// The C's lines are as far apart as the listing's rows, with the glyphs
    /// in the middle of each line, and both are drawn in the monospaced family
    /// Settings names for the dump.
    func testTheCReadsAtTheListingsPitchInTheSettingsFont() throws {
        let suite = "CodePaneViewTests.codeFont"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let saved = ToolPanelFont.defaults
        ToolPanelFont.defaults = defaults
        defer {
            ToolPanelFont.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(13.0, forKey: ToolPanelFont.zoomSizeKey)
        defaults.set("Menlo", forKey: ToolPanelFont.fontFamilyKey)

        let view = CodePaneView(manifest: manifest(), artifact: try spannedArtifact(),
                                moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let layout = try XCTUnwrap(textView.layoutManager)
        layout.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let menlo = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 13))
        XCTAssertEqual(CodePaneView.codeLineHeight, (layout.defaultLineHeight(for: menlo) * 1.3).rounded(),
                       "the font's own line times the default spacing")
        let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        XCTAssertEqual(line.height, CodePaneView.codeLineHeight, "a line of the C")
        let listing = try XCTUnwrap(tables(in: view).first { $0.tableColumns.first?.identifier.rawValue == "instruction" })
        XCTAssertEqual(listing.rowHeight, CodePaneView.codeLineHeight, "a row of the listing")
        let glyphs = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 3), in: textView.textContainer!)
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let ink = line.maxY - CodePaneView.codeLinePadding - layout.defaultLineHeight(for: font)
        XCTAssertEqual(ink, line.minY + CodePaneView.codeLinePadding, accuracy: 1, "the font's line in the middle")
        XCTAssertLessThanOrEqual(glyphs.height, line.height)

        XCTAssertEqual(font.familyName, "Menlo")

        // Settings ▸ Code Line Spacing: 1.0 sets the lines solid, at the
        // font's own line, in the C and the listing alike.
        defaults.set(1.0, forKey: ToolPanelFont.codeLineSpacingKey)
        NotificationCenter.default.post(name: ToolPanelFont.zoomDidChangeNotification, object: nil)
        let solid = layout.defaultLineHeight(for: font)
        XCTAssertEqual(CodePaneView.codeLineHeight, solid)
        XCTAssertEqual(listing.rowHeight, solid)
        layout.ensureLayout(for: textView.textContainer!)
        XCTAssertEqual(layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height, solid)
        defaults.removeObject(forKey: ToolPanelFont.codeLineSpacingKey)
        defaults.set("", forKey: ToolPanelFont.fontFamilyKey)
        NotificationCenter.default.post(name: ToolPanelFont.zoomDidChangeNotification, object: nil)
        let system = try XCTUnwrap(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertNotEqual(system.familyName, "Menlo", "back to the system monospaced font")
    }

    /// A zoom keeps the reader where they were: the line at the top of the C
    /// and of the listing is at the top again, at the new size.
    func testAZoomKeepsTheLineAtTheTop() throws {
        let suite = "CodePaneViewTests.zoomPlace"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let saved = ToolPanelFont.defaults
        ToolPanelFont.defaults = defaults
        defer {
            ToolPanelFont.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(13.0, forKey: ToolPanelFont.zoomSizeKey)
        var c = "int Long(void)\n{\n"
        var instructions: [[String: Any]] = []
        for line in 0..<400 {
            c += "  Step\(line)();\n"
            instructions.append(["address": String(format: "0x%X", 0x220 + line), "bytes": "90",
                                 "mnemonic": "NOP", "text": "NOP ; \(line)"])
        }
        c += "}\n"
        let json: [String: Any] = [
            "script_version": 4, "ghidra": "12.1.2", "program": ["image_base": "0x0"],
            "functions": [["entry": "0x220", "name": "Long", "c": c, "instructions": instructions]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: Data(count: 0x600), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let cScroll = try XCTUnwrap(textView.enclosingScrollView)
        let text = textView.string as NSString
        let target = text.range(of: "Step200()")
        let layout = try XCTUnwrap(textView.layoutManager)
        layout.ensureLayout(for: textView.textContainer!)
        let lineRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: target.location),
                                               effectiveRange: nil)
        cScroll.contentView.scroll(to: NSPoint(x: 0, y: lineRect.minY + textView.textContainerOrigin.y))
        cScroll.reflectScrolledClipView(cScroll.contentView)
        func lineAtTop() -> String {
            let y = cScroll.contentView.bounds.minY - textView.textContainerOrigin.y + 1
            let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: textView.textContainer!)
            return text.substring(with: text.lineRange(for: NSRange(location: layout.characterIndexForGlyph(at: glyph), length: 0)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(lineAtTop(), "Step200();")

        view.showDecompiledC(false)
        let listing = try XCTUnwrap(tables(in: view).first { $0.tableColumns.first?.identifier.rawValue == "instruction" })
        listing.scrollRowToVisible(399)
        let listingScroll = try XCTUnwrap(listing.enclosingScrollView)
        listingScroll.contentView.scroll(to: NSPoint(x: 0, y: listing.rect(ofRow: 300).minY))
        listingScroll.reflectScrolledClipView(listingScroll.contentView)
        view.showDecompiledC(true)

        defaults.set(18.0, forKey: ToolPanelFont.zoomSizeKey)
        NotificationCenter.default.post(name: ToolPanelFont.zoomDidChangeNotification, object: nil)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(lineAtTop(), "Step200();", "the C stays at the line it was at")
        XCTAssertEqual(listing.row(at: NSPoint(x: 0, y: listingScroll.contentView.bounds.minY + 1)), 300,
                       "and so does the listing")
    }

    /// A `goto`'s label is a link, as a call is: underlined under the
    /// pointer, ⌘-click goes to where the label is defined — and to its
    /// instruction when the name spells its address — and Back returns. A
    /// plain click highlights the goto and the definition alike.
    func testAGotoGoesToItsLabel() throws {
        let c = "void F(int x)\n{\n  if (x) goto LAB_00000222;\n  goto Done;\n  x = 2;\n"
            + "LAB_00000222:\n  x = 1;\nDone:\n  return;\n}\n"
        let json: [String: Any] = [
            "script_version": 5, "program": ["image_base": "0x0"],
            "functions": [["entry": "0x220", "name": "F", "c": c, "instructions": [
                ["address": "0x220", "bytes": "90", "mnemonic": "NOP", "text": "NOP"],
                ["address": "0x221", "bytes": "90", "mnemonic": "NOP", "text": "NOP"],
                ["address": "0x222", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let text = textView.string as NSString
        let gotoLab = text.range(of: "LAB_00000222")
        let definition = text.range(of: "LAB_00000222:")
        XCTAssertNotNil(textView.textStorage?.attribute(.link, at: gotoLab.location, effectiveRange: nil),
                        "a link, underlined under the pointer")

        XCTAssertFalse(view.clickC(at: gotoLab.location, event: try click(count: 1)))
        XCTAssertEqual(textView.highlightedRanges.map { text.substring(with: $0) }, ["LAB_00000222", "LAB_00000222"])

        XCTAssertTrue(view.clickC(at: gotoLab.location, event: try click(count: 1, flags: .command)))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: definition.location, length: 12), "the definition")
        XCTAssertEqual(view.selectedInstruction?.address, CodeAddress(0x222), "and its instruction")
        XCTAssertEqual(view.lastFlash, .c(NSRange(location: definition.location, length: 12)))
        view.goBack()
        XCTAssertEqual(textView.selectedRange(), gotoLab, "Back returns to the goto, as to a call")

        let done = text.range(of: "Done;")
        XCTAssertTrue(view.clickC(at: done.location, event: try click(count: 2)))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: text.range(of: "Done:").location, length: 4),
                       "a label the review named, without an address, by name")
        XCTAssertTrue(view.canGoBack)
    }

    /// Back from a place opened under a popover's "Used at" — here in another
    /// function — returns to the name the popover was opened on: selected and
    /// flashed, as the call a jump was made from is. It flashed the function's
    /// name in its signature and scrolled up to it.
    func testBackFromAUseReturnsToTheNameThePopoverWasOpenedOn() throws {
        let a = "void A(void)\n{\n" + String(repeating: "  x = 0;\n", count: 40)
            + "  out(PCI_CONFIG_ADDRESS,1);\n}\n"
        let b = "void B(void)\n{\n  x = 1;\n  out(PCI_CONFIG_ADDRESS,2);\n}\n"
        let inA = (a as NSString).range(of: "PCI_CONFIG_ADDRESS")
        let inB = (b as NSString).range(of: "PCI_CONFIG_ADDRESS")
        let json: [String: Any] = [
            "script_version": 5, "program": ["image_base": "0x0"],
            "functions": [
                ["entry": "0x220", "name": "A", "c": a, "c_spans": [[inA.location, inA.length, "constant"]],
                 "instructions": [["address": "0x220", "bytes": "66 BA F8 0C", "mnemonic": "MOV", "text": "MOV DX,0xcf8"]]],
                ["entry": "0x230", "name": "B", "c": b, "c_spans": [[inB.location, inB.length, "constant"]],
                 "instructions": [["address": "0x230", "bytes": "90", "mnemonic": "NOP", "text": "NOP"],
                                  ["address": "0x231", "bytes": "66 BA F8 0C", "mnemonic": "MOV", "text": "MOV DX,0xcf8"]]]],
            "equates": [["name": "PCI_CONFIG_ADDRESS", "value": "0xCF8", "references": [["0x220", 1], ["0x231", 1]]]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: teModule(), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        // A popover shows only off a window on screen.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        textView.scrollRangeToVisible(inA)
        let scrolled = try scrollOrigin(of: textView)
        XCTAssertGreaterThan(scrolled, 0, "the name is down the function")
        XCTAssertFalse(view.clickC(at: inA.location + 1, event: try click(count: 1)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(view.shownExplanation)

        view.goToUse(2)
        XCTAssertEqual(view.selectedFunction?.name, "B")
        view.goBack()
        XCTAssertEqual(view.selectedFunction?.name, "A")
        XCTAssertEqual(textView.selectedRange(), inA, "the name the popover was opened on")
        XCTAssertEqual(view.lastFlash, .c(inA), "flashed, not the function's name")
        XCTAssertEqual(try scrollOrigin(of: textView), scrolled, accuracy: 0.5, "where it was scrolled")
    }

    /// A click on a name in a long function's C highlights at once: what
    /// each token names was once read by copying the whole text per token,
    /// 6.7 s for this function.
    func testAHighlightInALongFunctionIsQuick() throws {
        var c = "int Big(int Count)\n{\n  int Total;\n"
        var spans: [[Any]] = []
        func add(_ text: String, _ kind: String? = nil) {
            if let kind { spans.append([c.utf16.count, text.utf16.count, kind]) }
            c += text
        }
        for line in 0..<1500 {
            add("  "); add("Total", "local"); add(" = "); add("Total", "local"); add(" + ")
            add("Count", "parameter"); add(" + "); add("local_\(line % 40)", "local"); add(";\n")
        }
        c += "  return Total;\n}\n"
        let json: [String: Any] = [
            "script_version": 4, "ghidra": "12.1.2", "program": ["image_base": "0x0"],
            "functions": [["entry": "0x220", "name": "Big", "c": c, "c_spans": spans,
                           "instructions": [["address": "0x220", "bytes": "56", "mnemonic": "PUSH", "text": "PUSH ESI"]]]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })

        let start = Date()
        XCTAssertFalse(view.clickC(at: try XCTUnwrap(spans[2][0] as? Int), event: try click(count: 1)))
        XCTAssertEqual(view.highlightedSymbol, .variable("Count"))
        XCTAssertEqual(textView.highlightedRanges.count, 1500)
        XCTAssertFalse(view.clickC(at: try XCTUnwrap(spans[0][0] as? Int), event: try click(count: 1)))
        XCTAssertEqual(textView.highlightedRanges.count, 3000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "two clicks, 6000 names")
    }

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

    /// A click on a name the review explained opens what it stands for: a
    /// constant's value, enum and words with the instructions that hold it;
    /// a type's C; a field's line in it. A name nobody explained opens nothing.
    func testAClickOnAnExplainedNameOpensWhatItStandsFor() throws {
        let c = "void ResetEntry(SEC_SERIAL_DEVICE_INFO *Info)\n{\n  out(PCI_CONFIG_ADDRESS,Info->BaudRate);\n}\n"
        let text = c as NSString
        func at(_ word: String) -> Int { text.range(of: word).location }
        let structC = "struct SEC_SERIAL_DEVICE_INFO {\n    /* 0x00 */ UINT32 Base; // I/O base\n"
            + "    /* 0x04 */ UINT32 BaudRate; // bits per second\n} /* size 0x8 */;"
        let json: [String: Any] = [
            "script_version": 5, "program": ["image_base": "0x0"],
            "functions": [[
                "entry": "0x220", "name": "ResetEntry", "c": c,
                "c_spans": [[at("SEC_SERIAL_DEVICE_INFO"), 22, "type"], [at("PCI_CONFIG_ADDRESS"), 18, "constant"],
                            [at("Info->"), 4, "parameter"]],
                "c_fields": [[at("BaudRate"), 8, "SEC_SERIAL_DEVICE_INFO", 4]],
                "instructions": [["address": "0x220", "bytes": "66 BA F8 0C", "mnemonic": "MOV", "text": "MOV DX,0xcf8"]]
            ]],
            "equates": [["name": "PCI_CONFIG_ADDRESS", "value": "0xCF8", "enum": "FCH_IO_PORT",
                         "comment": "PCI configuration address port.", "references": [["0x220", 1]]]],
            "types": [["name": "SEC_SERIAL_DEVICE_INFO", "kind": "struct", "size": 8, "c": structC]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: teModule(), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        // A popover shows only off a window on screen.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func clickOn(_ word: String) throws -> CodeExplanation? {
            XCTAssertFalse(view.clickC(at: at(word) + 1, event: try click(count: 1)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return view.shownExplanation
        }

        // What explains itself is marked: underlined under the pointer, with
        // the question-mark pointer; a parameter is not.
        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let shown = textView.string as NSString
        XCTAssertEqual(Set(textView.explainable.map { shown.substring(with: $0) }),
                       ["SEC_SERIAL_DEVICE_INFO", "PCI_CONFIG_ADDRESS", "BaudRate"])
        let name = try XCTUnwrap(textView.explainable.first { shown.substring(with: $0) == "PCI_CONFIG_ADDRESS" })
        let glyphs = textView.layoutManager!.glyphRange(forCharacterRange: name, actualCharacterRange: nil)
        let box = textView.layoutManager!.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
        textView.hover(at: NSPoint(x: box.midX + textView.textContainerOrigin.x,
                                   y: box.midY + textView.textContainerOrigin.y))
        XCTAssertEqual(textView.hoveredLink, name)
        XCTAssertEqual(view.explainableInListing(("MOV DX,0xcf8", [CodeToken(start: 7, length: 5, kind: .constant)]),
                                                 line: 0), [NSRange(location: 7, length: 5)])

        let constant = try XCTUnwrap(try clickOn("PCI_CONFIG_ADDRESS"))
        XCTAssertEqual(constant.text, "PCI configuration address port.")
        XCTAssertEqual(constant.uses.map(\.line), [0])
        XCTAssertEqual(CodeExplanationPopover(explanation: constant, model: CodeModel(artifact: artifact, layout: nil))
                        .factsText(), "0xCF8 = 3320 · enum FCH_IO_PORT")
        XCTAssertEqual(try clickOn("SEC_SERIAL_DEVICE_INFO")?.c?.hasPrefix("struct SEC_SERIAL_DEVICE_INFO"), true)
        // A double click on a name that explains itself asks it too: it is a
        // question about the name, not a selection of the word.
        view.shownExplanationClose()
        XCTAssertFalse(view.clickC(at: at("SEC_SERIAL_DEVICE_INFO") + 1, event: try click(count: 2)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(view.shownExplanation?.subject, .type("SEC_SERIAL_DEVICE_INFO"))
        view.shownExplanationClose()
        let field = try XCTUnwrap(try clickOn("BaudRate"))
        XCTAssertEqual(field.name, "SEC_SERIAL_DEVICE_INFO.BaudRate")
        XCTAssertEqual(field.text, "bits per second")
        XCTAssertEqual(CodeExplanationPopover.lineRange(in: structC, offset: 4, name: "BaudRate").map {
            (structC as NSString).substring(with: $0) }, "    /* 0x04 */ UINT32 BaudRate; // bits per second")
        view.shownExplanationClose()
        XCTAssertNil(try clickOn("Info"), "a parameter explains nothing")
        XCTAssertEqual(CodePaneView.listingNumber("0xcf8"), 0xCF8)
        XCTAssertEqual(CodePaneView.listingNumber("-0x1"), UInt64.max)
        XCTAssertNil(CodePaneView.listingNumber("DX"))

        // A press on an explained name that becomes a drag selecting text
        // opens nothing when it ends: it was a selection, not a question.
        // A place under "Used at" is a move: Back returns to the C the
        // popover was opened over, even when the use is in the same function
        // and on the instruction already selected.
        XCTAssertNotNil(try clickOn("PCI_CONFIG_ADDRESS"))
        let back = view.canGoBack
        view.goToUse(0)
        XCTAssertTrue(view.canGoBack, "the use is a place Back returns from")
        view.goBack()
        XCTAssertEqual(view.canGoBack, back)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: at("PCI_CONFIG_ADDRESS"), length: 18),
                       "back at the name the popover was opened on")

        view.shownExplanationClose()
        XCTAssertFalse(view.clickC(at: at("PCI_CONFIG_ADDRESS") + 1, event: try click(count: 1)))
        textView.setSelectedRange(NSRange(location: at("PCI_CONFIG_ADDRESS"), length: 30))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(view.shownExplanation, "a selection, not a click")
    }

    /// The one line for the blocks the decompiler removed explains itself:
    /// a click lists the blocks, a long list scrolls, a block goes to its line.
    func testTheRemovedBlocksLineListsWhereTheyAre() throws {
        let summary = "/* WARNING: Removing 20 unreachable blocks */"
        let c = "void Entry(void)\n{\n  \(summary)\n  return;\n}\n"
        let at = (c as NSString).range(of: summary)
        let instructions = (0..<21).map { index -> [String: Any] in
            ["address": String(format: "0x%X", 0x220 + index), "bytes": "90", "mnemonic": "NOP", "text": "NOP"]
        }
        let json: [String: Any] = [
            "script_version": 5, "program": ["image_base": "0x0"],
            "functions": [[
                "entry": "0x220", "name": "Entry", "c": c,
                "c_spans": [[at.location, at.length, "comment"]],
                "c_unreachable": [at.location, at.length, (1...20).map { String(format: "0x%X", 0x220 + $0) }],
                "instructions": instructions
            ]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: teModule(), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let shown = textView.string as NSString
        XCTAssertEqual(textView.explainable.map { shown.substring(with: $0) }, [summary])
        let place = shown.range(of: summary).location
        XCTAssertFalse(view.clickC(at: place + 3, event: try click(count: 1)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let removed = try XCTUnwrap(view.shownExplanation)
        XCTAssertEqual(removed.subject, .unreachable(blocks: 20))
        XCTAssertEqual(removed.uses.map(\.line), Array(1...20))
        let popover = CodeExplanationPopover(explanation: removed, model: CodeModel(artifact: artifact, layout: nil))
        XCTAssertEqual(popover.title(), "Unreachable blocks")
        XCTAssertEqual(popover.factsText(), "20 blocks removed from the C")
        XCTAssertNotNil(popover.wordsText())
        let scroll = try XCTUnwrap(first(NSScrollView.self, in: popover.view) { $0.documentView is NSStackView },
                                   "twenty blocks scroll")
        XCTAssertEqual((scroll.documentView as? NSStackView)?.arrangedSubviews.count, 20)
        view.shownExplanationClose()
    }

    /// A type's line longer than the popover scrolls sideways in its box.
    /// A named global in the C is a link that explains itself on a click:
    /// its type and place, what the image holds there, the review's words
    /// and the instructions that use it. ⌘-click still selects its bytes.
    func testAClickOnAGlobalSaysWhatItIs() throws {
        let c = "void F(void)\n{\n  Port = mPort;\n}\n"
        let at = (c as NSString).range(of: "mPort")
        let json: [String: Any] = [
            "script_version": 5, "program": ["image_base": "0x0"],
            "functions": [[
                "entry": "0x220", "name": "F", "c": c,
                "c_spans": [[at.location, at.length, "global", "0x230"]],
                "instructions": [["address": "0x220", "bytes": "66 A1", "mnemonic": "MOV", "text": "MOV AX,[0x220]",
                                  "references": [["to": "0x230", "type": "READ"]]]]
            ]],
            "symbols": [["address": "0x230", "name": "mPort", "type": "UINT16", "source": "USER_DEFINED",
                         "comment": "The port the board's EC answers on. Source: the board's schematic."]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        var module = teModule()
        module[0x78] = 0x56
        module[0x79] = 0x57
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: module, hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let shown = textView.string as NSString
        XCTAssertEqual(textView.explainable.map { shown.substring(with: $0) }, ["mPort"])
        XCTAssertFalse(view.clickC(at: shown.range(of: "mPort").location + 1, event: try click(count: 1)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let global = try XCTUnwrap(view.shownExplanation)
        XCTAssertEqual(global.subject, .global(CodeAddress(0x230)))
        XCTAssertEqual(global.value, "0x5756 = 22358", "the two bytes at 0x78, little-endian")
        XCTAssertEqual(global.uses.map(\.line), [0])
        let popover = CodeExplanationPopover(explanation: global, model: CodeModel(artifact: artifact, moduleBytes: module))
        XCTAssertEqual(popover.factsText(), "UINT16 at address 0x78\nIn the image: 0x5756 = 22358")
        let stack = try XCTUnwrap(popover.view as? NSStackView)
        XCTAssertEqual((stack.arrangedSubviews.last as? NSTextField)?.stringValue, "Source: the board's schematic.")
        view.shownExplanationClose()

        // A selection the reader left in the C does not swallow the click:
        // only a selection this click makes does.
        view.shownExplanationClose()
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertFalse(view.clickC(at: shown.range(of: "mPort").location + 1, event: try click(count: 1)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(view.shownExplanation?.subject, .global(CodeAddress(0x230)))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        view.shownExplanationClose()

        // A double click on a name that explains itself asks it, as a click
        // does — it does not move to the name's bytes.
        var selected: Range<UInt64>?
        view.onSelectRange = { selected = $0 }
        XCTAssertFalse(view.clickC(at: shown.range(of: "mPort").location + 1, event: try click(count: 2)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(view.shownExplanation?.subject, .global(CodeAddress(0x230)))
        XCTAssertNil(selected, "a double click does not go to the bytes")

        // ⌘ is how the global's bytes are asked for: both of a UINT16, not its first.
        XCTAssertTrue(view.clickC(at: shown.range(of: "mPort").location + 1,
                                  event: try click(count: 1, flags: .command)))
        XCTAssertEqual(selected, 0x78..<0x7A)
        // The bytes moved, the code did not: the function on screen is the one
        // the reader was on, no place was added, and the place the reader stays
        // on keeps no mark of the global's name — Back and Forward walk the
        // code as if the selection had not happened.
        XCTAssertEqual(view.selectedFunction?.name, "F")
        XCTAssertFalse(view.canGoBack, "a link to data is not a place")
        XCTAssertNil(view.carriedHistory.views.last?.cMark)
    }

    /// A ⌘-click on a global selects its bytes in the dump, and the hex
    /// view's report of that selection must not move the code: data is no
    /// instruction, and the line nearest before it belongs to whatever
    /// function ended there. (PeiResetSystem's `gPeiCoreGuid` opened
    /// InternalMathDivRemU64x32 this way, the last function before the data.)
    func testTheBytesOfAGlobalDoNotSteerTheCode() throws {
        let c = "void F(void)\n{\n  Port = g;\n}\n"
        let at = (c as NSString).range(of: "Port = g")
        let json: [String: Any] = [
            "script_version": 5, "program": ["image_base": "0x0"],
            "functions": [
                ["entry": "0x220", "name": "F", "c": c,
                 "c_spans": [[at.location + 7, 1, "global", "0x240"]],
                 "instructions": [["address": "0x220", "bytes": "8B 00", "mnemonic": "MOV",
                                   "text": "MOV AX,[0x240]"]]],
                ["entry": "0x230", "name": "G", "c": "void G(void)\n{\n}\n",
                 "instructions": [["address": "0x230", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]
            ],
            "symbols": [["address": "0x240", "name": "g", "type": "UINT16", "source": "USER_DEFINED"]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: teModule(), hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.restore(function: 0, instruction: nil, showsC: true)
        view.layoutSubtreeIfNeeded()

        // The app's wiring: the selection made in the dump is reported back to
        // the code panel, which is what used to move it.
        var selected: Range<UInt64>?
        view.onSelectRange = { range in
            selected = range
            view.selectModuleRange(range)
        }
        XCTAssertTrue(view.clickC(at: at.location + 7, event: try click(count: 1, flags: .command)))
        XCTAssertEqual(selected, 0x88..<0x8A, "the global's two bytes at module offset 0x88")
        XCTAssertEqual(view.selectedFunction?.name, "F", "the code stays on the function it was on")
    }

    /// A click in the C drops the selection it had, whether the name under the
    /// pointer is a global (a link), a type that explains itself, or plain
    /// code: one behavior, not two. (A global's click used to keep the
    /// selection, a type's to drop it.)
    func testAClickInTheCDropsTheSelectionUnderEveryNameAlike() throws {
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        view.isEditable = false
        view.isSelectable = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        let text = NSMutableAttributedString(string: "Port = gPeiCoreGuid; struct T x;")
        let string = text.string as NSString
        let global = string.range(of: "gPeiCoreGuid")
        let type = string.range(of: "T x")
        text.addAttribute(.link, value: "code:4", range: global)
        view.textStorage?.setAttributedString(text)
        view.explainable = [global, NSRange(location: type.location, length: 1)]
        view.onClick = { _, _ in false }
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        func down(at range: NSRange) throws -> NSEvent {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let point = view.convert(NSPoint(x: box.midX + view.textContainerOrigin.x,
                                             y: box.midY + view.textContainerOrigin.y), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                                   modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        for range in [global, NSRange(location: type.location, length: 1)] {
            view.setSelectedRange(NSRange(location: 0, length: 4))
            view.mouseDown(with: try down(at: range))
            XCTAssertEqual(view.selectedRange().length, 0, "the click drops the selection")
        }
    }

    /// Copying a linked name puts the name on the clipboard. AppKit writes a
    /// copied link as a URL beside the text, and that URL is the pane's own
    /// token — a selection of just `gPeiCoreGuid` reached the clipboard as
    /// `code:4`, which is no name at all.
    func testCopyingALinkedNamePutsTheNameItselfOnTheClipboard() throws {
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let text = NSMutableAttributedString(string: "Port = gPeiCoreGuid;")
        text.addAttribute(.link, value: "code:4", range: NSRange(location: 7, length: 12))
        view.textStorage?.setAttributedString(text)
        view.setSelectedRange(NSRange(location: 7, length: 12))

        let board = NSPasteboard(name: .init("CodePaneViewTests.copy"))
        view.copySelectedText(to: board)
        XCTAssertEqual(board.string(forType: .string), "gPeiCoreGuid")
        XCTAssertNil(board.string(forType: .URL), "no URL of the pane's own token")
        for type in board.types ?? [] where type.rawValue.contains("rtf") || type.rawValue.contains("url") {
            XCTFail("\(type.rawValue) is on the clipboard beside the text")
        }
    }

    /// What a name stands for reads first; its source is the last paragraph,
    /// smaller, under the uses and the C.
    func testTheSourceIsTheLastParagraph() throws {
        let json: [String: Any] = ["script_version": 5, "functions": []]
        let model = CodeModel(artifact: try JSONDecoder().decode(CodeArtifact.self,
                                                                 from: JSONSerialization.data(withJSONObject: json)),
                              layout: nil)
        let popover = CodeExplanationPopover(
            explanation: CodeExplanation(subject: .type("T"), name: "T", enumName: nil, kind: "struct", size: 4,
                                         declaration: nil, text: "The UART SEC reports through. Source: EDK2 SerialPortLib.",
                                         c: "struct T {\n};", uses: []),
            model: model)
        let stack = try XCTUnwrap(popover.view as? NSStackView)
        let labels = stack.arrangedSubviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue == "The UART SEC reports through." })
        let last = try XCTUnwrap(stack.arrangedSubviews.last as? NSTextField)
        XCTAssertEqual(last.stringValue, "Source: EDK2 SerialPortLib.")
        XCTAssertLessThan(last.font?.pointSize ?? 99, labels[2].font?.pointSize ?? 0, "smaller than the words")
    }

    func testALongLineOfATypeScrollsSideways() throws {
        let long = "struct T {\n    /* 0x00 */ UINT32 Size; // " + String(repeating: "a long comment ", count: 20) + "\n};"
        let json: [String: Any] = ["script_version": 5, "functions": []]
        let model = CodeModel(artifact: try JSONDecoder().decode(CodeArtifact.self,
                                                                 from: JSONSerialization.data(withJSONObject: json)),
                              layout: nil)
        let popover = CodeExplanationPopover(
            explanation: CodeExplanation(subject: .type("T"), name: "T", enumName: nil, kind: "struct", size: 4,
                                         declaration: nil, text: nil, c: long, uses: []),
            model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = popover.view
        popover.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(all(NSScrollView.self, in: popover.view).first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.width, scroll.contentView.bounds.width + 100,
                             "the text is as wide as its longest line")
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 100)
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

    /// A p-code operation's name — SIDT, which Ghidra writes as
    /// InterruptDescriptorTableRegister() — is marked and explained like any
    /// other name: it is an instruction, and the popover says so and titles it
    /// with the mnemonic.
    func testAPCodeOperationOpensItsInstruction() throws {
        let c = "void PeiDispatcher(void)\n{\n  InterruptDescriptorTableRegister(&Idtr);\n}\n"
        let at = (c as NSString).range(of: "InterruptDescriptorTableRegister").location
        let json: [String: Any] = [
            "script_version": 6, "program": ["image_base": "0x0"],
            "functions": [[
                "entry": "0x100", "name": "PeiDispatcher", "c": c,
                "c_spans": [[at, 32, "pcode"]],
                "instructions": [["address": "0x100", "bytes": "0F 01 08", "mnemonic": "SIDT",
                                  "text": "SIDT dword ptr [EAX]"]]
            ]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self,
                                                from: JSONSerialization.data(withJSONObject: json))
        let view = CodePaneView(manifest: manifest(), artifact: artifact, moduleBytes: teModule(), hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.restore(function: 0, instruction: nil, showsC: true)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let textView = try XCTUnwrap(first(CodeTextView.self, in: view) { _ in true })
        let shown = textView.string as NSString
        XCTAssertEqual(textView.explainable.map { shown.substring(with: $0) },
                       ["InterruptDescriptorTableRegister"], "the name is clickable")
        XCTAssertFalse(view.clickC(at: at + 1, event: try click(count: 1)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let explained = try XCTUnwrap(view.shownExplanation)
        XCTAssertEqual(explained.subject, .pcodeOperation("InterruptDescriptorTableRegister"))
        let popover = CodeExplanationPopover(explanation: explained,
                                             model: CodeModel(artifact: artifact, layout: nil))
        XCTAssertEqual(popover.title(), "SIDT / LIDT")
        let words = popover.wordsText() ?? ""
        XCTAssertTrue(words.contains("p-code operation"))
        XCTAssertTrue(words.contains("nothing is returned"), "the load form is explained too: \(words)")
    }

    /// The round help button after the ASM/C switch opens the page about the
    /// code panel.
    func testTheHeaderOpensTheHelpForTheCodePanel() throws {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 400)
        view.layoutSubtreeIfNeeded()
        let help = try XCTUnwrap(all(HelpButton.self, in: view).first)
        XCTAssertEqual(help.opens, .topic(.codePanel))
        let mode = try XCTUnwrap(all(NSSegmentedControl.self, in: view)
            .first { $0.segmentCount == 3 && $0.label(forSegment: 1) == "C" })
        let helpRect = view.convert(help.bounds, from: help)
        let modeRect = view.convert(mode.bounds, from: mode)
        XCTAssertLessThan(helpRect.maxX, modeRect.minX, "the help button stands before the switch")
        XCTAssertEqual(helpRect.midY, modeRect.midY, accuracy: 1.5, "one line with it")
    }

    /// The menu lists every analysis newest first — the order the agent's
    /// `code_modules` gives them. The one shown keeps its place, so a line
    /// where it is not on top says a newer analysis exists.
    func testTheMenuListsEveryAnalysisNewestFirst() throws {
        var older = manifest()
        older.recipe = AnalysisRecipe(id: "code-v0-ghidra-12.0", exporter: 0,
                                      ghidra: "12.0", script: "ExportCode.java")
        older.analyzedAt = "2026-10-01T00:00:00+00:00"
        var newer = manifest()
        newer.recipe = AnalysisRecipe(id: "code-v3-ghidra-12.2", exporter: 3,
                                      ghidra: "12.2", script: "ExportCode.java")
        newer.analyzedAt = "2026-10-20T00:00:00+00:00"
        var newest = manifest()
        newest.recipe = AnalysisRecipe(id: "code-v4-ghidra-12.3", exporter: 4,
                                       ghidra: "12.3", script: "ExportCode.java")
        newest.analyzedAt = "2026-10-27T00:00:00+00:00"
        // The analysis shown is of 2026-10-25 — newer than one of the others,
        // older than another, and it is not moved to the top.
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView(),
                                recipes: [older, newer, newest])
        XCTAssertEqual(view.offeredRecipes.map(\.recipe.id),
                       ["code-v4-ghidra-12.3", "code-v2-ghidra-12.1.2",
                        "code-v3-ghidra-12.2", "code-v0-ghidra-12.0"])
    }

    /// The line wears its ground while the menu is up and under the pointer,
    /// and takes it off when the menu closes without a choice.
    func testTheGroundGoesWhenTheMenuCloses() {
        let line = CodeVersionsLine(frame: NSRect(x: 0, y: 0, width: 120, height: 14))
        line.onOpen = {}
        XCTAssertFalse(line.showsGround, "no ground at rest")
        line.menuOpened()
        XCTAssertTrue(line.showsGround, "the line stays marked while its menu is up")
        line.menuClosed()
        XCTAssertFalse(line.showsGround, "a menu dismissed untouched leaves no ground")
    }

    /// An enum member is marked on the line that names it — and a member
    /// whose name only starts the same way is not it.
    func testAnEnumMemberIsMarkedOnItsOwnLine() throws {
        let c = "enum EFI_STATUS {\n    EFI_SUCCESS = 0x0,\n    EFI_LOAD_ERROR = 0x80000001,\n"
            + "    EFI_LOAD_ERROR_2 = 0x2\n}"
        let range = try XCTUnwrap(CodeExplanationPopover.memberRange(in: c, name: "EFI_LOAD_ERROR"))
        XCTAssertEqual((c as NSString).substring(with: range), "    EFI_LOAD_ERROR = 0x80000001,")
        XCTAssertNil(CodeExplanationPopover.memberRange(in: c, name: "EFI_NOT_HERE"))
    }

    /// In the panel the strip carries every group the module has functions in,
    /// in the grouped order's sequence, and it goes away with another list.
    func testThePanelShowsTheStripForTheFunctionsOnly() throws {
        let suiteName = "CodeReadinessBarTests.panel"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        CodePaneView.defaults = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            CodePaneView.defaults = .standard
        }
        let art = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":8,"program":{"image_base":"0x0"},
         "functions":[
          {"entry":"0x100","name":"Done","review_level":"full","instructions":[]},
          {"entry":"0x200","name":"Partly","review_level":"partial","instructions":[]},
          {"entry":"0x300","name":"FUN_00000300","review_level":"decompiled","instructions":[]},
          {"entry":"0x400","name":"FUN_00000400","review_level":"decompiled","instructions":[]},
          {"entry":"0x500","name":"External","review_level":"no_body","instructions":[]}]}
        """.utf8))
        let view = CodePaneView(manifest: manifest(), artifact: art,
                                moduleBytes: moduleBytes, hexView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.navigatorReadinessIsShown)
        XCTAssertEqual(view.navigatorReadiness.map { $0.group }, [.full, .partial, .decompiled, .noBody])
        XCTAssertEqual(view.navigatorReadiness.map { $0.count }, [1, 1, 2, 1])

        view.selectList(.strings)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.navigatorReadinessIsShown, "the strip speaks about the functions")
    }
}

/// A view that lays its subviews out top-down, as a table's document view
/// does — the hierarchy a row's chevron is drawn in.
private final class FlippedTestView: NSView {
    override var isFlipped: Bool { true }
}

/// The readiness strip between the list's switch and the rows: the review's
/// groups, each as wide as its share of the module's functions.
@MainActor
final class CodeReadinessBarTests: XCTestCase {
    /// Widths follow the counts, and a group too small to see keeps a point
    /// taken from the widest one.
    func testTheStripDividesItsWidthByTheCounts() {
        XCTAssertEqual(CodeReviewReadinessBar.widths([3, 1], in: 40), [30, 10])
        XCTAssertEqual(CodeReviewReadinessBar.widths([1, 1, 2], in: 40), [10, 10, 20])
        XCTAssertEqual(CodeReviewReadinessBar.widths([], in: 40), [])

        // 552 functions: two of them would be a tenth of a point; each still
        // shows, and the strip is still exactly as wide as its room.
        let widths = CodeReviewReadinessBar.widths([2, 550], in: 100)
        XCTAssertEqual(widths[0], 1, accuracy: 0.001, "a group of two still shows")
        XCTAssertEqual(widths.reduce(0, +), 100, accuracy: 0.001)
        XCTAssertGreaterThan(widths[1], widths[0])
    }

    /// The strip says what its colours are in words, from the names the group
    /// headings already have.
    func testTheStripSaysItsCountsInWords() {
        let words = CodeReviewReadinessBar.words([
            (group: .full, count: 3), (group: .decompiled, count: 523)
        ])
        XCTAssertEqual(words, "Fully reviewed 3, Decompiler only 523")
    }


}
