import AgentKit
import XCTest
@testable import ByteRipper

/// An agent's marks (`Design/AGENT_PLAN.md`, "Marks"): made, listed, related
/// and removed through the service; drawn by the pane and explained under the
/// pointer; listed in the Agent window; gone with their document.
@MainActor
final class AgentMarkTests: XCTestCase {
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
        try controller.windowModel.pane1.open(url: tempFile((0..<size).map { UInt8(truncatingIfNeeded: $0) }, "agent-mark"))
        controller.apply(mode: .singleFile)
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        return controller
    }

    private var pane: PaneViewModel { controller!.windowModel.pane1 }

    // MARK: - The tools

    func testAMarkIsMadeOnThePaneAndListed() async throws {
        try open()
        let made = try await client.answer("mark", ["offset": "0x10", "length": 4, "label": "Signature",
                                                    "note": "The magic the parser looks for."])
        XCTAssertEqual(made["id"], "m1")
        XCTAssertEqual(made["range"], ["start": "0x10", "end": "0x14", "length": "0x4"])
        XCTAssertEqual(pane.agentMarks.map(\.label), ["Signature"])
        XCTAssertEqual(pane.hexAgentMarkSpans(in: 0..<0x100).map(\.range), [0x10..<0x14])

        let listed = try await client.answer("marks")["marks"]?.arrayValue
        XCTAssertEqual(listed?.count, 1)
        XCTAssertEqual(listed?.first?["note"], "The magic the parser looks for.")
    }

    /// A pointer and what it points at: the relation is kept, and goes when
    /// either end does.
    func testARelationNamesAnotherMarkAndGoesWithIt() async throws {
        try open()
        _ = try await client.answer("mark", ["offset": "0x100", "length": 0x40, "label": "Table"])
        let pointer = try await client.answer("mark", ["offset": "0x20", "length": 4, "label": "Pointer",
                                                       "related_to": ["m1"]])
        XCTAssertEqual(pointer["related_to"], ["m1"])

        let unknown = try await client.call("mark", ["offset": 0, "length": 1, "label": "X", "related_to": ["m9"]])
        XCTAssertEqual(unknown.answer, "No mark m9. Call `marks` for the ones there are.")

        let removed = try await client.answer("unmark", ["ids": ["m1"]])
        XCTAssertEqual(removed["removed"], ["m1"])
        XCTAssertEqual(pane.agentMarks.map(\.id), ["m2"])
        XCTAssertEqual(pane.agentMarks.first?.relatedTo, [], "the relation went with its other end")
    }

    func testAMarkPastTheEndOrWithoutALabelIsRefused() async throws {
        try open(0x100)
        let past = try await client.call("mark", ["offset": "0xF0", "length": "0x20", "label": "Tail"])
        XCTAssertEqual(past.answer, "The range 0xF0+0x20 runs past the end of d1, which is 0x100 bytes long.")
        let empty = try await client.call("mark", ["offset": 0, "length": 1, "label": "  "])
        XCTAssertTrue(empty.isError)
        let zero = try await client.call("mark", ["offset": 0, "length": 0, "label": "Nothing"])
        XCTAssertTrue(zero.isError)
        XCTAssertTrue(pane.agentMarks.isEmpty)
    }

    func testUnmarkAllClearsEveryDocument() async throws {
        try open()
        _ = try await client.answer("mark", ["offset": 0, "length": 1, "label": "A"])
        _ = try await client.answer("mark", ["offset": 2, "length": 1, "label": "B"])
        let removed = try await client.answer("unmark", ["all": true])
        XCTAssertEqual(removed["removed"], ["m1", "m2"])
        XCTAssertTrue(pane.agentMarks.isEmpty)
        let refused = try await client.call("unmark")
        XCTAssertTrue(refused.isError, "an unmark that names nothing removes nothing")
    }

    // MARK: - On screen

    /// The note is what the pointer resting on the bytes shows — the
    /// innermost mark's, where two overlap.
    func testTheTooltipIsTheInnermostMarksLabelAndNote() async throws {
        try open()
        _ = try await client.answer("mark", ["offset": 0, "length": 0x100, "label": "Region"])
        _ = try await client.answer("mark", ["offset": 0x10, "length": 4, "label": "Signature", "note": "Magic."])
        XCTAssertEqual(pane.hexAgentMarkTooltip(at: 0x11), "Signature\nMagic.")
        XCTAssertEqual(pane.hexAgentMarkTooltip(at: 0x80), "Region")
        XCTAssertEqual(pane.hexAgentMarkTooltip(at: 0x200), "")
    }

    /// The bytes they were about are gone; so are they.
    func testMarksGoWhenAnotherFileIsOpenedInThePane() async throws {
        let controller = try open()
        _ = try await client.answer("mark", ["offset": 0, "length": 1, "label": "A"])
        try controller.windowModel.pane1.open(url: tempFile([1, 2, 3], "agent-mark-other"))
        XCTAssertTrue(pane.agentMarks.isEmpty)
    }

    // MARK: - The Agent window

    func testTheWindowListsMarksWithTheirRelationsAndClearsThem() async throws {
        try open()
        _ = try await client.answer("mark", ["offset": "0x100", "length": 0x40, "label": "Table"])
        _ = try await client.answer("mark", ["offset": "0x20", "length": 4, "label": "Pointer", "related_to": ["m1"]])
        let agentWindow = AgentWindowController(service: service)
        _ = agentWindow.window
        agentWindow.refresh()
        agentWindow.showMarks()
        let list = agentWindow.marksList
        XCTAssertEqual(list.shownText(row: 0, column: "label"), "Table")
        XCTAssertEqual(list.shownText(row: 1, column: "range"), "0x20–0x24")
        XCTAssertEqual(list.shownText(row: 1, column: "note"), "Related Marks: m1 Table", "the relation follows the note")
        XCTAssertEqual(pane.hexAgentMarkTooltip(at: 0x20), "Pointer\nRelated Marks: m1 Table")

        service.markTools.remove { _ in true }
        XCTAssertTrue(pane.agentMarks.isEmpty)
        XCTAssertTrue(list.isEmpty, "the window heard about it")
    }

    /// A double-click on a mark's row goes to its bytes, and Back comes back.
    func testShowingAMarkSelectsItsBytesAsAStep() async throws {
        let controller = try open(0x10000)
        _ = try await client.answer("mark", ["offset": "0x8000", "length": 8, "label": "Far"])
        service.markTools.show("m1")
        let selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x8000..<0x8008)
        XCTAssertTrue(controller.canNavigateBack)
    }
}
