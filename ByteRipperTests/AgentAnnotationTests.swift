import AgentKit
import ToolModuleKit
import XCTest
@testable import ByteRipper

/// An agent's annotations (`Design/AGENT_PLAN.md`, "Annotations"; issue
/// #37): made, listed, related and removed through the service; drawn by the
/// pane and explained under the pointer; listed in the Agent window; kept with
/// the file when it closes, and drawn again when it opens.
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
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        try controller.windowModel.pane1.open(url: tempFile((0..<size).map { UInt8(truncatingIfNeeded: $0) }, "agent-annotation"))
        controller.apply(mode: .singleFile)
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        return controller
    }

    private var pane: PaneViewModel { controller!.windowModel.pane1 }

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
        let both = try await client.call("annotate", ["offset": 0, "node": "0", "title": "Both"])
        XCTAssertTrue(both.isError)
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

    // MARK: - The Agent window

    func testTheWindowListsAnnotationsWithTheirRelationsAndClearsThem() async throws {
        try open()
        _ = try await client.answer("annotate", ["offset": "0x100", "length": 0x40, "title": "Table"])
        _ = try await client.answer("annotate", ["offset": "0x20", "length": 4, "title": "Pointer", "related_to": ["a1"]])
        let agentWindow = AgentWindowController(service: service)
        _ = agentWindow.window
        agentWindow.refresh()
        agentWindow.showAnnotations()
        let list = agentWindow.annotationsList
        let name = try XCTUnwrap(pane.document?.url.lastPathComponent)
        // A card: the number and the title, the file and the place, the note,
        // and the annotations it is about as links.
        // The place's node as UEFI Structure names it: a file that is all
        // padding, by its addresses.
        XCTAssertEqual(list.shownTexts(of: "a1"), ["a1", "Table", "\(name) · 0x100–0x140", "Padding, 0x0–0x1000"])
        XCTAssertEqual(list.shownTexts(of: "a2"), ["a2", "Pointer", "\(name) · 0x20–0x24", "Padding, 0x0–0x1000",
                                                   "→ a1 Table"])
        list.select("a1")
        XCTAssertEqual(list.selectedIDs, ["a1"])
        XCTAssertEqual(pane.hexAgentMarkTooltip(at: 0x20), "Pointer\nRelated Annotations: a1 Table")

        service.annotationTools.remove { _ in true }
        XCTAssertTrue(pane.agentAnnotations.isEmpty)
        XCTAssertTrue(list.isEmpty, "the window heard about it")
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

        let agentWindow = AgentWindowController(service: service)
        let window = try XCTUnwrap(agentWindow.window)
        window.setContentSize(NSSize(width: 820, height: 500))
        agentWindow.refresh()
        agentWindow.showAnnotations()
        window.layoutIfNeeded()
        let cards = agentWindow.annotationsList
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
            place: "SPI_C86018_128Mbit.03022026.orig.bin · 0xEACFFB–0xEAD005", path: nil,
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
            for field in card.subviews.compactMap({ $0 as? NSTextField }) {
                let needs = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.frame.width, height: 10_000)).height ?? 0
                XCTAssertGreaterThanOrEqual(field.frame.height, needs, "width \(width): \(field.stringValue) is cut")
            }
        }
    }

    /// The same, for the cards the window shows.
    func testTheWindowsCardsHoldAllOfTheirText() async throws {
        try open(0x1000)
        for index in 0..<4 {
            _ = try await client.answer("annotate", [
                "offset": .int(Int64(index * 16)), "length": 6, "title": .string("LBLDESP: панель 2560×1600 \(index)"),
                "note": .string("Lenovo Panel descriptor: здесь width=0x0A00 (2560), height=0x0640 (1600). "
                                + String(repeating: "В другом дампе 1920×1080 — другая модель экрана. ", count: index + 1))])
        }
        let agentWindow = AgentWindowController(service: service)
        let window = try XCTUnwrap(agentWindow.window)
        let saved = ToolPanelFont.defaults.object(forKey: ToolPanelFont.zoomSizeKey)
        defer { ToolPanelFont.defaults.set(saved, forKey: ToolPanelFont.zoomSizeKey) }
        for (width, zoom) in [(420.0, 13.0), (700, 13), (1100, 13), (420, 17), (700, 17)] {
            window.setContentSize(NSSize(width: width, height: 600))
            agentWindow.refresh()
            agentWindow.showAnnotations()
            window.layoutIfNeeded()
            ToolPanelFont.defaults.set(zoom, forKey: ToolPanelFont.zoomSizeKey)
            NotificationCenter.default.post(name: ToolPanelFont.zoomDidChangeNotification, object: nil)
            window.layoutIfNeeded()
            let cards = agentWindow.annotationsList
            cards.collection.layoutSubtreeIfNeeded()
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
}
