import AppPalette
import AgentKit
import Localization
import ToolModuleKit
import XCTest
import UEFIImage
@testable import UEFIToolUI
@testable import ByteRipper

/// An agent's annotations (`Design/AGENT_PLAN.md`, "Annotations"; issue
/// #37): made, listed, related and removed through the service; drawn by the
/// pane and explained under the pointer; listed in the tab's Notes panel;
/// kept with the file when it closes, and drawn again when it opens. And the
/// person's own notes beside them.
@MainActor
final class AgentAnnotationTests: XCTestCase {
    private var controller: MainViewController?
    private var window: NSWindow?
    private var service: AgentService!
    private var client: AgentTestClient!
    private var defaultsName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        let desk = AgentDesk(controllers: { [weak self] in self?.controller.map { [$0] } ?? [] },
                             keyController: { [weak self] in self?.controller })
        service = AgentService(desk: desk, defaults: defaults,
                               socketPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        client = AgentTestClient(service)
    }

    override func tearDown() {
        NotesWindowController.discardForTesting()
        mainWindowController = nil
        controller?.windowModel.pane1.close()
        window?.orderOut(nil)
        window = nil
        controller = nil
        discardIsolatedDefaults(defaultsName, defaults)
        super.tearDown()
    }

    @discardableResult
    private func open(_ size: Int = 0x1000) throws -> MainViewController {
        try open(bytes: (0..<size).map { UInt8(truncatingIfNeeded: $0) })
    }

    @discardableResult
    private func open(bytes: [UInt8]) throws -> MainViewController {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        try controller.windowModel.pane1.open(url: tempFile(bytes, "agent-annotation"))
        controller.apply(mode: .singleFile)
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        return controller
    }

    private var pane: PaneViewModel { controller!.windowModel.pane1 }

    /// The Annotations window's cards, the window shown and laid out.
    private func notes(raised: Bool = true) throws -> AgentAnnotationCards {
        let notes = NotesWindowController.instance
        if raised { notes.show(tabbedWith: window) }
        notes.window?.layoutIfNeeded()
        notes.cards.collection.layoutSubtreeIfNeeded()
        return notes.cards
    }

    /// A window as the app makes it — with its toolbar — holding the tab.
    private var mainWindowController: MainWindowController?

    @discardableResult
    private func openInAppWindow() throws -> MainWindowController {
        let made = MainWindowController(frameAutosaveName: nil)
        mainWindowController = made
        controller = made.mainViewController
        window = made.window
        made.showWindow(nil)
        try made.mainViewController.windowModel.pane1.open(url: tempFile([UInt8](repeating: 0, count: 0x100), "agent-annotation"))
        made.mainViewController.apply(mode: .singleFile)
        for _ in 0..<4 {
            made.window?.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        return made
    }

    // MARK: - The tools

    func testAnAnnotationIsDrawnOnThePaneAndListed() async throws {
        try open()
        let made = try await client.answer("annotate", ["offset": "0x10", "length": 4, "title": "Signature",
                                                        "note": "The magic the parser looks for."])
        XCTAssertEqual(made["id"], "a1")
        XCTAssertEqual(made["range"], ["start": "0x10", "end": "0x14", "length": "0x4"])
        XCTAssertEqual(made["document"], "d1")
        XCTAssertTrue(made["path"]?.stringValue?.contains("agent-annotation") == true, "\(made)")
        XCTAssertEqual(pane.agentAnnotations.map(\.title), ["Signature"])
        XCTAssertEqual(pane.hexAgentMarkSpans(in: 0..<0x100).map(\.range), [0x10..<0x14])

        let listed = try await client.answer("annotations")["annotations"]?.arrayValue
        XCTAssertEqual(listed?.count, 1)
        XCTAssertEqual(listed?.first?["note"], "The magic the parser looks for.")
        let one = try await client.answer("annotate", ["offset": "0x20", "title": "One byte"])
        XCTAssertEqual(one["range"]?["length"], "0x1", "a place is a byte unless told otherwise")
    }

    /// A pointer and what it points at: the relation is kept, and goes when
    /// either end does.
    func testARelationNamesAnotherAnnotationAndGoesWithIt() async throws {
        try open()
        _ = try await client.answer("annotate", ["offset": "0x100", "length": 0x40, "title": "Table"])
        let pointer = try await client.answer("annotate", ["offset": "0x20", "length": 4, "title": "Pointer",
                                                           "related_to": ["a1"]])
        XCTAssertEqual(pointer["related_to"], ["a1"])

        let unknown = try await client.call("annotate", ["offset": 0, "title": "X", "related_to": ["a9"]])
        XCTAssertEqual(unknown.answer, "No annotation a9. Call `annotations` for the ones there are.")

        let removed = try await client.answer("remove_annotations", ["ids": ["a1"]])
        XCTAssertEqual(removed["removed"], ["a1"])
        XCTAssertEqual(pane.agentAnnotations.map(\.id), ["a2"])
        XCTAssertEqual(pane.agentAnnotations.first?.relatedTo, [], "the relation went with its other end")
    }

    func testAnAnnotationPastTheEndOrWithoutATitleOrAPlaceIsRefused() async throws {
        try open(0x100)
        let past = try await client.call("annotate", ["offset": "0xF0", "length": "0x20", "title": "Tail"])
        XCTAssertTrue(past.answer.stringValue?.hasSuffix(" (d1), which is 0x100 bytes long.") == true, "\(past.answer)")
        let empty = try await client.call("annotate", ["offset": 0, "title": "  "])
        XCTAssertTrue(empty.isError)
        let zero = try await client.call("annotate", ["offset": 0, "length": 0, "title": "Nothing"])
        XCTAssertTrue(zero.isError)
        let root = try await client.call("annotate", ["offset": 0, "node": "root", "title": "Root"])
        XCTAssertTrue(root.isError, "the top of the tree is no node")
        XCTAssertTrue(pane.agentAnnotations.isEmpty)
    }

    func testRemovingAllClearsEveryFile() async throws {
        try open()
        _ = try await client.answer("annotate", ["offset": 0, "title": "A"])
        _ = try await client.answer("annotate", ["offset": 2, "title": "B"])
        let removed = try await client.answer("remove_annotations", ["all": true])
        XCTAssertEqual(removed["removed"], ["a1", "a2"])
        XCTAssertTrue(pane.agentAnnotations.isEmpty)
        let refused = try await client.call("remove_annotations")
        XCTAssertTrue(refused.isError, "a removal that names nothing removes nothing")
    }

    // MARK: - On screen

    /// The note is what the pointer resting on the bytes shows — the
    /// innermost annotation's, where two overlap.
    func testTheTooltipIsTheInnermostAnnotationsTitleAndNote() async throws {
        try open()
        _ = try await client.answer("annotate", ["offset": 0, "length": 0x100, "title": "Region"])
        _ = try await client.answer("annotate", ["offset": 0x10, "length": 4, "title": "Signature", "note": "Magic."])
        XCTAssertEqual(pane.hexAgentMarkTooltip(at: 0x11), "Signature\nMagic.")
        XCTAssertEqual(pane.hexAgentMarkTooltip(at: 0x80), "Region")
        XCTAssertEqual(pane.hexAgentMarkTooltip(at: 0x200), "")
    }

    /// An annotation belongs to the file: another file in the pane does not
    /// show it, the list keeps it, and the file opened again shows it again.
    func testAnAnnotationOutlivesItsFileClosingAndReturnsWithIt() async throws {
        let controller = try open()
        let url = try XCTUnwrap(pane.document?.url)
        _ = try await client.answer("annotate", ["offset": 0x10, "length": 2, "title": "A"])
        try controller.windowModel.pane1.open(url: tempFile([1, 2, 3], "agent-annotation-other"))
        XCTAssertTrue(pane.agentAnnotations.isEmpty, "not on another file")
        controller.windowModel.pane1.close()
        let listed = try await client.answer("annotations")
        XCTAssertEqual(listed["total"], 1, "kept when its file closed")
        XCTAssertNil(listed["annotations"]?.arrayValue?.first?["document"], "and says it is not open")

        try controller.windowModel.pane1.open(url: url)
        XCTAssertEqual(pane.agentAnnotations.map(\.title), ["A"], "drawn again when the file is opened")
        XCTAssertEqual(pane.hexAgentMarkSpans(in: 0..<0x100).map(\.range), [0x10..<0x12])
    }

    /// A file that is not open is annotated by its path; showing the
    /// annotation opens it.
    func testAFileNotOpenIsAnnotatedByPathAndOpenedToShowIt() async throws {
        let controller = try open()
        let url = try XCTUnwrap(pane.document?.url)
        controller.windowModel.pane1.close()
        let made = try await client.answer("annotate", ["path": .string(url.path), "offset": "0x40", "length": 4,
                                                        "title": "Result", "note": "What was found here."])
        XCTAssertNil(made["document"])
        var opened: URL?
        service.annotationTools.openInNewTab = { [weak self] file in
            opened = file
            try? self?.pane.open(url: file)
        }
        service.annotationTools.show("a1")
        XCTAssertEqual(opened, url)
        let selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x40..<0x44)
        XCTAssertEqual(pane.agentAnnotations.map(\.title), ["Result"])

        let missing = try await client.call("annotate", ["path": "/nonexistent/file.bin", "offset": 0, "title": "X"])
        XCTAssertEqual(missing.answer, "There is no file at /nonexistent/file.bin.")
    }

