import XCTest
import ToolModuleKit
import UEFIImage
@testable import ByteRipper

/// A tab opened from a part of another document remembers where it came from,
/// says so in its header, and tells a UEFI panel what its bytes are
/// (`Design/UEFI/UPDATE_IN_PARENT.md` §2).
@MainActor
final class LinkedTabTests: XCTestCase {
    private var files: [URL] = []
    private var controllers: [MainViewController] = []
    private var windows: [NSWindow] = []
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        installToolStubs()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
    }

    override func tearDown() {
        for controller in controllers {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
        }
        windows.forEach { $0.close() }
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        controllers = []
        windows = []
        files = []
        super.tearDown()
    }

    private func makeController(opening bytes: [UInt8]? = nil) throws -> MainViewController {
        let controller = MainViewController()
        let window = makeTestWindow(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        if let bytes {
            let url = try tempFile(bytes)
            files.append(url)
            try controller.windowModel.pane1.open(url: url)
            controller.apply(mode: .singleFile)
        }
        window.layoutIfNeeded()
        controllers.append(controller)
        windows.append(window)
        return controller
    }

    private func host(_ controller: MainViewController) throws -> PaneToolHost {
        controller.tools.activate(StubToolA.identifier, animated: false)
        return try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)
    }

    /// A zone "FFSv2" at 0x100..<0x180 of a 0x400-byte dump, opened in a tab.
    private func openZoneTab() throws -> (parent: MainViewController, tab: MainViewController) {
        let parent = try makeController(opening: [UInt8](repeating: 0xAA, count: 0x400))
        try host(parent).publish(ZoneMap(zones: [Zone(id: "fv", name: "FFSv2", range: 0x100..<0x180)]))
        let menu = parent.makeOffsetMenu(for: parent.windowModel.pane1, offset: 0x120)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Zone “FFSv2” in a New Tab" })
        let tab = try makeController()
        parent.makeSiblingTab = { tab }
        _ = item.target?.perform(item.action, with: item)
        tab.view.window?.layoutIfNeeded()
        return (parent, tab)
    }

    private func link(in tab: MainViewController) throws -> NSButton {
        try XCTUnwrap(tab.filePaneView(for: tab.windowModel.pane1)?.linkButton)
    }

    // MARK: - The link

    func testAZoneTabIsLinkedToTheZoneAndNamesItsParent() throws {
        let (parent, tab) = try openZoneTab()

        let origin = try XCTUnwrap(tab.windowModel.pane1.origin)
        XCTAssertTrue(origin.parent === parent.windowModel.pane1)
        XCTAssertEqual(origin.sourceRange, 0x100..<0x180)
        XCTAssertEqual(origin.partName, "FFSv2")
        XCTAssertEqual(origin.state, .intact)

        let button = try link(in: tab)
        XCTAssertFalse(button.isHidden, "the header shows the link")
        XCTAssertEqual(button.title, parent.windowModel.pane1.status.fileName)
        XCTAssertEqual(button.toolTip?.contains("FFSv2"), true)
    }

    /// An edit to the source breaks the link and undoing it mends it; an edit
    /// elsewhere in the parent leaves it alone.
    func testTheLinkFollowsTheSourceBytes() throws {
        let (parent, tab) = try openZoneTab()
        let parentHost = try host(parent)
        let origin = try XCTUnwrap(tab.windowModel.pane1.origin)

        try parentHost.apply(ToolTransaction(name: "Elsewhere", offset: 0x10, bytes: [0x01]))
        XCTAssertEqual(origin.state, .intact, "an edit outside the source")

        try parentHost.apply(ToolTransaction(name: "Inside", offset: 0x140, bytes: [0x02]))
        XCTAssertEqual(origin.state, .sourceChanged)
        XCTAssertEqual(try link(in: tab).toolTip?.contains("changed"), true,
                       "the header redraws when the parent changes")

        _ = try parent.windowModel.pane1.undo()
        XCTAssertEqual(origin.state, .intact, "the bytes are the ones taken out again")
    }

    func testClosingTheParentBreaksTheLink() throws {
        let (parent, tab) = try openZoneTab()
        let origin = try XCTUnwrap(tab.windowModel.pane1.origin)
        let name = parent.windowModel.pane1.status.fileName

        parent.windowModel.pane1.close()

        XCTAssertEqual(origin.state, .parentClosed)
        XCTAssertEqual(origin.parentName, name, "still says which file it was")
        XCTAssertEqual(try link(in: tab).toolTip?.contains("no longer open"), true)
    }

    /// Another file dropped into the tab replaces the part: no link any more.
    func testReplacingTheTabsContentDropsTheLink() throws {
        let (_, tab) = try openZoneTab()
        let url = try tempFile([0x01, 0x02])
        files.append(url)

        try tab.windowModel.pane1.open(url: url)

        XCTAssertNil(tab.windowModel.pane1.origin)
    }

    func testClickingTheLinkSelectsTheSourceInTheParent() throws {
        let (parent, tab) = try openZoneTab()

        tab.revealOrigin(of: tab.windowModel.pane1)

        let selection = parent.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x100..<0x180)
    }

    func testAToolTabsPartIsNamedWithoutTheDumpAroundIt() {
        XCTAssertEqual(MainViewController.partName(ofTab: "bios_LZMA section.bin", parent: "bios.rom"),
                       "LZMA section")
        XCTAssertEqual(MainViewController.partName(ofTab: "Body.bin", parent: "bios.rom"), "Body")
    }

    // MARK: - What the bytes are

    /// The report: a Tiano section's body opened in a tab showed only padding
    /// in UEFI Structure. Linked as a decompressed body, it reads as sections.
    func testADecompressedBodyTabIsReadAsSections() async throws {
        let parent = try makeController(opening: [UInt8](repeating: 0xFF, count: 0x100))
        let parentHost = try host(parent)
        let tab = try makeController()
        parent.makeSiblingTab = { tab }
        // Two user-interface sections, "Drv" and "Set", twelve bytes each.
        let section: (String) -> [UInt8] = { text in
            [0x0C, 0x00, 0x00, 0x15] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
        }

        parentHost.openInNewTab(section("Drv") + section("Set"), named: "bios_Body.bin",
                                linkedTo: 0x20..<0x80, layout: .decompressedBody)

        XCTAssertEqual(tab.windowModel.pane1.origin?.layout, .decompressedBody)
        let tree = try XCTUnwrap(try host(tab).uefiTree())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.whenReady { done.resume() }
        }
        XCTAssertEqual(tree.layout, .decompressedBody)
        XCTAssertEqual(tree.rootNodes.map(\.kind), [.section, .section])
    }

    /// A zone of a UEFI file is told what it is by the parent's tree.
    func testAZoneOfAUEFINodeIsToldWhatItIs() throws {
        let (parent, tab) = try openZoneTab()
        _ = parent
        // The dump is all 0xAA: no node covers the zone, so it is an image.
        XCTAssertEqual(tab.windowModel.pane1.origin?.layout, .image)
    }
}
