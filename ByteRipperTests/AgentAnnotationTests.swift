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

    /// The Notes panel's cards, the panel raised and laid out.
    private func notes(raised: Bool = true) throws -> AgentAnnotationCards {
        let fragments = try XCTUnwrap(controller).fragments
        let panel = try XCTUnwrap(fragments.notesPanel, "the tab has a Notes panel")
        if raised, !fragments.notesAreUp { fragments.showNotes(animated: false) }
        window?.layoutIfNeeded()
        panel.cards.collection.layoutSubtreeIfNeeded()
        return panel.cards
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

    // MARK: - The Notes panel

    func testTheNotesPanelListsAnnotationsWithTheirRelationsAndGoesWithTheLast() async throws {
        let controller = try open()
        XCTAssertNil(controller.fragments.notesPanel, "no notes, no panel")
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

        service.annotationTools.remove { _ in true }
        XCTAssertTrue(pane.agentAnnotations.isEmpty)
        XCTAssertNil(controller.fragments.notesPanel, "the panel went with the last note")
        XCTAssertTrue(controller.fragments.isEmpty)
    }

    /// The agent's notes made while the panel is folded — or being made with
    /// the first of them — are counted on its pill until it is raised; one
    /// made while it is up is seen at once.
    func testThePillCountsTheAgentsNotesUntilThePanelIsRaised() async throws {
        let controller = try open()
        _ = try await client.answer("annotate", ["offset": 0, "title": "A"])
        _ = try await client.answer("annotate", ["offset": 2, "title": "B"])
        XCTAssertFalse(controller.fragments.notesAreUp, "the panel arrives folded")
        let pill = try XCTUnwrap(controller.fragmentDockStripForTesting.pillsForTesting.first)
        XCTAssertTrue(pill.isNotes)
        XCTAssertEqual(pill.unseen, 2)
        XCTAssertFalse(pill.badge.isHidden)
        XCTAssertNil(pill.menu(for: NSEvent()), "no Close, no New Tab")

        controller.fragments.showNotes(animated: false)
        XCTAssertEqual(service.annotationTools.unseen, [])
        XCTAssertEqual(pill.unseen, 0)
        XCTAssertTrue(pill.badge.isHidden)
        _ = try await client.answer("annotate", ["offset": 4, "title": "C"])
        XCTAssertEqual(pill.unseen, 0, "made while the panel is up")

        // Esc and ⌘W fold it; nothing closes it.
        controller.closeDocument()
        XCTAssertFalse(controller.fragments.notesAreUp)
        XCTAssertNotNil(controller.fragments.notesPanel)
        controller.fragments.showNotes(animated: false)
        controller.cancelOperation(nil)
        XCTAssertFalse(controller.fragments.notesAreUp)
        XCTAssertNotNil(controller.fragments.notesPanel)
    }

    /// The window speaks Russian: a note the agent makes draws the panel and
    /// its pill in Russian, and the agent is answered in English.
    func testThePanelSpeaksTheWindowsLanguageAndTheAgentEnglish() async throws {
        try await withAppLanguage(.russian) {
            let controller = try open(bytes: try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
            let made = try await client.answer("annotate", ["offset": "0x28", "length": 4, "title": "Signature"])
            let pill = try XCTUnwrap(controller.fragmentDockStripForTesting.pillsForTesting.first)
            XCTAssertEqual(pill.title, "Заметки")
            XCTAssertEqual(controller.fragments.notesPanel?.header.titleForTesting, "Заметки")
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
        XCTAssertEqual(service.annotationTools.all().map(\.title), ["A"])
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