    // MARK: - The Annotations window

    func testTheNotesWindowListsAnnotationsWithTheirRelationsAndStandsEmptyWithout() async throws {
        let controller = try open()
        let notesWindow = NotesWindowController.instance
        notesWindow.show(tabbedWith: window)
        XCTAssertFalse(notesWindow.emptyView.isHidden, "no notes: the empty screen")
        XCTAssertTrue(notesWindow.cards.scroll.isHidden)
        _ = try await client.answer("annotate", ["offset": "0x100", "length": 0x40, "title": "Table"])
        _ = try await client.answer("annotate", ["offset": "0x20", "length": 4, "title": "Pointer", "related_to": ["a1"]])
        let list = try notes()
        let name = try XCTUnwrap(pane.document?.url.lastPathComponent)
        // A card: the title, the file and the place, the note,
        // and the annotations it is about as links.
        // A file that is all padding has no node worth naming: the place is
        // said by its addresses.
        XCTAssertEqual(list.shownTexts(of: "a1"), ["Table", "● \(name)", "0x100–0x140"])
        XCTAssertEqual(list.shownTexts(of: "a2"), ["Pointer", "● \(name)", "0x20–0x24",
                                                   "→ a1 Table"])
        let pointer = try XCTUnwrap(list.collection.visibleItems().compactMap { $0.view as? AnnotationCardView }
            .first { $0.texts.first == "Pointer" })
        let link = try XCTUnwrap(pointer.subviews.compactMap { $0 as? NSButton }.first { $0.title == "→ a1 Table" })
        XCTAssertGreaterThan(link.frame.width, 0, "the relation is drawn, not only listed")
        XCTAssertLessThanOrEqual(link.frame.maxY, pointer.bounds.height - AnnotationCardView.padding + 0.5)
        list.select("a1")
        XCTAssertEqual(list.selectedIDs, ["a1"])
        XCTAssertEqual(pane.hexAgentMarkTooltip(at: 0x20), "Pointer\nRelated Annotations: a1 Table")

        XCTAssertTrue(notesWindow.emptyView.isHidden)
        XCTAssertTrue(controller.fragments.isEmpty, "nothing in the tab's dock")

        service.annotationTools.remove { _ in true }
        XCTAssertTrue(pane.agentAnnotations.isEmpty)
        XCTAssertFalse(notesWindow.emptyView.isHidden, "the window stays, empty")
        XCTAssertTrue(notesWindow.window?.isVisible == true)
    }

