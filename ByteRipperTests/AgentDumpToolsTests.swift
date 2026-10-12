import AgentKit
import XCTest
@testable import ByteRipper

/// Work across many dumps (`Design/AGENT_PLAN.md`, stage 5): a file opened by
/// path with no window, a folder asked one question, a dump put on screen, and
/// findings that lead back to their place.
@MainActor
final class AgentDumpToolsTests: XCTestCase {
    private var controller: MainViewController?
    private var window: NSWindow?
    private var service: AgentService!
    private var client: AgentTestClient!
    private var defaultsName = ""
    private var defaults: UserDefaults!
    private var folder: URL!

    override func setUp() {
        super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        let desk = AgentDesk(controllers: { [weak self] in self?.controller.map { [$0] } ?? [] },
                             keyController: { [weak self] in self?.controller })
        service = AgentService(desk: desk, defaults: defaults,
                               socketPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        // A test's own "new tab": the second pane of its one window.
        service.dumpTools.openInNewTab = { [weak self] url in
            guard let controller = self?.controller else { return }
            try? controller.windowModel.pane2.open(url: url)
            controller.apply(mode: .comparison)
        }
        client = AgentTestClient(service)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-dumps-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        service.stop()
        controller?.windowModel.pane1.close()
        controller?.windowModel.pane2.close()
        window?.orderOut(nil)
        window = nil
        controller = nil
        try? FileManager.default.removeItem(at: folder)
        discardIsolatedDefaults(defaultsName, defaults)
        super.tearDown()
    }

    @discardableResult
    private func openWindow(with bytes: [UInt8] = [0, 1, 2, 3]) throws -> MainViewController {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        try controller.windowModel.pane1.open(url: write(bytes, "front.bin"))
        controller.apply(mode: .singleFile)
        return controller
    }

    @discardableResult
    private func write(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - open_dump

    func testABackgroundDumpAnswersQuestionsButIsNotOnScreen() async throws {
        try openWindow()
        let image = try write(UEFITestImage.make(), "image.rom")
        let opened = try await client.answer("open_dump", ["path": .string(image.path)])
        XCTAssertEqual(opened["on_screen"], false)
        let id = try XCTUnwrap(opened["document"]?.stringValue)

        let listing = try await client.answer("documents")["documents"]?.arrayValue ?? []
        XCTAssertEqual(listing.first { $0["id"]?.stringValue == id }?["slot"], "background")

        let tree = try await client.answer("uefi_tree", ["document": .string(id), "depth": 3])
        XCTAssertTrue(tree.jsonText.contains(#""name":"MyDriver""#), tree.jsonText)
        let bytes = try await client.answer("read", ["document": .string(id), "offset": 0, "length": 4, "format": "u8"])
        XCTAssertEqual(bytes["values"]?.arrayValue?.count, 4)

        let reveal = try await client.call("reveal", ["document": .string(id), "offset": 0])
        XCTAssertTrue(reveal.answer.stringValue?.hasSuffix("(\(id)) is open in the background, not on screen. "
                                                         + "Call `show` to open it in a tab first.") == true,
                      "named by its file and its id: \(reveal.answer)")
        // An annotation on a file with no window belongs to the file, and is
        // drawn once it is shown.
        let annotated = try await client.answer("annotate", ["document": .string(id), "offset": 0, "title": "X"])
        XCTAssertNotNil(annotated["path"])
        XCTAssertNil(annotated["document"], "not on screen")
    }

    /// A document is named to the person by its file, never by its id: two
    /// files of one name are told apart by their folders, and a file on disk
    /// has a link that brings it forward.
    func testADocumentIsNamedByItsFileAndToldApartFromItsTwin() async throws {
        try openWindow()
        let other = folder.appendingPathComponent("Dell")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let twin = other.appendingPathComponent("front.bin")
        try Data([9, 9]).write(to: twin)
        _ = try await client.answer("open_dump", ["path": .string(twin.path)])

        let documents = try await client.answer("documents")
        let listed = try XCTUnwrap(documents["documents"]?.arrayValue)
        let labels = listed.compactMap { $0["label"]?.stringValue }
        XCTAssertEqual(Set(labels), ["\(folder.lastPathComponent)/front.bin", "Dell/front.bin"], "\(listed)")
        let link = try XCTUnwrap(listed.first?["link"]?.stringValue)
        XCTAssertTrue(link.hasPrefix("[\(labels[0])](byteripper://file?path="), link)
        let url = try XCTUnwrap(URL(string: String(link.dropFirst(labels[0].count + 3).dropLast())))
        XCTAssertNil(AgentNodeURLs.parse(url)?.node, "a link to the file itself")

        // Every answer about a document names it as well.
        let read = try await client.answer("read", ["document": "d1", "offset": 0, "length": 2])
        XCTAssertEqual(read["document_label"], .string(labels[0]))
    }

    func testAFileAlreadyInATabAnswersWithThatTabsId() async throws {
        let controller = try openWindow()
        let path = try XCTUnwrap(controller.windowModel.pane1.document?.url.path)
        let opened = try await client.answer("open_dump", ["path": .string(path)])
        XCTAssertEqual(opened["on_screen"], true)
        XCTAssertEqual(opened["document"], "d1")
        XCTAssertTrue(service.desk.background.entries.isEmpty)
    }

    /// A file changed on disk is read again before it is answered about, and
    /// keeps the id the agent already has.
    func testAFileChangedOnDiskIsReadAgainUnderTheSameId() async throws {
        try openWindow()
        let url = try write([1, 1, 1, 1], "changing.bin")
        let openedFile = try await client.answer("open_dump", ["path": .string(url.path)])
        let id = try XCTUnwrap(openedFile["document"]?.stringValue)
        try await Task.sleep(for: .milliseconds(1100))  // a modification date one second on
        try write([2, 2], "changing.bin")
        let read = try await client.answer("read", ["document": .string(id), "offset": 0, "length": 2, "format": "u8"])
        XCTAssertEqual(read["values"], ["0x02", "0x02"])
        XCTAssertEqual(read["document"]?.stringValue, id)
    }

    func testOnlyTheMostRecentlyUsedAreKept() async throws {
        try openWindow()
        service.desk.background.limit = 2
        for name in ["a.bin", "b.bin", "c.bin"] {
            let url = try write([0], name)
            _ = try await client.answer("open_dump", ["path": .string(url.path)])
        }
        XCTAssertEqual(service.desk.background.entries.map { $0.url.lastPathComponent }, ["b.bin", "c.bin"])
    }

    func testCloseDumpClosesABackgroundFileAndRefusesATab() async throws {
        try openWindow()
        let url = try write([0], "b.bin")
        let openedFile = try await client.answer("open_dump", ["path": .string(url.path)])
        let id = try XCTUnwrap(openedFile["document"]?.stringValue)
        let closed = try await client.answer("close_dump", ["document": .string(id)])
        XCTAssertEqual(closed["closed"]?.stringValue, id)
        XCTAssertTrue(service.desk.background.entries.isEmpty)
        let refused = try await client.call("close_dump", ["document": "d1"])
        XCTAssertEqual(refused.answer, "front.bin (d1) is open in a tab; only the person closes it.")
    }

    func testAMissingFileIsRefusedWithItsPath() async throws {
        try openWindow()
        let refused = try await client.call("open_dump", ["path": "/nowhere/at/all.bin"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.answer.stringValue?.hasPrefix("Could not read /nowhere/at/all.bin") == true, "\(refused.answer)")
        let relative = try await client.call("open_dump", ["path": "dumps/a.bin"])
        XCTAssertEqual(relative.answer, "`dumps/a.bin` is not an absolute path.")
    }

    // MARK: - survey

    /// One question of a folder: two images with a driver, one file without,
    /// and a file that is not a dump at all, which is left out.
    func testASurveyGroupsTheFolderByTheValueAskedFor() async throws {
        try openWindow()
        try write(UEFITestImage.make(), "one.rom")
        try write(UEFITestImage.make(), "two.bin")
        try write([UInt8](repeating: 0xFF, count: 0x1000), "blank.bin")
        try write([1, 2, 3], "notes.txt")
        let survey = try await client.answer("survey", [
            "folder": .string(folder.path), "tool": "uefi_find",
            "arguments": ["name": "MyDriver", "exact": true], "group_by": "total"
        ])
        // front.bin, the window's own file, is in the folder too.
        XCTAssertEqual(survey["files"], 4)
        let groups = try XCTUnwrap(survey["groups"]?.arrayValue)
        let byValue = Dictionary(uniqueKeysWithValues: groups.map { ($0["value"]?.jsonText ?? "", $0) })
        XCTAssertEqual(byValue["2"]?["count"], 2, "\(groups)")
        XCTAssertEqual(byValue["2"]?["files"], ["one.rom", "two.bin"])
    }

    /// The DMI area across a folder: grouped by how many were found, the
    /// dump the parser knows the layout of apart from the one it does not.
    func testASurveyOfTheDMIAreaSetsTheKnownLayoutsApart() async throws {
        try openWindow()
        try write(LenovoTestImage.make(), "lenovo.bin")
        try write(UEFITestImage.make(), "plain.rom")
        let survey = try await client.answer("survey", [
            "paths": .array([.string(folder.appendingPathComponent("lenovo.bin").path),
                             .string(folder.appendingPathComponent("plain.rom").path)]),
            "tool": "uefi_dmi", "group_by": "areas.0.layout"
        ])
        let groups = try XCTUnwrap(survey["groups"]?.arrayValue)
        let byValue = Dictionary(uniqueKeysWithValues: groups.map { ($0["value"]?.jsonText ?? "", $0) })
        XCTAssertEqual(byValue[#""Lenovo DMI store""#]?["files"], ["lenovo.bin"], "\(groups)")
        XCTAssertEqual(byValue["null"]?["files"], ["plain.rom"], "\(groups)")
        XCTAssertNil(survey["failed"], "a dump with no area found is an answer, not a refusal")
    }

    /// A survey's groups in pages: the second page is cut from the same run,
    /// and a cursor of another survey is refused.
    func testASurveysGroupsArePaged() async throws {
        try openWindow()
        try write(UEFITestImage.make(), "one.rom")
        try write([UInt8](repeating: 0xFF, count: 0x1000), "blank.bin")
        let question: [String: JSONValue] = [
            "folder": .string(folder.path), "tool": "uefi_find",
            "arguments": ["name": "MyDriver", "exact": true], "group_by": "total", "limit": 1
        ]
        let first = try await client.answer("survey", .object(question))
        XCTAssertEqual(first["groups"]?.arrayValue?.count, 1)
        XCTAssertEqual(first["groups_total"], 2)
        let next = try XCTUnwrap(first["next"]?.stringValue, "\(first)")
        var more = question
        more["after"] = .string(next)
        let second = try await client.answer("survey", .object(more))
        XCTAssertEqual(second["groups"]?.arrayValue?.count, 1)
        XCTAssertEqual(second["next"], .null)
        XCTAssertNotEqual(first["groups"], second["groups"])

        var other = more
        other["group_by"] = "matches"
        let refused = try await client.call("survey", .object(other))
        XCTAssertEqual(refused.answer, "That page is of another survey; ask again without `after`.")
    }

    func testAPathCanCountFromTheEndAndARefusalIsListed() async throws {
        try openWindow()
        let image = try write(UEFITestImage.make(), "image.rom")
        let short = try write([1, 2], "short.bin")
        let survey = try await client.answer("survey", [
            "paths": [.string(image.path), .string(short.path)], "tool": "read",
            "arguments": ["offset": "0x10", "length": 2, "format": "u8"], "group_by": "values.-1"
        ])
        XCTAssertEqual(survey["groups"]?.arrayValue?.count, 1)
        XCTAssertEqual(survey["failed"]?.arrayValue?.first?["file"], "short.bin")
    }

    func testASurveyOnlyRunsToolsThatTakeADocument() async throws {
        try openWindow()
        let refused = try await client.call("survey", ["folder": .string(folder.path), "tool": "documents"])
        XCTAssertEqual(refused.answer, "`documents` is not a tool that answers about one document.")
    }

    // MARK: - show

    func testShowPutsABackgroundDumpOnScreenUnderANewId() async throws {
        let controller = try openWindow()
        let url = try write([UInt8](repeating: 7, count: 0x100), "later.bin")
        let openedFile = try await client.answer("open_dump", ["path": .string(url.path)])
        let id = try XCTUnwrap(openedFile["document"]?.stringValue)
        let shown = try await client.answer("show", ["document": .string(id), "offset": "0x10", "length": 4])
        XCTAssertEqual(shown["replaces"]?.stringValue, id)
        XCTAssertNotEqual(shown["document"]?.stringValue, id)
        XCTAssertEqual(controller.windowModel.pane2.document?.url.lastPathComponent, "later.bin")
        let selection = controller.windowModel.pane2.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x10..<0x14)
        XCTAssertTrue(service.desk.background.entries.isEmpty, "the background copy gave way to the tab")
    }

    // MARK: - Annotations

    /// What a survey leaves: an annotation, listed in the window, which leads
    /// back to its place.
    func testAnAnnotationIsListedAndLeadsBackToItsPlace() async throws {
        let controller = try openWindow(with: [UInt8](repeating: 0, count: 0x10000))
        let recorded = try await client.answer("annotate", ["document": "d1", "offset": "0x8000", "length": 8,
                                                            "title": "Stray byte", "note": "A stray byte."])
        XCTAssertEqual(recorded["id"], "a1")
        let listed = try await client.answer("annotations")["annotations"]?.arrayValue
        XCTAssertEqual(listed?.first?["note"], "A stray byte.")

        let cards = try XCTUnwrap(controller.fragments.notesPanel?.cards, "listed in the Notes panel")
        XCTAssertTrue(cards.shownTexts(of: "a1").contains("0x8000–0x8008"), "\(cards.shownTexts(of: "a1"))")

        service.annotationTools.show("a1")
        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x8000..<0x8008)

        service.annotationTools.remove { _ in true }
        XCTAssertNil(controller.fragments.notesPanel)
    }
}
