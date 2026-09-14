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

    // MARK: - Against the bytes it was opened with

    private func modified(_ range: Range<UInt64>, in tab: MainViewController) -> [Bool] {
        tab.windowModel.pane1.hexByteStates(in: range).map(\.isModified)
    }

    /// An edit in a part's tab reads as modified against the bytes the part
    /// was opened with — in the hex view and on the minimap's source — and
    /// still does after the edit has been put back into the parent.
    func testAnEditInAPartsTabReadsAsModified() throws {
        let (_, tab) = try openZoneTab()
        let pane = tab.windowModel.pane1
        XCTAssertTrue(pane.marksModifiedBytes)
        XCTAssertEqual(modified(0x0F..<0x12, in: tab), [false, false, false], "nothing edited yet")

        try patch(tab, at: 0x10, with: 0x55)
        XCTAssertEqual(modified(0x0F..<0x12, in: tab), [false, true, false])

        try patch(tab, at: 0x10, with: 0xAA)
        XCTAssertEqual(modified(0x0F..<0x12, in: tab), [false, false, false],
                       "the original byte back is not a modification")

        try patch(tab, at: 0x10, with: 0x55)
        tab.performUpdateInParent(of: pane)
        XCTAssertEqual(modified(0x10..<0x11, in: tab), [true], "still not what the tab was opened with")
    }

    /// An untitled document with no parent has nothing to be modified against.
    func testAPlainUntitledDocumentMarksNothing() throws {
        let controller = try makeController()
        let pane = controller.windowModel.pane1
        pane.openBytes([1, 2, 3], named: "bytes.bin")
        try pane.applyToolWrites([(offset: 1, bytes: [9])], named: "Patch")

        XCTAssertFalse(pane.marksModifiedBytes)
        XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.isModified), [false, false, false])
    }

    /// In a part's tab, Revert to Saved is Revert to Original: asked first,
    /// it drops every edit and leaves the tab linked, holding what it opened with.
    func testRevertToOriginalGoesBackToTheBytesTheTabOpenedWith() throws {
        let (parent, tab) = try openZoneTab()
        let pane = tab.windowModel.pane1
        let menu = tab.makePaneMenu(for: pane)
        let item = try XCTUnwrap(menu.items.first {
            $0.action == #selector(MainViewController.revertPaneDocument(_:))
        })
        XCTAssertTrue(tab.validateMenuItem(item))
        XCTAssertEqual(item.title, "Revert to Original")
        XCTAssertEqual(parent.makePaneMenu(for: parent.windowModel.pane1).items.first {
            $0.action == #selector(MainViewController.revertPaneDocument(_:))
        }.map { parent.validateMenuItem($0) ? $0.title : "disabled" }, "Revert to Saved")

        try patch(tab, at: 0x10, with: 0x55)
        var asked: String?
        MainViewController.modalResponder = { alert in
            asked = alert.messageText
            return .alertSecondButtonReturn
        }
        defer { MainViewController.modalResponder = nil }
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(asked, "Revert to the original bytes?")
        XCTAssertEqual(try byte(at: 0x10, of: tab), 0x55, "cancelled")

        MainViewController.modalResponder = { _ in .alertFirstButtonReturn }
        _ = item.target?.perform(item.action, with: item)

        XCTAssertEqual(try byte(at: 0x10, of: tab), 0xAA)
        XCTAssertFalse(pane.status.isDirty)
        XCTAssertFalse(pane.status.canUndo, "the edits are gone, not undoable")
        XCTAssertEqual(modified(0x10..<0x11, in: tab), [false])
        XCTAssertNotNil(pane.origin, "still linked")
        XCTAssertFalse(try XCTUnwrap(pane.origin).hasChanges(in: pane))
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
                                linkedTo: 0x20..<0x80, layout: .decompressedBody,
                                part: .init(space: .decompressed(chain: [0x20])))

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

    // MARK: - Update in Parent (§3)

    private func byte(at offset: UInt64, of controller: MainViewController) throws -> UInt8 {
        try XCTUnwrap(controller.windowModel.pane1.document?.read(at: offset, length: 1).first)
    }

    private func patch(_ tab: MainViewController, at offset: UInt64, with value: UInt8) throws {
        try tab.windowModel.pane1.applyToolWrites([(offset: offset, bytes: [value])], named: "Patch")
    }

    /// The tab's bytes go back over the zone as one undo step in the parent,
    /// named after the tab, and the link then has nothing left to put back.
    func testUpdatingAZoneWritesTheTabBackAsOneUndoStep() throws {
        let (parent, tab) = try openZoneTab()
        let pane = tab.windowModel.pane1
        let origin = try XCTUnwrap(pane.origin)
        try patch(tab, at: 0x10, with: 0x55)
        XCTAssertTrue(origin.hasChanges(in: pane))

        tab.performUpdateInParent(of: pane)

        XCTAssertEqual(try byte(at: 0x110, of: parent), 0x55)
        XCTAssertEqual(parent.windowModel.pane1.undoLabel, "Update from \(pane.status.fileName)")
        XCTAssertTrue(parent.windowModel.pane1.status.isDirty, "written to the parent, not to its file")
        XCTAssertEqual(origin.state, .intact)
        XCTAssertFalse(origin.hasChanges(in: pane))
        XCTAssertEqual(try link(in: tab).toolTip?.contains("Click to show"), true,
                       "the header shows the link intact after the parent's own change")

        _ = try parent.windowModel.pane1.undo()
        XCTAssertEqual(try byte(at: 0x110, of: parent), 0xAA)
        XCTAssertEqual(origin.state, .sourceChanged, "the parent no longer holds what the tab put back")
    }

    /// Offered in the header's menu, named after the parent, and enabled only
    /// when there is something to put back.
    func testTheCommandIsOfferedWhenThereIsSomethingToPutBack() throws {
        let (parent, tab) = try openZoneTab()
        let pane = tab.windowModel.pane1
        let menu = tab.makePaneMenu(for: pane)
        let item = try XCTUnwrap(menu.items.first {
            $0.action == #selector(MainViewController.updatePaneInParent(_:))
        })

        XCTAssertFalse(tab.validateMenuItem(item), "nothing changed yet")
        XCTAssertEqual(item.title, "Update in “\(parent.windowModel.pane1.status.fileName)”")

        try patch(tab, at: 0, with: 0x01)
        XCTAssertTrue(tab.validateMenuItem(item))

        parent.windowModel.pane1.close()
        XCTAssertFalse(tab.validateMenuItem(item), "no parent to put it back into")
    }

    func testALengthChangeIsRefused() throws {
        let parent = try makeController(opening: [UInt8](repeating: 0xAA, count: 0x100))
        let tab = try makeController()
        parent.makeSiblingTab = { tab }
        try host(parent).openInNewTab([0x01, 0x02, 0x03], named: "part.bin", linkedTo: 0x10..<0x20)
        try patch(tab, at: 0, with: 0x09)

        tab.performUpdateInParent(of: tab.windowModel.pane1)

        XCTAssertEqual(tab.lastAlertTitle, "The length changed")
        XCTAssertEqual(try byte(at: 0x10, of: parent), 0xAA, "nothing was written")
    }

    /// A source edited in the parent since is overwritten only when the reader
    /// says so.
    func testAChangedSourceIsOverwrittenOnlyWhenConfirmed() throws {
        let (parent, tab) = try openZoneTab()
        let pane = tab.windowModel.pane1
        try host(parent).apply(ToolTransaction(name: "Meanwhile", offset: 0x150, bytes: [0x77]))
        try patch(tab, at: 0x10, with: 0x55)
        var asked: String?

        tab.updateConfirm = { alert in
            asked = alert.messageText
            return .alertSecondButtonReturn
        }
        tab.performUpdateInParent(of: pane)
        XCTAssertEqual(asked, "“FFSv2” has changed in \(parent.windowModel.pane1.status.fileName)")
        XCTAssertEqual(try byte(at: 0x110, of: parent), 0xAA, "cancelled")
        XCTAssertEqual(try byte(at: 0x150, of: parent), 0x77)

        tab.updateConfirm = { _ in .alertFirstButtonReturn }
        tab.performUpdateInParent(of: pane)
        XCTAssertEqual(try byte(at: 0x110, of: parent), 0x55)
        XCTAssertEqual(try byte(at: 0x150, of: parent), 0xAA, "the tab's bytes, the parent's change overwritten")
        XCTAssertEqual(pane.origin?.state, .intact)
    }

    /// A decompressed body goes back through the rebuild planner; one whose
    /// section is not in the parent any more is refused with the reason, and
    /// nothing is written.
    func testADecompressedBodyWhoseSectionIsGoneIsRefused() async throws {
        let parent = try makeController(opening: [UInt8](repeating: 0xFF, count: 0x100))
        let tab = try makeController()
        parent.makeSiblingTab = { tab }
        try host(parent).openInNewTab([UInt8](repeating: 0, count: 0x60), named: "body.bin",
                                      linkedTo: 0x20..<0x80, layout: .decompressedBody,
                                      part: .init(space: .decompressed(chain: [0x20])))
        try patch(tab, at: 0, with: 0x01)

        await tab.performUpdateInParent(of: tab.windowModel.pane1)?.value

        XCTAssertEqual(tab.lastAlertTitle, "“body” cannot be put back")
        XCTAssertEqual(try byte(at: 0x20, of: parent), 0xFF)
    }

    /// A zone that is a file of the image goes back through the planner, which
    /// puts the file's checksums right around the edit.
    func testAZoneThatIsAFileGoesBackWithItsChecksumsRight() async throws {
        let parent = try makeController(opening: UEFITestImage.make())
        let parentHost = try host(parent)
        let tree = try XCTUnwrap(parentHost.uefiTree())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.whenReady { done.resume() }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.expand(NodeID.root.child(0)) { _ in done.resume() }
        }
        parentHost.publish(ZoneMap(zones: [Zone(id: "0.0", name: "MyDriver", range: 0x48..<0x8C)]))
        let menu = parent.makeOffsetMenu(for: parent.windowModel.pane1, offset: 0x50)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Zone “MyDriver” in a New Tab" })
        let tab = try makeController()
        parent.makeSiblingTab = { tab }
        _ = item.target?.perform(item.action, with: item)
        let pane = tab.windowModel.pane1
        XCTAssertEqual(pane.origin?.rebuildTarget, .init(space: .file, range: 0x48..<0x8C))

        // The raw section's first payload byte.
        try patch(tab, at: 0x34, with: 0x00)
        let update = tab.performUpdateInParent(of: pane)
        // The work lands in the parent, and its status bar shows it while it
        // runs — not the tab's.
        let parentView = try XCTUnwrap(parent.filePaneView(for: parent.windowModel.pane1))
        let operation = try XCTUnwrap(parentView.shownOperation, "the parent's status bar shows the update")
        XCTAssertFalse(parentView.operationView.isHidden)
        XCTAssertTrue(parentView.operationView.nameLabel.stringValue.contains("MyDriver"),
                      parentView.operationView.nameLabel.stringValue)
        XCTAssertNil(tab.filePaneView(for: pane)?.shownOperation)
        await update?.value
        for _ in 0..<200 where operation.isActive { await Task.yield() }
        XCTAssertFalse(operation.isActive, "gone when the update is done")
        XCTAssertTrue(parentView.operationView.isHidden)

        XCTAssertEqual(try byte(at: 0x48 + 0x34, of: parent), 0x00)
        let bytes = try XCTUnwrap(parent.windowModel.pane1.document?.read(at: 0, length: 0x1000))
        let checksums = UEFIParser.parse(bytes).diagnostics.filter { "\($0.kind)".hasPrefix("checksumMismatch") }
        XCTAssertEqual(checksums, [], "the file's checksums were put right")
        XCTAssertEqual(tab.lastAlertTitle, "Updated “\(parent.windowModel.pane1.status.fileName)”")
        XCTAssertEqual(pane.origin?.state, .intact)
        XCTAssertEqual(pane.origin?.hasChanges(in: pane), false)
    }
}