    /// The agent's notes made while the Annotations window is not in front
    /// are counted on the toolbar's button, in the agent's hue, until it
    /// is; one made while it is in front is seen at once. The window opens
    /// as a tab beside the dump's, and closes like one.
    func testTheToolbarButtonCountsTheAgentsNotesUntilTheWindowIsInFront() async throws {
        let main = try openInAppWindow()
        let toolbar = try XCTUnwrap(main.window?.toolbar)
        let ids = toolbar.items.map(\.itemIdentifier)
        XCTAssertEqual(ids.firstIndex(of: .notes), ids.firstIndex(of: .segments).map { $0 + 1 }, "right after Segments")
        let item = try XCTUnwrap(main.notesItem)
        XCTAssertNil(item.view, "a plain item, drawn as Segments and Find are")
        XCTAssertEqual(item.image?.accessibilityDescription, "Annotations")
        let badge = main.notesBadge
        _ = try await client.answer("annotate", ["offset": 0, "title": "A"])
        _ = try await client.answer("annotate", ["offset": 2, "title": "B"])
        XCTAssertNil(NotesWindowController.shared, "nothing opens the window but the person")
        XCTAssertEqual(badge.count, 2)
        XCTAssertFalse(badge.isHidden)
        let button = try XCTUnwrap(badge.superview as? NSButton, "on the button the toolbar drew")
        XCTAssertEqual(button.action, #selector(MainViewController.showNotesWindow(_:)))
        // Beside the digit, the badge is the agent's notes' colour — whose
        // the new notes are — as a square of that colour beside it draws it:
        // drawn off the window, the colour lands in another colour space.
        final class Swatch: NSView {
            var fill = NSColor.clear
            override func draw(_ dirtyRect: NSRect) { fill.setFill(); bounds.fill() }
        }
        func pixel(of view: NSView) throws -> NSColor {
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            return try XCTUnwrap(image.colorAt(x: image.pixelsWide * 2 / 14, y: image.pixelsHigh / 2)?
                .usingColorSpace(.sRGB))
        }
        let swatch = Swatch(frame: badge.frame)
        button.addSubview(swatch, positioned: .below, relativeTo: badge)
        defer { swatch.removeFromSuperview() }
        swatch.fill = ZoneColors.agent
        let drawn = try pixel(of: badge)
        let agent = try pixel(of: swatch)
        for (got, expected) in [(drawn.redComponent, agent.redComponent), (drawn.greenComponent, agent.greenComponent),
                                (drawn.blueComponent, agent.blueComponent)] {
            XCTAssertEqual(got, expected, accuracy: 0.02, "\(drawn) is the agent's \(agent)")
        }

        main.mainViewController.showNotesWindow(nil)
        let notesWindow = try XCTUnwrap(NotesWindowController.shared?.window)
        XCTAssertTrue(notesWindow.isVisible)
        XCTAssertEqual(notesWindow.tabGroup?.windows.contains { $0 === main.window }, true, "a tab beside the dump's")
        XCTAssertEqual(service.annotationTools.unseen, [])
        XCTAssertEqual(badge.count, 0)
        XCTAssertTrue(badge.isHidden)
        _ = try await client.answer("annotate", ["offset": 4, "title": "C"])
        XCTAssertEqual(badge.count, 0, "made while the window is in front")

        // ⌘W closes it like a tab; the notes stay, and new ones are counted.
        NotesWindowController.shared?.closeDocument()
        XCTAssertFalse(notesWindow.isVisible)
        XCTAssertEqual(service.annotationTools.all().count, 3)
        _ = try await client.answer("annotate", ["offset": 6, "title": "D"])
        XCTAssertEqual(badge.count, 1)
        main.mainViewController.showNotesWindow(nil)
        XCTAssertTrue(notesWindow.isVisible, "the same window, opened again")
        XCTAssertTrue(NotesWindowController.shared?.window === notesWindow)
        XCTAssertEqual(badge.count, 0)
    }

    /// The app speaks Russian: the Annotations window does, and the agent is
    /// answered in English.
    func testTheWindowSpeaksTheAppsLanguageAndTheAgentEnglish() async throws {
        try await withAppLanguage(.russian) {
            try open(bytes: try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
            let made = try await client.answer("annotate", ["offset": "0x28", "length": 4, "title": "Signature"])
            _ = try notes()
            let notesWindow = try XCTUnwrap(NotesWindowController.shared)
            XCTAssertEqual(notesWindow.window?.title, "Заметки")
            let label = try XCTUnwrap(made["label"]?.stringValue)
            XCTAssertNil(label.range(of: "\\p{Cyrillic}", options: .regularExpression), "the agent reads English: \(label)")
        }
    }

    /// The person's note on a selection: right-click ▸ Add Annotation…, kept and
    /// drawn as the agent's is, in the person's hue, without the agent's
    /// picture, and never counted as unseen.
    func testThePersonsNoteIsMadeOnTheSelectionInTheirHue() async throws {
        let controller = try open()
        pane.select(range: 0x30..<0x38)
        let menu = controller.makeOffsetMenu(for: pane, offset: 0x31)
        let item = try XCTUnwrap(menu.items.first { $0.action == #selector(MainViewController.addNoteToSelection(_:)) })
        XCTAssertEqual(item.title, "Add Annotation…")

        let id = try await service.annotationTools.addNote(title: "Board ID", note: "Checked by hand.",
                                                          on: 0x30..<0x38, of: pane)
        let note = try XCTUnwrap(service.annotationTools.all().first { $0.id == id })
        XCTAssertEqual(note.author, .person)
        XCTAssertEqual(note.range, 0x30..<0x38)
        XCTAssertEqual(service.annotationTools.unseen, [])
        XCTAssertEqual(pane.hexAgentMarkSpans(in: 0..<0x100).map(\.byPerson), [true])
        let listed = try await client.answer("annotations")["annotations"]?.arrayValue
        XCTAssertEqual(listed?.first?["author"], "person", "the agent is told whose it is")

        _ = try await client.answer("annotate", ["offset": 0, "title": "Agent's"])
        let cards = try notes()
        let views = cards.collection.visibleItems().compactMap { $0.view as? AnnotationCardView }
        let person = try XCTUnwrap(views.first { $0.texts.first == "Board ID" })
        let agent = try XCTUnwrap(views.first { $0.texts.first == "Agent's" })
        XCTAssertFalse(person.showsAgentIcon)
        XCTAssertTrue(agent.showsAgentIcon, "the agent's note wears its picture")
        XCTAssertEqual(person.hue, ZoneColors.person)
        XCTAssertNotNil(person.editButton, "the person's note wears the pencil")
        XCTAssertNil(agent.editButton, "the agent's does not")
        service.annotationTools.update(id, title: "Board ID, checked", note: "Twice.")
        let edited = try XCTUnwrap(service.annotationTools.all().first { $0.id == id })
        XCTAssertEqual([edited.title, edited.note], ["Board ID, checked", "Twice."])
        XCTAssertEqual(edited.range, 0x30..<0x38, "the place stays")
        XCTAssertEqual(edited.author, .person)
        XCTAssertEqual(agent.hue, ZoneColors.agent)
    }

    /// A row of UEFI Structure: right-click ▸ Add Annotation… puts the
    /// person's note on the node — one inside a compressed section in the
    /// bytes it decompresses to, with the codec its card shows.
    func testThePersonsNoteIsMadeOnANodeOfTheTree() async throws {
        let controller = try open(bytes: try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let tools = controller.surface.tools
        tools.activate(ToolRegistry.uefiStructure, animated: false)
        var outline: NSOutlineView?
        let listed = await settle {
            outline = self.descendants(of: tools.panel, NSOutlineView.self).first
            guard let outline, outline.numberOfRows > 0,
                  let row = outline.item(atRow: 0) as? UEFITreeRow else { return false }
            return self.pane.uefiState.tree?.node(row.id) != nil
        }
        XCTAssertTrue(listed, treeState(tools))
        let tree = try XCTUnwrap(outline)
        let rect = tree.rect(ofRow: 0)
        let point = tree.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: tree.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(tree.menu(for: event), treeState(tools))
        XCTAssertTrue(menu.items.contains { $0.title == "Add Annotation…" }, "\(menu.items.map(\.title))")

        let found = try await client.answer("find_bytes", ["node": "root", "text": "GH51G"])
        let node = try XCTUnwrap(found["matches"]?.arrayValue?.first?["node"]?["id"]?.stringValue, "\(found)")
        let id = try await service.annotationTools.addNote(title: "Model", note: "", node: node, of: pane)
        let note = try XCTUnwrap(service.annotationTools.all().first { $0.id == id })
        XCTAssertEqual(note.author, .person)
        XCTAssertEqual(note.node, node)
        XCTAssertEqual(note.decoded?.codecs.map(\.text), ["LZMA"], "kept in the decompressed bytes")
        XCTAssertEqual(service.annotationTools.unseen, [], "the person's own is never unseen")
    }

    /// Cards go in as many columns as the width holds, each into the shortest
    /// one; Delete removes the selected; the place's node is named as UEFI
    /// Structure names it.
    func testTheCardsFillTheShortestColumnAndDeleteRemoves() async throws {
        try open(0x1000)
        _ = try await client.answer("annotate", ["offset": 0, "title": "Long",
                                                 "note": .string(String(repeating: "A long note that wraps. ", count: 12))])
        _ = try await client.answer("annotate", ["offset": 1, "title": "Short"])
        _ = try await client.answer("annotate", ["offset": 2, "title": "Third"])
        XCTAssertEqual(AnnotationMasonryLayout.columns(forWidth: 500), 1)
        XCTAssertEqual(AnnotationMasonryLayout.columns(forWidth: 800), 2)
        XCTAssertEqual(AnnotationMasonryLayout.columns(forWidth: 1200), 3)

        window?.setContentSize(NSSize(width: 820, height: 600))
        let cards = try notes()
        XCTAssertEqual(cards.rows.map(\.id), ["a3", "a2", "a1"], "the newest first")
        // Long last: the two short cards side by side, the long one under the
        // first of them, which ends higher than nothing does.
        service.annotationTools.arrange(["a1", "a2", "a3"])
        NotesWindowController.shared?.refresh()
        cards.collection.layoutSubtreeIfNeeded()
        let frames = try XCTUnwrap(cards.collection.collectionViewLayout as? AnnotationMasonryLayout).itemFrames
        XCTAssertEqual(frames.count, 3)
        XCTAssertGreaterThan(frames[0].height, frames[1].height, "the long note makes a taller card")
        XCTAssertGreaterThan(frames[1].minX, frames[0].minX, "the second card beside the first")
        XCTAssertEqual(frames[2].minX, frames[1].minX, "the third under the shorter one")

        cards.select("a2")
        cards.collection.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)))
        XCTAssertEqual(service.annotationTools.all().map(\.id), ["a1", "a3"])
    }

    /// A card is as tall as its text laid out at the card's width: a note that
    /// wraps to several lines stays inside the outline.
    func testACardHoldsAllOfItsWrappedText() throws {
        let content = AnnotationCardView.Content(
            id: "a2", title: "LBLDESP: панель 2560×1600", isOpen: true,
            file: "SPI_C86018_128Mbit.03022026.orig.bin", codecs: ["XOR C0"], address: "0x14F–0x155", path: nil,
            site: "LBLDESP",
            note: "Lenovo Panel descriptor: здесь width=0x0A00 (2560), height=0x0640 (1600). "
                + "В другом дампе 1920×1080 — другая модель экрана.",
            related: [])
        for width: CGFloat in [200, 260, 330, 420] {
            let sizer = AnnotationCardView()
            sizer.show(content)
            let height = ceil(sizer.height(forWidth: width))
            let card = AnnotationCardView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            card.show(content)
            card.layoutSubtreeIfNeeded()
            let bottom = card.subviews.flatMap { [$0] + $0.subviews }.map { card.convert($0.bounds, from: $0).maxY }.max() ?? 0
            XCTAssertLessThanOrEqual(bottom, height - AnnotationCardView.padding + 0.5, "width \(width): text ends at \(bottom), card is \(height)")
            for field in card.subviews.flatMap({ [$0] + $0.subviews }).compactMap({ $0 as? NSTextField }) {
                let needs = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.frame.width, height: 10_000)).height ?? 0
                XCTAssertGreaterThanOrEqual(field.frame.height, needs, "width \(width): \(field.stringValue) is cut")
                if field.cell?.wraps == false {
                    XCTAssertGreaterThanOrEqual(field.frame.width, field.cell?.cellSize.width ?? 0,
                                                "width \(width): \(field.stringValue) is cut at its end")
                }
            }
        }
    }

