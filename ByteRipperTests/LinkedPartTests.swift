import XCTest
import ToolModuleKit
import UEFIImage
@testable import ByteRipper

/// A panel opened from a part of another document remembers where it came
/// from, says so in its header, and tells a UEFI panel what its bytes are
/// (`Design/UEFI/UPDATE_IN_PARENT.md` §2, `Design/FRAGMENT_PANELS_PLAN.md`).
@MainActor
final class LinkedPartTests: XCTestCase {
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
        // A controller shrinks its window to what its view asks for, which for
        // an empty one is nothing: the panel a part opens into needs a window
        // with room in it.
        window.setContentSize(NSSize(width: 900, height: 600))
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

    /// A zone "FFSv2" at 0x100..<0x180 of a 0x400-byte dump, opened as a panel
    /// over the dump it came out of — which is where a part opens
    /// (`Design/FRAGMENT_PANELS_PLAN.md`). The parent is that controller's own
    /// pane 1; the part is the panel's pane.
    private func openZonePanel() throws -> (controller: MainViewController, part: PaneViewModel) {
        let controller = try makeController(opening: [UInt8](repeating: 0xAA, count: 0x400))
        try host(controller).publish(
            ZoneMap(zones: [Zone(id: "fv", name: "FFSv2", range: 0x100..<0x180)]))
        let menu = controller.makeOffsetMenu(for: controller.windowModel.pane1, offset: 0x120)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Zone “FFSv2”" })
        _ = item.target?.perform(item.action, with: item)
        let id = try XCTUnwrap(controller.fragments.expanded, "the part opens in a panel, raised")
        // The panel is placed by frame arithmetic, so its subtree has to be
        // laid out before the pane's own chrome — the link button among it —
        // knows whether it fits.
        controller.view.window?.layoutIfNeeded()
        controller.fragments.panelView(id)?.layoutSubtreeIfNeeded()
        return (controller, try XCTUnwrap(controller.fragments.pane(id)))
    }

    private func link(of part: PaneViewModel, in controller: MainViewController) throws -> NSButton {
        controller.paneView(for: part).linkButton
    }

    /// The part in the panel `controller` has raised — what every route that
    /// opens one leaves on screen.
    private func openedPart(in controller: MainViewController) throws -> PaneViewModel {
        let id = try XCTUnwrap(controller.fragments.expanded, "a part opens in a raised panel")
        return try XCTUnwrap(controller.fragments.pane(id))
    }

    /// A tool-module on the raised panel's own surface, bound to the part.
    private func partHost(_ controller: MainViewController) throws -> PaneToolHost {
        let id = try XCTUnwrap(controller.fragments.expanded)
        try XCTUnwrap(controller.fragments.surface(id)).tools.activate(StubToolA.identifier,
                                                                      animated: false)
        return try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)
    }

    // MARK: - The link

    func testAZoneTabIsLinkedToTheZoneAndNamesItsParent() throws {
        let (controller, part) = try openZonePanel()

        let origin = try XCTUnwrap(part.origin)
        XCTAssertTrue(origin.parent === controller.windowModel.pane1)
        XCTAssertEqual(origin.sourceRange, 0x100..<0x180)
        XCTAssertEqual(origin.partName, "FFSv2")
        XCTAssertEqual(origin.state, .intact)

        let button = try link(of: part, in: controller)
        XCTAssertFalse(button.isHidden, "the header shows the link")
        XCTAssertEqual(button.title, controller.windowModel.pane1.status.fileName)
        XCTAssertEqual(button.toolTip?.contains("FFSv2"), true)
    }

    /// An edit to the source breaks the link and undoing it mends it; an edit
    /// elsewhere in the parent leaves it alone.
    func testTheLinkFollowsTheSourceBytes() throws {
        let (controller, part) = try openZonePanel()
        let parentHost = try host(controller)
        let origin = try XCTUnwrap(part.origin)

        try parentHost.apply(ToolTransaction(name: "Elsewhere", offset: 0x10, bytes: [0x01]))
        XCTAssertEqual(origin.state, .intact, "an edit outside the source")

        try parentHost.apply(ToolTransaction(name: "Inside", offset: 0x140, bytes: [0x02]))
        XCTAssertEqual(origin.state, .sourceChanged)
        XCTAssertEqual(try link(of: part, in: controller).toolTip?.contains("changed"), true,
                       "the header redraws when the parent changes")

        _ = try controller.windowModel.pane1.undo()
        XCTAssertEqual(origin.state, .intact, "the bytes are the ones taken out again")
    }

    func testClosingTheParentBreaksTheLink() throws {
        let (controller, part) = try openZonePanel()
        let origin = try XCTUnwrap(part.origin)
        let name = controller.windowModel.pane1.status.fileName

        controller.windowModel.pane1.close()

        XCTAssertEqual(origin.state, .parentClosed)
        XCTAssertEqual(origin.parentName, name, "still says which file it was")
        XCTAssertEqual(try link(of: part, in: controller).toolTip?.contains("no longer open"), true)
    }

    /// Another file dropped into the tab replaces the part: no link any more.
    func testReplacingTheTabsContentDropsTheLink() throws {
        let (_, part) = try openZonePanel()
        let url = try tempFile([0x01, 0x02])
        files.append(url)

        try part.open(url: url)

        XCTAssertNil(part.origin)
    }

    func testClickingTheLinkSelectsTheSourceInTheParent() throws {
        let (controller, part) = try openZonePanel()

        controller.revealOrigin(of: part)

        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x100..<0x180)
    }

    func testAToolTabsPartIsNamedWithoutTheDumpAroundIt() {
        XCTAssertEqual(MainViewController.partName(ofTab: "bios_LZMA section.bin", parent: "bios.rom"),
                       "LZMA section")
        XCTAssertEqual(MainViewController.partName(ofTab: "Body.bin", parent: "bios.rom"), "Body")
    }

    /// A part torn off into a tab of its own keeps the link: the origin is the
    /// pane's own property, so Update in Parent still knows where the bytes go
    /// (`Design/FRAGMENT_PANELS_PLAN.md`).
    func testAPartTornOffIntoATabKeepsItsLink() throws {
        let (controller, part) = try openZonePanel()
        let tab = try makeController()
        controller.makeSiblingTab = { tab }

        controller.tearOffPaneToNewTab(draggedPaneID: part.dragID)

        XCTAssertTrue(controller.fragments.isEmpty)
        XCTAssertTrue(tab.windowModel.pane1 === part)
        let origin = try XCTUnwrap(part.origin, "still linked to the zone it came out of")
        XCTAssertTrue(origin.parent === controller.windowModel.pane1)
        XCTAssertEqual(origin.state, .intact)

        try patch(part, at: 0x10, with: 0x55)
        tab.performUpdateInParent(of: part)
        XCTAssertEqual(try byte(at: 0x110, of: controller.windowModel.pane1), 0x55,
                       "and the bytes still go back where they came from")
    }

    // MARK: - Against the bytes it was opened with

    private func modified(_ range: Range<UInt64>, in part: PaneViewModel) -> [Bool] {
        part.hexByteStates(in: range).map(\.isModified)
    }

    /// An edit in a part's tab reads as modified against the bytes the part
    /// was opened with — in the hex view and on the minimap's source — and
    /// still does after the edit has been put back into the controller.
    func testAnEditInAPartsTabReadsAsModified() throws {
        let (controller, part) = try openZonePanel()
        let pane = part
        XCTAssertTrue(pane.marksModifiedBytes)
        XCTAssertEqual(modified(0x0F..<0x12, in: part), [false, false, false], "nothing edited yet")

        try patch(part, at: 0x10, with: 0x55)
        XCTAssertEqual(modified(0x0F..<0x12, in: part), [false, true, false])

        try patch(part, at: 0x10, with: 0xAA)
        XCTAssertEqual(modified(0x0F..<0x12, in: part), [false, false, false],
                       "the original byte back is not a modification")

        try patch(part, at: 0x10, with: 0x55)
        controller.performUpdateInParent(of: pane)
        XCTAssertEqual(modified(0x10..<0x11, in: part), [true], "still not what the tab was opened with")
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
        let (controller, part) = try openZonePanel()
        let pane = part
        let menu = controller.makePaneMenu(for: pane)
        let item = try XCTUnwrap(menu.items.first {
            $0.action == #selector(MainViewController.revertPaneDocument(_:))
        })
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Revert to Original")
        XCTAssertEqual(controller.makePaneMenu(for: controller.windowModel.pane1).items.first {
            $0.action == #selector(MainViewController.revertPaneDocument(_:))
        }.map { controller.validateMenuItem($0) ? $0.title : "disabled" }, "Revert to Saved")

        try patch(part, at: 0x10, with: 0x55)
        var asked: String?
        MainViewController.modalResponder = { alert in
            asked = alert.messageText
            return .alertSecondButtonReturn
        }
        defer { MainViewController.modalResponder = nil }
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(asked, "Revert to the original bytes?")
        XCTAssertEqual(try byte(at: 0x10, of: part), 0x55, "cancelled")

        MainViewController.modalResponder = { _ in .alertFirstButtonReturn }
        _ = item.target?.perform(item.action, with: item)

        XCTAssertEqual(try byte(at: 0x10, of: part), 0xAA)
        XCTAssertFalse(pane.status.isDirty)
        XCTAssertFalse(pane.status.canUndo, "the edits are gone, not undoable")
        XCTAssertEqual(modified(0x10..<0x11, in: part), [false])
        XCTAssertNotNil(pane.origin, "still linked")
        XCTAssertFalse(try XCTUnwrap(pane.origin).hasChanges(in: pane))
    }

    // MARK: - What the bytes are

    /// The report: a Tiano section's body opened in a tab showed only padding
    /// in UEFI Structure. Linked as a decompressed body, it reads as sections.
    func testADecompressedBodyTabIsReadAsSections() async throws {
        let controller = try makeController(opening: [UInt8](repeating: 0xFF, count: 0x100))
        let parentHost = try host(controller)
        // Two user-interface sections, "Drv" and "Set", twelve bytes each.
        let section: (String) -> [UInt8] = { text in
            [0x0C, 0x00, 0x00, 0x15] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
        }

        parentHost.openPart(section("Drv") + section("Set"), named: "bios_Body.bin",
                                linkedTo: 0x20..<0x80, layout: .decompressedBody,
                                part: .init(space: .decompressed(chain: [0x20])))

        let part = try openedPart(in: controller)
        XCTAssertEqual(part.origin?.layout, .decompressedBody)
        let tree = try XCTUnwrap(try partHost(controller).uefiTree())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.whenReady { done.resume() }
        }
        XCTAssertEqual(tree.layout, .decompressedBody)
        XCTAssertEqual(tree.rootNodes.map(\.kind), [.section, .section])
    }

    /// A zone of a UEFI file is told what it is by the parent's tree.
    func testAZoneOfAUEFINodeIsToldWhatItIs() throws {
        let (_, part) = try openZonePanel()
        // The dump is all 0xAA: no node covers the zone, so it is an image.
        XCTAssertEqual(part.origin?.layout, .image)
    }

    // MARK: - Update in Parent (§3)

    private func byte(at offset: UInt64, of pane: PaneViewModel) throws -> UInt8 {
        try XCTUnwrap(pane.document?.read(at: offset, length: 1).first)
    }

    private func patch(_ part: PaneViewModel, at offset: UInt64, with value: UInt8) throws {
        try part.applyToolWrites([(offset: offset, bytes: [value])], named: "Patch")
    }

    /// The tab's bytes go back over the zone as one undo step in the parent,
    /// named after the tab, and the link then has nothing left to put back.
    func testUpdatingAZoneWritesTheTabBackAsOneUndoStep() throws {
        let (controller, part) = try openZonePanel()
        let pane = part
        let origin = try XCTUnwrap(pane.origin)
        try patch(part, at: 0x10, with: 0x55)
        XCTAssertTrue(origin.hasChanges(in: pane))

        controller.performUpdateInParent(of: pane)

        XCTAssertEqual(try byte(at: 0x110, of: controller.windowModel.pane1), 0x55)
        XCTAssertEqual(controller.windowModel.pane1.undoLabel, "Update from \(pane.status.fileName)")
        XCTAssertTrue(controller.windowModel.pane1.status.isDirty, "written to the parent, not to its file")
        XCTAssertEqual(origin.state, .intact)
        XCTAssertFalse(origin.hasChanges(in: pane))
        XCTAssertEqual(try link(of: part, in: controller).toolTip?.contains("Click to show"), true,
                       "the header shows the link intact after the parent's own change")

        _ = try controller.windowModel.pane1.undo()
        XCTAssertEqual(try byte(at: 0x110, of: controller.windowModel.pane1), 0xAA)
        XCTAssertEqual(origin.state, .sourceChanged, "the parent no longer holds what the tab put back")
    }

    /// The bytes go back, and the panel gets out of the way so the change can
    /// be seen landing: it folds into its pill, and the dump behind it has the
    /// part selected where it went.
    func testUpdatingFoldsThePanelAndShowsWhereItLanded() throws {
        let (controller, part) = try openZonePanel()
        try patch(part, at: 0x10, with: 0x55)
        XCTAssertNotNil(controller.fragments.expanded, "the premise: the panel is up")

        controller.performUpdateInParent(of: part)

        XCTAssertNil(controller.fragments.expanded,
                     "the panel folds — watching it land is why a part opens over its parent")
        XCTAssertEqual(controller.fragments.count, 1, "folded, not closed")
        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x100..<0x180,
                       "and the dump shows the bytes that just arrived")
    }

    /// Offered in the header's menu, named after the parent, and enabled only
    /// when there is something to put back.
    func testTheCommandIsOfferedWhenThereIsSomethingToPutBack() throws {
        let (controller, part) = try openZonePanel()
        let pane = part
        let menu = controller.makePaneMenu(for: pane)
        let item = try XCTUnwrap(menu.items.first {
            $0.action == #selector(MainViewController.updatePaneInParent(_:))
        })

        XCTAssertFalse(controller.validateMenuItem(item), "nothing changed yet")
        XCTAssertEqual(item.title, "Update in “\(controller.windowModel.pane1.status.fileName)”")

        try patch(part, at: 0, with: 0x01)
        XCTAssertTrue(controller.validateMenuItem(item))

        controller.windowModel.pane1.close()
        XCTAssertFalse(controller.validateMenuItem(item), "no parent to put it back into")
    }

    func testALengthChangeIsRefused() throws {
        let controller = try makeController(opening: [UInt8](repeating: 0xAA, count: 0x100))
        try host(controller).openPart([0x01, 0x02, 0x03], named: "part.bin", linkedTo: 0x10..<0x20)
        let part = try openedPart(in: controller)
        try patch(part, at: 0, with: 0x09)

        controller.performUpdateInParent(of: part)

        XCTAssertEqual(controller.lastAlertTitle, "The length changed")
        XCTAssertEqual(try byte(at: 0x10, of: controller.windowModel.pane1), 0xAA, "nothing was written")
    }

    /// A source edited in the parent since is overwritten only when the reader
    /// says so.
    func testAChangedSourceIsOverwrittenOnlyWhenConfirmed() throws {
        let (controller, part) = try openZonePanel()
        let pane = part
        try host(controller).apply(ToolTransaction(name: "Meanwhile", offset: 0x150, bytes: [0x77]))
        try patch(part, at: 0x10, with: 0x55)
        var asked: String?

        controller.updateConfirm = { alert in
            asked = alert.messageText
            return .alertSecondButtonReturn
        }
        controller.performUpdateInParent(of: pane)
        XCTAssertEqual(asked, "“FFSv2” has changed in \(controller.windowModel.pane1.status.fileName)")
        XCTAssertEqual(try byte(at: 0x110, of: controller.windowModel.pane1), 0xAA, "cancelled")
        XCTAssertEqual(try byte(at: 0x150, of: controller.windowModel.pane1), 0x77)

        controller.updateConfirm = { _ in .alertFirstButtonReturn }
        controller.performUpdateInParent(of: pane)
        XCTAssertEqual(try byte(at: 0x110, of: controller.windowModel.pane1), 0x55)
        XCTAssertEqual(try byte(at: 0x150, of: controller.windowModel.pane1), 0xAA, "the tab's bytes, the parent's change overwritten")
        XCTAssertEqual(pane.origin?.state, .intact)
    }

    /// A decompressed body goes back through the rebuild planner; one whose
    /// section is not in the parent any more is refused with the reason, and
    /// nothing is written.
    func testADecompressedBodyWhoseSectionIsGoneIsRefused() async throws {
        let controller = try makeController(opening: [UInt8](repeating: 0xFF, count: 0x100))
        try host(controller).openPart([UInt8](repeating: 0, count: 0x60), named: "body.bin",
                                      linkedTo: 0x20..<0x80, layout: .decompressedBody,
                                      part: .init(space: .decompressed(chain: [0x20])))
        let part = try openedPart(in: controller)
        try patch(part, at: 0, with: 0x01)

        await controller.performUpdateInParent(of: part)?.value

        XCTAssertEqual(controller.lastAlertTitle, "“body” cannot be put back")
        XCTAssertEqual(try byte(at: 0x20, of: controller.windowModel.pane1), 0xFF)
    }

    /// Waits, a little at a time and for two seconds at most, until `done` —
    /// for what lands on the main actor after an animation, like a sheet going.
    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Cancel on the update's sheet abandons it: the sheet goes, and nothing is
    /// written into the controller.
    func testCancellingTheUpdateSheetWritesNothing() async throws {
        let controller = try makeController(opening: UEFITestImage.make())
        let parentHost = try host(controller)
        let tree = try XCTUnwrap(parentHost.uefiTree())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.whenReady { done.resume() }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.expand(NodeID.root.child(0)) { _ in done.resume() }
        }
        parentHost.publish(ZoneMap(zones: [Zone(id: "0.0", name: "MyDriver", range: 0x48..<0x8C)]))
        let menu = controller.makeOffsetMenu(for: controller.windowModel.pane1, offset: 0x50)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Zone “MyDriver”" })
        _ = item.target?.perform(item.action, with: item)
        let part = try openedPart(in: controller)
        let pane = part
        try patch(part, at: 0x34, with: 0x00)
        let before = try XCTUnwrap(controller.windowModel.pane1.document?.read(at: 0, length: 0x1000))

        let update = controller.performUpdateInParent(of: pane)
        let sheet = try XCTUnwrap(controller.presentedViewControllers?.first as? BlockingOperationSheet)
        sheet.cancelButton.performClick(nil)
        await update?.value
        try await until { (controller.presentedViewControllers ?? []).isEmpty }

        XCTAssertTrue((controller.presentedViewControllers ?? []).isEmpty, "the sheet goes")
        XCTAssertFalse(sheet.operation.isActive)
        XCTAssertEqual(controller.windowModel.pane1.document.flatMap { try? $0.read(at: 0, length: 0x1000) }, before,
                       "nothing was written")
        XCTAssertNotEqual(controller.lastAlertTitle, "Updated “\(controller.windowModel.pane1.status.fileName)”")
    }

    /// A zone that is a file of the image goes back through the planner, which
    /// puts the file's checksums right around the edit.
    func testAZoneThatIsAFileGoesBackWithItsChecksumsRight() async throws {
        let controller = try makeController(opening: UEFITestImage.make())
        let parentHost = try host(controller)
        let tree = try XCTUnwrap(parentHost.uefiTree())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.whenReady { done.resume() }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.expand(NodeID.root.child(0)) { _ in done.resume() }
        }
        parentHost.publish(ZoneMap(zones: [Zone(id: "0.0", name: "MyDriver", range: 0x48..<0x8C)]))
        let menu = controller.makeOffsetMenu(for: controller.windowModel.pane1, offset: 0x50)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Zone “MyDriver”" })
        _ = item.target?.perform(item.action, with: item)
        let part = try openedPart(in: controller)
        let pane = part
        XCTAssertEqual(pane.origin?.rebuildTarget, .init(space: .file, range: 0x48..<0x8C))

        // The raw section's first payload byte.
        try patch(part, at: 0x34, with: 0x00)
        let update = controller.performUpdateInParent(of: pane)
        // The work lands in the parent: a sheet on its window says so while it
        // runs, and keeps the parent from being edited under it. One window
        // now, since the part opens over its parent rather than in a tab.
        let sheet = try XCTUnwrap(controller.presentedViewControllers?.first as? BlockingOperationSheet,
                                  "a sheet on the parent's window")
        XCTAssertTrue(sheet.titleLabel.stringValue.contains("MyDriver"), sheet.titleLabel.stringValue)
        XCTAssertEqual(sheet.cancelButton.title, "Cancel")
        let operation = sheet.operation
        await update?.value
        try await until { !operation.isActive && (controller.presentedViewControllers ?? []).isEmpty }
        XCTAssertFalse(operation.isActive, "done")
        XCTAssertTrue((controller.presentedViewControllers ?? []).isEmpty, "the sheet goes when the update is done")

        XCTAssertEqual(try byte(at: 0x48 + 0x34, of: controller.windowModel.pane1), 0x00)
        let bytes = try XCTUnwrap(controller.windowModel.pane1.document?.read(at: 0, length: 0x1000))
        let checksums = UEFIParser.parse(bytes).diagnostics.filter { "\($0.kind)".hasPrefix("checksumMismatch") }
        XCTAssertEqual(checksums, [], "the file's checksums were put right")
        XCTAssertEqual(controller.lastAlertTitle, "Updated “\(controller.windowModel.pane1.status.fileName)”")
        XCTAssertEqual(pane.origin?.state, .intact)
        XCTAssertEqual(pane.origin?.hasChanges(in: pane), false)
    }
}