    /// A node's name too long for its line wraps under its own start, beside
    /// the badges, and every line of it stays inside the card.
    func testALongNodeNameWrapsUnderItsOwnStart() throws {
        let site = "AmiTseSetupDataFile: LZMA compressed section: Raw section of the setup data"
        let content = AnnotationCardView.Content(
            id: "a3", title: "Setup", isOpen: true, file: "dump.bin", codecs: ["LZMA"],
            address: nil, path: nil, site: site, note: "", related: [])
        let width: CGFloat = 220
        let sizer = AnnotationCardView()
        sizer.show(content)
        let card = AnnotationCardView(frame: NSRect(x: 0, y: 0, width: width, height: ceil(sizer.height(forWidth: width))))
        card.show(content)
        card.layoutSubtreeIfNeeded()
        let line = try XCTUnwrap(card.subviews.compactMap { $0 as? AnnotationPlaceLine }.first)
        let badge = try XCTUnwrap(line.subviews.first { $0 is PartBadgeView })
        let link = try XCTUnwrap(line.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == site })
        let oneLine = link.cell?.cellSize.height ?? 0
        XCTAssertGreaterThan(link.frame.height, oneLine * 1.5, "the name takes more than one line")
        XCTAssertGreaterThan(link.frame.minX, badge.frame.maxX, "it wraps under its start, not under the badge")
        XCTAssertLessThanOrEqual(card.convert(link.bounds, from: link).maxX, width - AnnotationCardView.padding + 0.5)
        XCTAssertLessThanOrEqual(card.convert(link.bounds, from: link).maxY, card.bounds.height - AnnotationCardView.padding + 0.5)
    }

    /// The same, for the cards the Notes panel shows.
    func testTheWindowsCardsHoldAllOfTheirText() async throws {
        try open(0x1000)
        for index in 0..<4 {
            _ = try await client.answer("annotate", [
                "offset": .int(Int64(index * 16)), "length": 6, "title": .string("LBLDESP: панель 2560×1600 \(index)"),
                "note": .string("Lenovo Panel descriptor: здесь width=0x0A00 (2560), height=0x0640 (1600). "
                                + String(repeating: "В другом дампе 1920×1080 — другая модель экрана. ", count: index + 1))])
        }
        let window = try XCTUnwrap(self.window)
        let saved = ToolPanelFont.defaults.object(forKey: ToolPanelFont.zoomSizeKey)
        defer { ToolPanelFont.defaults.set(saved, forKey: ToolPanelFont.zoomSizeKey) }
        for (width, zoom) in [(420.0, 13.0), (700, 13), (1100, 13), (420, 17), (700, 17)] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.layoutIfNeeded()
            ToolPanelFont.defaults.set(zoom, forKey: ToolPanelFont.zoomSizeKey)
            NotificationCenter.default.post(name: ToolPanelFont.zoomDidChangeNotification, object: nil)
            window.layoutIfNeeded()
            let cards = try notes()
            XCTAssertFalse(cards.collection.visibleItems().isEmpty)
            for item in cards.collection.visibleItems() {
                let card = item.view
                card.layoutSubtreeIfNeeded()
                let bottom = card.subviews.flatMap { [$0] + $0.subviews }.map { card.convert($0.bounds, from: $0).maxY }.max() ?? 0
                XCTAssertLessThanOrEqual(bottom, card.bounds.height - AnnotationCardView.padding + 0.5,
                                         "window \(width), card \(card.frame): text ends at \(bottom)")
            }
        }
    }

    /// A double-click on a row goes to its bytes, and Back comes back.
    func testShowingAnAnnotationSelectsItsBytesAsAStep() async throws {
        let controller = try open(0x10000)
        _ = try await client.answer("annotate", ["offset": "0x8000", "length": 8, "title": "Far"])
        service.annotationTools.show("a1")
        let selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x8000..<0x8008)
        XCTAssertTrue(controller.canNavigateBack)
    }

    func testRevealBringsThePlaceOnScreen() async throws {
        try open(0x10000)
        _ = try await client.answer("annotate", ["offset": "0x9000", "length": 2, "title": "Here", "reveal": true])
        let selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x9000..<0x9002)
    }

    // MARK: - Decoded bytes

    /// A match `find_bytes` found in what a compressed section decompresses
    /// to is annotated as `node` and `node_offset`: the place is kept in those
    /// bytes, not drawn over the whole section; the card wears the codec's
    /// badge before the addresses; showing it opens the decompressed bytes in
    /// a fragment panel, with the place selected and drawn there.
    func testAPlaceInDecompressedBytesIsShownInAPanelOfThem() async throws {
        let controller = try open(bytes: try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let found = try await client.answer("find_bytes", ["node": "root", "text": "GH51G"])
        let match = try XCTUnwrap(found["matches"]?.arrayValue?.first)
        let node = try XCTUnwrap(match["node"]?["id"]?.stringValue)
        let made = try await client.answer("annotate", [
            "node": .string(node), "offset": try XCTUnwrap(match["node_offset"]), "length": 5, "title": "Model"])
        XCTAssertNil(made["range"], "no bytes of the file: \(made)")
        let decoded = try XCTUnwrap(made["decoded"])
        XCTAssertEqual(decoded["codecs"], ["LZMA"])
        XCTAssertEqual(decoded["node"], match["section"], "the section the panel opens")
        XCTAssertEqual(decoded["range"]?["start"], match["buffer_start"])
        XCTAssertEqual(decoded["range"]?["end"], match["buffer_end"])
        XCTAssertTrue(pane.agentAnnotations.isEmpty, "the compressed section is not outlined")

        let name = try XCTUnwrap(pane.document?.url.lastPathComponent)
        XCTAssertEqual(Array(try notes(raised: false).shownTexts(of: "a1").dropFirst().prefix(2)),
                       ["● \(name)", "LZMA LZMA compressed section: Raw"],
                       "the file after the dot saying it is open, and under it the badge before the node, named as the search results name it")

        service.annotationTools.show("a1")
        let opened = await settle { controller.fragments.panelsLinked(to: self.pane).count == 1 }
        XCTAssertTrue(opened, "a panel opens")
        let part = try XCTUnwrap(controller.fragments.panelsLinked(to: pane).first.flatMap(controller.fragments.pane))
        let selected = await settle { part.hexSelection().start != 0 }
        XCTAssertTrue(selected)
        let selection = part.hexSelection()
        XCTAssertEqual(try part.byteStorage?.read(at: selection.start, length: Int(selection.end - selection.start)),
                       Array("GH51G".utf8), "the place is selected")
        XCTAssertEqual(part.agentAnnotations.map(\.title), ["Model"], "and drawn in the panel")
        // UEFI Structure in the panel, open to the node that holds the place.
        let id = try XCTUnwrap(controller.fragments.panelsLinked(to: pane).first)
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        XCTAssertEqual(surface.tools.activeIdentifier, ToolRegistry.uefiStructure)
        let raw = await settle {
            guard let outline = self.descendants(of: surface.tools.panel, NSOutlineView.self).first,
                  outline.selectedRow >= 0,
                  let row = outline.item(atRow: outline.selectedRow) as? UEFITreeRow,
                  let node = part.uefiState.tree?.node(row.id) else { return false }
            return node.kind == .section && node.subtype == 0x19
        }
        XCTAssertTrue(raw, "the raw section holding the place is selected in the panel's tree")
        XCTAssertEqual(part.hexAgentMarkSpans(in: 0..<part.fileSize).map(\.range), [selection.start..<selection.end])

        service.annotationTools.show("a1")
        _ = await settle(0.5)
        XCTAssertEqual(controller.fragments.panelsLinked(to: pane).count, 1, "the open panel is used again")
    }

    /// A place given by its addresses in a LENV block stored encoded — as a
    /// survey's answers give it, on a file open or opened in the background
    /// — is read decoded: the card wears the XOR badge, and showing it opens
    /// the block decoded.
    func testAnAddressInAnEncodedLENVBlockIsReadDecoded() async throws {
        let controller = try open(bytes: LenovoTestImage.make())
        let offset = String(format: "0x%X", LenovoTestImage.serialInBlock2)
        let made = try await client.answer("annotate", ["offset": .string(offset), "length": 8, "title": "Serial"])
        XCTAssertEqual(made["decoded"]?["codecs"], ["XOR 77"], "\(made)")
        XCTAssertNotNil(made["range"], "the file's bytes are outlined too")

        let url = try XCTUnwrap(pane.document?.url)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("lenv-\(UUID().uuidString).bin")
        try FileManager.default.copyItem(at: url, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        _ = try await client.answer("open_dump", ["path": .string(copy.path)])
        let byPath = try await client.answer("annotate", ["path": .string(copy.path), "offset": .string(offset),
                                                          "length": 8, "title": "Serial elsewhere"])
        XCTAssertEqual(byPath["decoded"]?["codecs"], ["XOR 77"], "a file the survey opened: \(byPath)")

        service.annotationTools.show("a1")
        let opened = await settle { controller.fragments.panelsLinked(to: self.pane).count == 1 }
        XCTAssertTrue(opened, "the block opens decoded")
        let part = try XCTUnwrap(controller.fragments.panelsLinked(to: pane).first.flatMap(controller.fragments.pane))
        let selected = await settle { !part.hexSelection().isEmpty }
        XCTAssertTrue(selected)
        let selection = part.hexSelection()
        XCTAssertEqual(try part.byteStorage?.read(at: selection.start, length: Int(selection.end - selection.start)),
                       Array("PF0TEST1".utf8), "the serial, decoded, is selected")
    }

    /// A card of a file that is not open: showing it opens the file and then
    /// goes to the place as it would in an open one — once the file's tree
    /// has been read: a node opens UEFI Structure at it, a place in a LENV
    /// block stored encoded opens the block decoded in a panel.
    func testShowingAPlaceInAFileNotOpenWaitsForItsTree() async throws {
        let controller = try open(bytes: LenovoTestImage.make())
        let url = try XCTUnwrap(pane.document?.url)
        let offset = String(format: "0x%X", LenovoTestImage.serialInBlock2)
        _ = try await client.answer("annotate", ["offset": .string(offset), "length": 8, "title": "Serial"])
        controller.windowModel.pane1.close()
        service.annotationTools.openInNewTab = { [weak self] file in try? self?.pane.open(url: file) }

        service.annotationTools.show("a1")
        XCTAssertEqual(pane.document?.url, url, "the file is opened")
        let opened = await settle { controller.fragments.panelsLinked(to: self.pane).count == 1 }
        XCTAssertTrue(opened, "the block opens decoded once the tree is read")
        let part = try XCTUnwrap(controller.fragments.panelsLinked(to: pane).first.flatMap(controller.fragments.pane))
        let selected = await settle { !part.hexSelection().isEmpty }
        XCTAssertTrue(selected)
        let selection = part.hexSelection()
        XCTAssertEqual(try part.byteStorage?.read(at: selection.start, length: Int(selection.end - selection.start)),
                       Array("PF0TEST1".utf8))
    }

    /// A place annotated in a dump read only in the background — never on
    /// screen, so no branch of its tree has been opened in a tab — opens in
    /// a fragment panel the first time the file is opened for it: the
    /// branches down to the block or the section are opened first.
    func testAPlaceFromABackgroundDumpOpensItsPanelTheFirstTime() async throws {
        let controller = try open()
        for (bytes, length, expected) in [
            (LenovoTestImage.make(), 8, Array("PF0TEST1".utf8)),
            (try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"), 5, Array("GH51G".utf8))
        ] {
            let file = try tempFile(bytes, "agent-background")
            let dump = try await client.answer("open_dump", ["path": .string(file.path)])
            let document = try XCTUnwrap(dump["document"])
            let made: JSONValue
            if bytes.count == LenovoTestImage.make().count {
                made = try await client.answer("annotate", [
                    "path": .string(file.path), "offset": .string(String(format: "0x%X", LenovoTestImage.serialInBlock2)),
                    "length": .count(length), "title": "Serial"])
            } else {
                let found = try await client.answer("find_bytes", ["document": document, "node": "root", "text": "GH51G"])
                let match = try XCTUnwrap(found["matches"]?.arrayValue?.first)
                made = try await client.answer("annotate", [
                    "path": .string(file.path), "node": try XCTUnwrap(match["node"]?["id"]),
                    "offset": try XCTUnwrap(match["node_offset"]), "length": .count(length), "title": "Model"])
            }
            XCTAssertNotNil(made["decoded"], "\(made)")
            _ = try await client.answer("close_dump", ["document": document])
            service.annotationTools.openInNewTab = { [weak self] url in try? self?.pane.open(url: url) }

            service.annotationTools.show(try XCTUnwrap(made["id"]?.stringValue))
            // Seconds on a real image: the window says it is reading, in the
            // sheet other long reads put up, until the place is reached.
            let sheet = controller.presentedViewControllers?.first as? BlockingOperationSheet
            XCTAssertNotNil(sheet, "the reading is shown, not silent")
            let opened = await settle { controller.fragments.panelsLinked(to: self.pane).count == 1 }
            let gone = await settle { controller.presentedViewControllers?.isEmpty ?? true }
            XCTAssertTrue(gone, "the sheet goes once the place is reached")
            XCTAssertTrue(opened, "the panel opens on the first show of \(expected.count == 8 ? "LENV" : "LZMA")")
            let part = try XCTUnwrap(controller.fragments.panelsLinked(to: pane).first.flatMap(controller.fragments.pane))
            let selected = await settle { !part.hexSelection().isEmpty }
            XCTAssertTrue(selected)
            let selection = part.hexSelection()
            XCTAssertEqual(try part.byteStorage?.read(at: selection.start, length: Int(selection.end - selection.start)),
                           expected)
            for id in controller.fragments.panelsLinked(to: pane) { controller.fragments.close(id, animated: false) }
            controller.tools.activate(nil, animated: false)
            pane.close()
        }
    }

    /// The same for a node of the file's own bytes: UEFI Structure opens at it.
    func testShowingANodeInAFileNotOpenOpensUEFIStructureAtIt() async throws {
        let controller = try open(bytes: try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        _ = try await client.answer("annotate", ["offset": "0x28", "length": 4, "title": "Signature"])
        controller.windowModel.pane1.close()
        controller.tools.activate(nil, animated: false)
        service.annotationTools.openInNewTab = { [weak self] file in try? self?.pane.open(url: file) }

        service.annotationTools.show("a1")
        let tools = controller.surface.tools
        let shown = await settle {
            guard tools.activeIdentifier == ToolRegistry.uefiStructure,
                  let outline = self.descendants(of: tools.panel, NSOutlineView.self).first,
                  outline.selectedRow >= 0,
                  let row = outline.item(atRow: outline.selectedRow) as? UEFITreeRow,
                  let node = self.pane.uefiState.tree?.node(row.id) else { return false }
            return node.kind == .volume
        }
        XCTAssertTrue(shown, "UEFI Structure at the volume: \(treeState(tools))")
    }

    /// Annotated in a part of the decompressed bytes, the place stays in them.
    func testAPlaceInAPartOfDecompressedBytesStaysThere() async throws {
        try open(bytes: try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let found = try await client.answer("find_bytes", ["node": "root", "text": "GH51G"])
        let match = try XCTUnwrap(found["matches"]?.arrayValue?.first)
        let opened = try await client.answer("open_part", ["node": try XCTUnwrap(match["section"]),
                                                          "part": "decompressed"])
        let made = try await client.answer("annotate", [
            "document": try XCTUnwrap(opened["document"]), "offset": try XCTUnwrap(match["buffer_start"]),
            "length": 5, "title": "Model"])
        XCTAssertEqual(made["from_part"]?["decoded"], true, "\(made)")
        XCTAssertNil(made["range"], "not the whole section in the file")
        XCTAssertEqual(made["decoded"]?["range"]?["start"], match["buffer_start"])
        XCTAssertEqual(made["decoded"]?["codecs"], ["LZMA"])
        XCTAssertNotNil(made["path"], "the file's annotation")
    }

    /// The ✕ in a card's corner removes that annotation alone.
    func testTheCrossOnACardRemovesIt() async throws {
        try open()
        _ = try await client.answer("annotate", ["offset": 0, "title": "A"])
        _ = try await client.answer("annotate", ["offset": 2, "title": "B"])
        let cards = try notes()
        let card = try XCTUnwrap(cards.collection.item(at: IndexPath(item: 1, section: 0))?.view)
        let cross = try XCTUnwrap(descendants(of: card, AnnotationRemoveBadge.self).first)
        // On the top right corner, standing out of the card.
        XCTAssertEqual(cross.frame.maxX, card.bounds.maxX + AnnotationCardView.removeOverhang, accuracy: 0.5)
        XCTAssertEqual(cross.frame.minY, -AnnotationCardView.removeOverhang, accuracy: 0.5)
        XCTAssertTrue(card.frame.minY - AnnotationCardView.removeOverhang >= 0, "inside the list's margin")
        let outside = NSPoint(x: card.frame.maxX + 3, y: card.frame.minY - 3)
        XCTAssertTrue(cards.collection.hitTest(outside) === cross, "a click beyond the card's edge reaches it")
        cross.click()
        XCTAssertEqual(service.annotationTools.all().map(\.title), ["B"], "the second card is the older one")
    }

    /// The ✕'s disc is the paper the cards lie on, in either theme — a white
    /// disc was the brightest thing in a dark panel.
    @MainActor
    func testTheCrossIsFilledWithTheThemesBackground() throws {
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let badge = AnnotationRemoveBadge { }
            badge.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            badge.appearance = NSAppearance(named: name)
            let rep = try XCTUnwrap(badge.bitmapImageRepForCachingDisplay(in: badge.bounds))
            badge.cacheDisplay(in: badge.bounds, to: rep)
            // Inside the disc, clear of the outline and of the cross's arms.
            let scale = CGFloat(rep.pixelsWide) / badge.bounds.width
            let fill = try XCTUnwrap(rep.colorAt(x: Int(10 * scale), y: Int(5 * scale))?
                .usingColorSpace(.deviceRGB))
            if dark {
                XCTAssertLessThan(fill.brightnessComponent, 0.4, "a dark disc in a dark theme: \(fill)")
            } else {
                XCTAssertGreaterThan(fill.brightnessComponent, 0.9, "a light disc in a light theme: \(fill)")
            }
        }
    }

    /// A place in the tab's own panes folds a fragment panel standing over
    /// them, so the selection is not behind it.
    func testShowingAPlaceInTheDumpFoldsAFragmentPanel() async throws {
        let controller = try open(0x10000)
        let opened = try await client.answer("open_part", ["offset": "0x100", "length": "0x100"])
        XCTAssertNotNil(opened["document"])
        XCTAssertNotNil(controller.fragments.expanded, "the part's panel is up")
        _ = try await client.answer("annotate", ["document": "d1", "offset": "0x8000", "length": 8, "title": "Far"])
        service.annotationTools.show("a1")
        XCTAssertNil(controller.fragments.expanded, "folded to show the dump")
        let selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x8000..<0x8008)
    }

    /// A place in the dump that is a node of the tree opens UEFI Structure on
    /// the tab, at the node holding it; the bytes stay selected.
    func testAPlaceOnANodeOpensUEFIStructureAtIt() async throws {
        let controller = try open(bytes: try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let made = try await client.answer("annotate", ["offset": "0x28", "length": 4, "title": "Signature"])
        XCTAssertNotNil(made["label"], "the place is named by the tree: \(made)")
        let card = try notes(raised: false).shownTexts(of: "a1")
        XCTAssertEqual(card.count, 3, "\(card)")
        XCTAssertFalse(card[2].hasPrefix("0x"), "the node, not the addresses: \(card)")
        XCTAssertNotEqual(controller.surface.tools.activeIdentifier, ToolRegistry.uefiStructure)

        service.annotationTools.show("a1")
        let tools = controller.surface.tools
        XCTAssertEqual(tools.activeIdentifier, ToolRegistry.uefiStructure)
        let shown = await settle {
            guard let outline = self.descendants(of: tools.panel, NSOutlineView.self).first,
                  outline.selectedRow >= 0,
                  let row = outline.item(atRow: outline.selectedRow) as? UEFITreeRow,
                  let node = self.pane.uefiState.tree?.node(row.id) else { return false }
            return node.kind == .volume
        }
        XCTAssertTrue(shown, "the volume whose signature it is is selected in the tree: \(treeState(tools))")
        _ = await settle(0.3)
        let selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x28..<0x2C, "the bytes stay selected")
    }

    // MARK: - The cards' order, New, dragging, and the next launch

    private func card(_ title: String, in cards: AgentAnnotationCards) -> AnnotationCardView? {
        cards.collection.visibleItems().compactMap { $0.view as? AnnotationCardView }.first { $0.texts.first == title }
    }

    /// A note is New: made while the window is away, from when it comes into
    /// view; made while it is in view, at once. The marks go when the window
    /// goes out of view, and do not come back.
    func testANoteIsNewUntilTheWindowGoesOutOfView() async throws {
        let main = try openInAppWindow()
        _ = try await client.answer("annotate", ["offset": 0, "title": "Away"])
        main.mainViewController.showNotesWindow(nil)
        let cards = try notes(raised: false)
        XCTAssertEqual(cards.newIDs, ["a1"])
        XCTAssertNotNil(card("Away", in: cards)?.newTag, "the card wears the tag")
        XCTAssertEqual(card("Away", in: cards)?.newTag?.text, "New")

        _ = try await client.answer("annotate", ["offset": 2, "title": "Watched"])
        cards.collection.layoutSubtreeIfNeeded()
        XCTAssertEqual(cards.rows.map(\.id), ["a2", "a1"], "the newest card first")
        XCTAssertEqual(cards.newIDs, ["a1", "a2"])
        XCTAssertNotNil(card("Watched", in: cards)?.newTag, "made in view: new at once")

        NotesWindowController.shared?.closeDocument()
        XCTAssertEqual(cards.newIDs, [], "out of view, the marks go")
        main.mainViewController.showNotesWindow(nil)
        XCTAssertEqual(cards.newIDs, [], "and do not come back")
        // Turned away from while the new card was still fading in: once it
        // is in, no card keeps the tag.
        _ = await settle(AgentAnnotationCards.moveDuration + 0.2)
        cards.collection.layoutSubtreeIfNeeded()
        XCTAssertNil(card("Away", in: cards)?.newTag)
        XCTAssertNil(card("Watched", in: cards)?.newTag)
    }

    /// A card carried onto another takes its place, the others moving
    /// aside; let go, it stays there, and a new card still comes first.
    func testACardDraggedOntoAnotherTakesItsPlace() async throws {
        try open()
        for (offset, title) in [(0, "A"), (2, "B"), (4, "C")] {
            _ = try await client.answer("annotate", ["offset": .int(Int64(offset)), "title": .string(title)])
        }
        let cards = try notes()
        XCTAssertEqual(cards.rows.map(\.id), ["a3", "a2", "a1"])
        let layout = try XCTUnwrap(cards.collection.collectionViewLayout as? AnnotationMasonryLayout)
        let before = layout.itemFrames

        XCTAssertTrue(cards.beginCarry("a1", at: NSPoint(x: before[2].midX, y: before[2].midY)))
        XCTAssertTrue(cards.isCarrying)
        let place = try XCTUnwrap(cards.collection.item(at: IndexPath(item: 2, section: 0))?.view)
        XCTAssertTrue(place.isHidden || place.alphaValue == 0, "its place stands empty while it is carried")
        cards.moveCarry(to: NSPoint(x: before[0].midX, y: before[0].midY))
        XCTAssertEqual(cards.rows.map(\.id), ["a1", "a3", "a2"], "the others moved aside")
        _ = await settle(AgentAnnotationCards.moveDuration + 0.2)
        cards.collection.layoutSubtreeIfNeeded()
        let landing = try XCTUnwrap(cards.collection.item(at: IndexPath(item: 0, section: 0))?.view)
        XCTAssertTrue(landing.isHidden || landing.alphaValue == 0,
                      "where it will land stands empty while it is carried, not drawn there too")
        cards.moveCarry(to: NSPoint(x: before[0].midX + 2, y: before[0].midY + 2))
        XCTAssertEqual(cards.rows.map(\.id), ["a1", "a3", "a2"], "a pointer resting does not trade places")
        cards.endCarry()
        XCTAssertFalse(cards.isCarrying)
        XCTAssertEqual(service.annotationTools.ordered().map(\.id), ["a1", "a3", "a2"])
        _ = await settle(AgentAnnotationCards.moveDuration + 0.3)
        XCTAssertEqual(layout.itemFrames.map(\.origin), before.map(\.origin), "closed up, aligned as before")
        let landed = try XCTUnwrap(cards.collection.item(at: IndexPath(item: 0, section: 0))?.view)
        XCTAssertTrue(!landed.isHidden && landed.alphaValue == 1, "let go, it is drawn in its place")

        _ = try await client.answer("annotate", ["offset": 6, "title": "D"])
        XCTAssertEqual(service.annotationTools.ordered().map(\.id), ["a4", "a1", "a3", "a2"])
        XCTAssertEqual(service.annotationTools.all().map(\.id), ["a1", "a2", "a3", "a4"],
                       "the agent still lists them oldest first")
    }

    /// Two columns, three cards: the end of the shorter column is empty, and
    /// a card carried there takes the last place — the others closing up
    /// behind it, its own place filled.
    func testACardCarriedBelowTheShorterColumnGoesLast() async throws {
        try open()
        for (offset, title) in [(0, "A"), (2, "B"), (4, "C")] {
            _ = try await client.answer("annotate", ["offset": .int(Int64(offset)), "title": .string(title)])
        }
        let cards = try notes()
        let layout = try XCTUnwrap(cards.collection.collectionViewLayout as? AnnotationMasonryLayout)
        let frames = layout.itemFrames
        XCTAssertEqual(frames[2].minX, frames[0].minX, "C, B side by side; A under C")
        let below = NSPoint(x: frames[1].midX, y: frames[1].maxY + 40)
        XCTAssertLessThan(below.y, frames[2].maxY, "beside A, not below every card")

        XCTAssertTrue(cards.beginCarry("a3", at: NSPoint(x: frames[0].midX, y: frames[0].midY)))
        cards.moveCarry(to: below)
        XCTAssertEqual(cards.rows.map(\.id), ["a2", "a1", "a3"], "the last place")
        cards.endCarry()
        _ = await settle(AgentAnnotationCards.moveDuration + 0.3)
        XCTAssertEqual(service.annotationTools.ordered().map(\.id), ["a2", "a1", "a3"])
        XCTAssertEqual(layout.itemFrames.map(\.origin), frames.map(\.origin), "closed up")
    }

    /// A press with ⌘ or ⇧ only selects: on the node's link, a relation or
    /// the ✕ it lands on the card, not on them.
    func testAPressWithCommandOrShiftOnlySelects() async throws {
        try open()
        _ = try await client.answer("annotate", ["offset": 0, "title": "A"])
        _ = try await client.answer("annotate", ["offset": 2, "title": "B", "related_to": ["a1"]])
        let cards = try notes()
        let view = try XCTUnwrap(card("B", in: cards))
        let link = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "→ a1 A" })
        let cross = try XCTUnwrap(descendants(of: view, AnnotationRemoveBadge.self).first)
        func press(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: flags,
                                             timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1))
        }
        for (target, name) in [(link as NSView, "the relation"), (cross, "the ✕")] {
            let point = view.convert(NSPoint(x: target.frame.midX, y: target.frame.midY), to: view.superview)
            XCTAssertTrue(view.target(at: point, for: try press([])) === target, "a plain press reaches \(name)")
            XCTAssertTrue(view.target(at: point, for: try press(.command)) === view, "⌘: \(name) is the card")
            XCTAssertTrue(view.target(at: point, for: try press(.shift)) === view, "⇧: \(name) is the card")
        }
    }

    /// The Annotations window's toolbar has Back and Forward at its left, in
    /// place of the title, the help book at its right, and the Agent button
    /// beside it while the agent service is on; its tab wears the notes'
    /// picture.
    func testTheWindowsToolbarHasBackForwardHelpAndTheAgentButton() async throws {
        try open()
        _ = try notes()
        let notesWindow = try XCTUnwrap(NotesWindowController.shared)
        let toolbar = try XCTUnwrap(notesWindow.window?.toolbar)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), [.historyNavigation, .flexibleSpace, .help])
        XCTAssertEqual(notesWindow.window?.titleVisibility, .hidden, "Back and Forward where the title was")
        let history = try XCTUnwrap(toolbar.items.first as? NSToolbarItemGroup)
        XCTAssertEqual(history.subitems.map(\.action), [#selector(MainViewController.navigateBack),
                                                         #selector(MainViewController.navigateForward)])
        XCTAssertTrue(history.subitems.allSatisfy { $0.target === notesWindow })
        XCTAssertNotNil((toolbar.items.last as? NSMenuToolbarItem)?.menu, "the help book's menu")
        let tabTitle = try XCTUnwrap(notesWindow.window?.tab.attributedTitle)
        XCTAssertNotNil(tabTitle.attribute(.attachment, at: 0, effectiveRange: nil), "the notes' picture first")
        XCTAssertTrue(tabTitle.string.hasSuffix("Annotations"))
        notesWindow.syncAgentItem(enabled: true, connected: true)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier),
                       [.historyNavigation, .flexibleSpace, .help, .space, .agentWindow])
        let agent = try XCTUnwrap(toolbar.items.last)
        XCTAssertEqual(agent.action, #selector(AppDelegate.showAgentWindow(_:)))
        notesWindow.syncAgentItem(enabled: false)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), [.historyNavigation, .flexibleSpace, .help])
    }

    /// ⇧-click selects the cards from the one last clicked to the one
    /// clicked; ⌘-click adds one card, or takes it out again.
    func testShiftSelectsARunAndCommandOneCard() async throws {
        try open()
        for offset in [0, 2, 4, 6] {
            _ = try await client.answer("annotate", ["offset": .int(Int64(offset)), "title": "N"])
        }
        let cards = try notes()
        XCTAssertEqual(cards.rows.map(\.id), ["a4", "a3", "a2", "a1"])
        cards.select("a3")
        cards.click("a1", with: .shift)
        XCTAssertEqual(cards.selectedIDs, ["a3", "a2", "a1"], "a run, in the cards' order")
        cards.click("a4", with: .command)
        XCTAssertEqual(cards.selectedIDs, ["a4", "a3", "a2", "a1"], "one more")
        cards.click("a2", with: .command)
        XCTAssertEqual(cards.selectedIDs, ["a4", "a3", "a1"], "one taken out")
        cards.click("a3", with: .shift)
        XCTAssertEqual(cards.selectedIDs, ["a4", "a3"], "from the card last ⌘-clicked")
    }

    /// A note made by hand brings up the Annotations window, a step of the
    /// history: its Back returns to the bytes it was made on, and the tab's
    /// Forward comes to the window again.
    func testANoteMadeShowsTheWindowAndBackReturnsToItsPlace() async throws {
        let controller = try open()
        pane.select(range: 0x30..<0x38)
        try await service.annotationTools.addNote(title: "Board ID", note: "", on: 0x30..<0x38, of: pane)
        controller.showNotesWindow(leaving: pane)
        let notesWindow = try XCTUnwrap(NotesWindowController.shared)
        XCTAssertTrue(notesWindow.window?.isVisible == true, "the window comes up")
        XCTAssertTrue(notesWindow.canNavigateBack)
        XCTAssertFalse(notesWindow.canNavigateForward)

        pane.select(range: 0..<1)
        notesWindow.navigateBack()
        let selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x30..<0x38, "back where the note was made")
        XCTAssertTrue(controller.canNavigateForward, "the tab's Forward goes to the window again")
        XCTAssertTrue(notesWindow.canNavigateForward == false && !notesWindow.canNavigateBack)

        controller.navigateForward()
        XCTAssertTrue(NotesWindowController.isInView || notesWindow.window?.isVisible == true)
        XCTAssertTrue(notesWindow.canNavigateBack, "and its Back to the tab once more")
        notesWindow.navigateBack()
        XCTAssertTrue(controller.canNavigateForward)
        controller.navigateForward()
        XCTAssertTrue(notesWindow.canNavigateBack)
    }

    /// ⌘Z in the Annotations window undoes the removals made there, the last
    /// first: each card back where it stood, with the relations the others
    /// lost; ⇧⌘Z removes it again.
    func testUndoPutsRemovedCardsBackWhereTheyStood() async throws {
        try open()
        _ = try await client.answer("annotate", ["offset": 0, "title": "A"])
        _ = try await client.answer("annotate", ["offset": 2, "title": "B"])
        _ = try await client.answer("annotate", ["offset": 4, "title": "C", "related_to": ["a1"]])
        let cards = try notes()
        let notesWindow = try XCTUnwrap(NotesWindowController.shared)
        let store = try XCTUnwrap(service.annotationTools)
        store.arrange(["a2", "a3", "a1"])
        let original = store.all()
        let undo = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(MainViewController.redoEdit), keyEquivalent: "Z")
        XCTAssertFalse(notesWindow.validateMenuItem(undo), "nothing to undo yet")

        cards.onRemove(["a3"])
        cards.onRemove(["a1"])
        XCTAssertEqual(store.ordered().map(\.id), ["a2"])
        XCTAssertTrue(notesWindow.validateMenuItem(undo))

        notesWindow.undoEdit()
        XCTAssertEqual(store.ordered().map(\.id), ["a2", "a1"], "the last removal first, in its place")
        XCTAssertEqual(cards.selectedIDs, ["a1"], "and selected")
        notesWindow.undoEdit()
        XCTAssertEqual(store.ordered().map(\.id), ["a2", "a3", "a1"])
        XCTAssertEqual(store.all(), original, "as they were, the relation to A too")
        XCTAssertFalse(notesWindow.validateMenuItem(undo))
        _ = await settle(AgentAnnotationCards.moveDuration + 0.3)
        XCTAssertEqual(cards.rows.map(\.id), ["a2", "a3", "a1"])
        XCTAssertEqual(cards.shownTexts(of: "a3").last, "→ a1 A", "the card says the relation again")

        XCTAssertTrue(notesWindow.validateMenuItem(redo))
        notesWindow.redoEdit()
        XCTAssertEqual(store.ordered().map(\.id), ["a2", "a1"])
        notesWindow.undoEdit()
        XCTAssertEqual(store.ordered().map(\.id), ["a2", "a3", "a1"])
    }

    /// Everything an annotation holds — a place in decompressed bytes with
    /// its codecs, a node and its name, a relation, the author — and the
    /// cards' order and which are new come back on the next launch; the ids
    /// go on from where they were.
    func testTheAnnotationsAreKeptForTheNextLaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("annotations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Annotations.json")
        service.annotationTools.keep(in: url)
        try open(bytes: try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        _ = try await client.answer("annotate", ["offset": "0x28", "length": 4, "title": "Signature", "note": "Magic."])
        let found = try await client.answer("find_bytes", ["node": "root", "text": "GH51G"])
        let node = try XCTUnwrap(found["matches"]?.arrayValue?.first?["node"]?["id"]?.stringValue, "\(found)")
        try await service.annotationTools.addNote(title: "Model", note: "By hand.", node: node, of: pane)
        _ = try await client.answer("annotate", ["offset": 0, "title": "Pointer", "related_to": ["a1"]])
        service.annotationTools.arrange(["a1", "a3", "a2"])
        _ = await settle(0.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "written without being asked")

        let before = service.annotationTools.all()
        XCTAssertNotNil(before[1].decoded)
        let later = AgentAnnotationTools(desk: service.annotationTools.desk)
        later.keep(in: url)
        XCTAssertEqual(later.all(), before)
        XCTAssertEqual(later.ordered().map(\.id), ["a1", "a3", "a2"])
        XCTAssertEqual(later.fresh, service.annotationTools.fresh)
        XCTAssertEqual(later.unseen, service.annotationTools.unseen)
        XCTAssertEqual(later.all()[1].decoded?.codecs.map(\.text), ["LZMA"])
        XCTAssertEqual(AnnotationsFile.read(url)?.nextID, 4, "the next one is a4")
    }

    /// A card is as tall measured inside the collection's animated update —
    /// the cards moving aside for one being dragged — as outside it: there,
    /// setting a frame animates it, and a height read back from the frames
    /// came out ten points, the cards' lines drawn over each other.
    func testACardMeasuredWhileTheCardsMoveIsAsTallAsEver() async throws {
        try open()
        _ = try await client.answer("annotate", ["offset": 0, "title": "A", "note": "Under the title."])
        let cards = try notes()
        let layout = try XCTUnwrap(cards.collection.collectionViewLayout as? AnnotationMasonryLayout)
        cards.zoomChanged()
        let plain = layout.heightFor(0, 432)
        cards.zoomChanged()
        var moving: CGFloat = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = AgentAnnotationCards.moveDuration
            cards.collection.animator().performBatchUpdates({ moving = layout.heightFor(0, 432) },
                                                            completionHandler: nil)
        }, completionHandler: nil)
        XCTAssertGreaterThan(plain, 40)
        XCTAssertEqual(moving, plain)
    }

    /// ⌘A — Edit ▸ Select All, whose action selects every byte in a dump —
    /// selects every card; Delete then removes them all.
    func testSelectAllSelectsEveryCard() async throws {
        try open()
        for offset in [0, 2, 4] {
            _ = try await client.answer("annotate", ["offset": .int(Int64(offset)), "title": "N"])
        }
        _ = try notes()
        let notesWindow = try XCTUnwrap(NotesWindowController.shared)
        let item = NSMenuItem(title: "Select All", action: #selector(MainViewController.selectAllBytes), keyEquivalent: "a")
        XCTAssertTrue(NSApp.target(forAction: item.action!, to: nil, from: item) as AnyObject? === notesWindow
                      || notesWindow.responds(to: item.action!))
        XCTAssertTrue(notesWindow.validateMenuItem(item))
        notesWindow.selectAllBytes()
        XCTAssertEqual(Set(notesWindow.cards.selectedIDs), ["a1", "a2", "a3"])
    }

    /// A card removed fades out and the others move up to close the gap,
    /// animated; a card that named it is said again without it.
    func testRemovingACardClosesTheGapAnimated() async throws {
        try open()
        _ = try await client.answer("annotate", ["offset": 0, "title": "A"])
        _ = try await client.answer("annotate", ["offset": 2, "title": "B", "related_to": ["a1"]])
        _ = try await client.answer("annotate", ["offset": 4, "title": "C"])
        let cards = try notes()
        let layout = try XCTUnwrap(cards.collection.collectionViewLayout as? AnnotationMasonryLayout)
        XCTAssertEqual(cards.rows.map(\.id), ["a3", "a2", "a1"])
        let first = layout.itemFrames[0]
        cards.select("a3")
        cards.onRemove(["a3"])
        XCTAssertEqual(cards.rows.map(\.id), ["a2", "a1"])
        XCTAssertEqual(layout.itemFrames.first?.origin, first.origin, "the next card takes the first place")
        func drawn(_ title: String) -> Bool {
            descendants(of: cards.collection, AnnotationCardView.self).contains { $0.texts.first == title && !$0.isHidden }
        }
        XCTAssertTrue(drawn("C"), "the removed card fades out rather than vanishing")
        _ = await settle(AgentAnnotationCards.moveDuration + 0.3)
        XCTAssertFalse(drawn("C"))
        XCTAssertEqual(cards.collection.item(at: IndexPath(item: 0, section: 0))?.view.frame.origin, first.origin)

        service.annotationTools.remove { $0.id == "a1" }
        _ = await settle(AgentAnnotationCards.moveDuration + 0.3)
        XCTAssertEqual(cards.rows.map(\.id), ["a2"])
        XCTAssertEqual(cards.shownTexts(of: "a2").last?.hasPrefix("→"), false, "the relation went with it")
        let shown = try XCTUnwrap(card("B", in: cards))
        XCTAssertFalse(shown.texts.contains { $0.hasPrefix("→") }, "and the card on screen says so")
    }

    private func treeState(_ tools: ToolController) -> String {
        guard let outline = descendants(of: tools.panel, NSOutlineView.self).first else { return "no outline" }
        let rows = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? UEFITreeRow).flatMap { pane.uefiState.tree?.node($0.id) }.map { "\($0.kind)" } }
        return "selected \(outline.selectedRow) of \(rows), session \(String(describing: tools.session))"
    }

    /// Waits for `condition`, letting the main actor's other work run: a run
    /// loop pumped inside an async test does not, and the tree announces
    /// itself ready through it.
    private func settle(_ timeout: TimeInterval = 5, until condition: () -> Bool = { false }) async -> Bool {
        let end = Date(timeIntervalSinceNow: timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }
}
