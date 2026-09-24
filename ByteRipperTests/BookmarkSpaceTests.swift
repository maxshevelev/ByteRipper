import XCTest
import UEFIImage
@testable import ByteRipper

/// §20.7 — one bookmark list for the window's dump and the fragment panels
/// opened out of it, read in each place at that place's own offsets.
///
/// A mark is a row of a file, so a panel showing the part of that file at
/// `0x1F000` shows the mark on `0x1F400` at `0x400`, and a mark made there on
/// `0x400` is a mark on `0x1F400` in the dump. A decompressed body is the
/// exception: its bytes are not the file's bytes, so it reads no list, adds to
/// none, and says so where a list would be offered.
@MainActor
final class BookmarkSpaceTests: XCTestCase {
    // MARK: - The arithmetic

    /// A pane showing a file whole reads the list as it is.
    func testASpaceAtZeroIsTheListItself() {
        let store = BookmarkStore()
        let space = BookmarkSpace(store: store)
        store.add(rowContaining: 0x120, name: "ME")

        XCTAssertFalse(space.isShifted)
        XCTAssertEqual(space.bookmarks, [Bookmark(row: 0x120, name: "ME")])
        XCTAssertEqual(space.storeRow(forRowContaining: 0x125), 0x120)
        XCTAssertEqual(space.localRow(forStoreRow: 0x120), 0x120)
    }

    /// A shifted space is the same list at the part's addresses, both ways
    /// round — and the marks it carries are the marks the list carries.
    func testAShiftedSpaceTranslatesBothWays() {
        let store = BookmarkStore()
        let space = BookmarkSpace(store: store, origin: 0x1F000)

        space.add(rowContaining: 0x400, name: "header")

        XCTAssertTrue(space.isShifted)
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x1F400, name: "header")],
                       "the list has it at the file's address")
        XCTAssertEqual(space.bookmarks, [Bookmark(row: 0x400, name: "header")],
                       "and the panel at the part's")
        XCTAssertEqual(space.bookmark(atRowContaining: 0x40B)?.row, 0x400)
    }

    /// A mark on a row the part does not cover is not a mark in the part. It
    /// stays in the list either way — the panel is a window onto it, not a copy
    /// of it.
    func testMarksBeforeThePartAreNotInIt() {
        let store = BookmarkStore()
        let space = BookmarkSpace(store: store, origin: 0x1F000)
        store.add(rowContaining: 0x10, name: "above")
        store.add(rowContaining: 0x1F010, name: "inside")

        XCTAssertEqual(space.bookmarks, [Bookmark(row: 0x10, name: "inside")])
        XCTAssertNil(space.localRow(forStoreRow: 0x10))
    }

    /// A part need not begin on a row boundary, and a mark made in one that
    /// does not must read back on the row it was made on. That is what the
    /// round *up* into the list's grid is for: rounding both ways down sent the
    /// mark one row up the moment it was looked at.
    func testAnUnalignedPartKeepsAMarkOnTheRowItWasMadeOn() {
        let space = BookmarkSpace(store: BookmarkStore(), origin: 0x108)

        for local: UInt64 in [0, 0x20, 0x30, 0x400] {
            let stored = space.storeRow(forRowContaining: local)
            XCTAssertEqual(stored % UInt64(HexLayout.bytesPerRow), 0,
                           "the list's rows are the list's grid")
            XCTAssertEqual(space.localRow(forStoreRow: stored), local,
                           "and it reads back where it was made")
        }
    }

    /// Two of the panel's rows never land on one row of the list, however the
    /// part is aligned — a mark made on one row can never swallow another.
    func testEachPanelRowHasAListRowOfItsOwn() {
        let space = BookmarkSpace(store: BookmarkStore(), origin: 0x108)
        let rows = (0..<8).map { space.storeRow(forRowContaining: UInt64($0) * 16) }

        XCTAssertEqual(Set(rows).count, rows.count)
    }

    /// The per-range question the dump's drawing asks, answered in the panel's
    /// offsets — including for the file's last, part-full row.
    func testRowsInRangeAnswerInThePanesOffsets() {
        let store = BookmarkStore()
        let space = BookmarkSpace(store: store, origin: 0x1F000)
        store.add(rowContaining: 0x1F000)
        store.add(rowContaining: 0x1F020)
        store.add(rowContaining: 0x1F100)

        XCTAssertEqual(space.rows(in: 0..<0x30), [0, 0x20])
        XCTAssertEqual(space.rows(in: 0..<0x2A), [0, 0x20],
                       "the last drawn row brings its mark even where the file stops mid-row")
        XCTAssertEqual(space.rows(in: 0x30..<0x110), [0x100])
    }

    /// Dragging a mark is the store's decision, taken in the list's offsets and
    /// answered in the panel's (§20.6).
    func testADragLandsInThePanesOffsets() {
        let store = BookmarkStore()
        let space = BookmarkSpace(store: store, origin: 0x1F000)
        space.add(rowContaining: 0x20, name: "moved")

        XCTAssertEqual(space.move(rowContaining: 0x20, to: 0x50, lastRow: 0x90), 0x50)
        XCTAssertEqual(store.bookmarks, [Bookmark(row: 0x1F050, name: "moved")])
    }

    // MARK: - A panel in the app

    /// A mark made in the dump repaints the panel's row — the one the part has
    /// it at — and a mark made in the panel repaints the dump's.
    func testAMarkInEitherPlaceRepaintsTheOther() throws {
        let part = try makePart(at: 0x100, length: 0x40)
        var dumpRows: [UInt64] = []
        var panelRows: [UInt64] = []
        part.controller.windowModel.pane1.onBookmarksChanged = { dumpRows.append($0) }
        part.pane.onBookmarksChanged = { panelRows.append($0) }

        part.controller.windowModel.bookmarkStore.add(rowContaining: 0x110)
        XCTAssertEqual(dumpRows, [0x110])
        XCTAssertEqual(panelRows, [0x10], "the panel repaints the row the part has it on")

        part.pane.bookmarks?.add(rowContaining: 0x20)
        XCTAssertEqual(dumpRows, [0x110, 0x120])
        XCTAssertEqual(panelRows, [0x10, 0x20])
    }

    /// A mark outside the part reaches the panel as nothing at all: there is no
    /// row of it to repaint.
    func testAMarkOutsideThePartRepaintsNothingInIt() throws {
        let part = try makePart(at: 0x100, length: 0x40)
        var panelRows: [UInt64] = []
        part.pane.onBookmarksChanged = { panelRows.append($0) }

        part.controller.windowModel.bookmarkStore.add(rowContaining: 0x10)

        XCTAssertTrue(panelRows.isEmpty)
    }

    /// A part opened out of a part composes the two offsets, so its marks land
    /// in the file's list at the file's address.
    func testAPartOfAPartComposesTheOffsets() throws {
        let outer = try makePart(at: 0x100, length: 0x80)
        let bytes = [UInt8](repeating: 0xAA, count: 0x20)
        let origin = try XCTUnwrap(DocumentOrigin(parent: outer.pane, source: 0x40..<0x60,
                                                  partName: "inner", layout: .image,
                                                  content: bytes))
        let id = try XCTUnwrap(outer.controller.openFragment(bytes, named: "inner",
                                                             origin: origin, animated: false))
        let inner = try XCTUnwrap(outer.controller.fragments.pane(id))

        inner.bookmarks?.add(rowContaining: 0x10, name: "deep")

        XCTAssertEqual(outer.controller.windowModel.bookmarkStore.bookmarks,
                       [Bookmark(row: 0x150, name: "deep")])
        XCTAssertEqual(outer.pane.bookmarks?.bookmarks, [Bookmark(row: 0x50, name: "deep")])
    }

    // MARK: - What the tooltip says

    /// In the dump the tooltip is the name and nothing else: the address is
    /// drawn on the mark, right under the pointer.
    func testTheDumpsTooltipIsJustTheName() throws {
        let part = try makePart(at: 0x100, length: 0x40)
        let dump = part.controller.windowModel.pane1
        dump.bookmarks?.add(rowContaining: 0x110, name: "ME region")

        XCTAssertEqual(dump.hexBookmarkTooltip(atRowContaining: 0x115), "ME region")
    }

    /// In a panel it also says where the row is in the file the mark belongs
    /// to — the address the mark has everywhere else, which the panel's own
    /// Offset column cannot show.
    func testAPanelsTooltipNamesTheOffsetInTheParent() throws {
        let part = try makePart(at: 0x100, length: 0x40)
        part.pane.bookmarks?.add(rowContaining: 0x10, name: "ME region")

        let tooltip = part.pane.hexBookmarkTooltip(atRowContaining: 0x1B)

        XCTAssertTrue(tooltip.hasPrefix("ME region\n"), tooltip)
        XCTAssertTrue(tooltip.contains(UInt64(0x110).hexAddress), tooltip)
        XCTAssertTrue(tooltip.contains(part.controller.windowModel.pane1.status.fileName), tooltip)
    }

    /// An unnamed mark in a panel still has that line: there it is not a
    /// repetition of the address on the mark, it is the other one.
    func testAnUnnamedMarkInAPanelStillNamesTheParentOffset() throws {
        let part = try makePart(at: 0x100, length: 0x40)
        part.pane.bookmarks?.add(rowContaining: 0x10)

        let tooltip = part.pane.hexBookmarkTooltip(atRowContaining: 0x10)

        XCTAssertFalse(tooltip.contains("\n"), "nothing to say twice: \(tooltip)")
        XCTAssertTrue(tooltip.contains(UInt64(0x110).hexAddress), tooltip)
    }

    /// An unmarked row says nothing, in a panel as in the dump.
    func testAnUnmarkedRowHasNoTooltip() throws {
        let part = try makePart(at: 0x100, length: 0x40)

        XCTAssertEqual(part.pane.hexBookmarkTooltip(atRowContaining: 0x10), "")
    }

    // MARK: - A decompressed body

    /// Nothing is drawn and nothing can be made: the pane has no list at all.
    func testADecompressedPartHasNoList() throws {
        let part = try makePart(at: 0x100, length: 0x40, kind: .decompressed)
        part.controller.windowModel.bookmarkStore.add(rowContaining: 0x110)

        XCTAssertNil(part.pane.bookmarks)
        XCTAssertTrue(part.pane.hexBookmarkedRows(in: 0..<0x40).isEmpty)
        XCTAssertEqual(part.pane.hexBookmarkTooltip(atRowContaining: 0x10), "")
    }

    /// ⌘D is off there, and so is ⇧⌘D: there is no row in this pane the file's
    /// list has an address for.
    func testTheBookmarkCommandsAreOffInADecompressedPart() throws {
        let part = try makePart(at: 0x100, length: 0x40, kind: .decompressed)
        part.controller.fragments.expand(part.id, animated: false)
        let toggle = NSMenuItem(title: "", action: #selector(MainViewController.toggleBookmark),
                                keyEquivalent: "")
        let edit = NSMenuItem(title: "", action: #selector(MainViewController.editBookmark),
                              keyEquivalent: "")

        XCTAssertTrue(part.pane === part.controller.activePane, "the panel is in front")
        XCTAssertFalse(part.controller.validateMenuItem(toggle))
        XCTAssertFalse(part.controller.validateMenuItem(edit))
    }

    /// And the offset menu carries no bookmark block: a disabled item would
    /// still be an offer, and there is nothing being offered.
    func testTheOffsetMenuHasNoBookmarkBlockInADecompressedPart() throws {
        let part = try makePart(at: 0x100, length: 0x40, kind: .decompressed)

        let titles = part.controller.makeOffsetMenu(for: part.pane, offset: 0x10).items.map(\.title)

        XCTAssertFalse(titles.contains { $0.hasPrefix("Toggle Bookmark") }, "\(titles)")
        XCTAssertFalse(titles.contains("Edit Bookmark…"), "\(titles)")
        XCTAssertFalse(titles.last?.isEmpty ?? false, "and no separator left dangling: \(titles)")
    }

    /// A copied part keeps the block, because there it means something.
    func testTheOffsetMenuKeepsTheBookmarkBlockInACopiedPart() throws {
        let part = try makePart(at: 0x100, length: 0x40)

        let titles = part.controller.makeOffsetMenu(for: part.pane, offset: 0x1B).items.map(\.title)

        XCTAssertTrue(titles.contains("Toggle Bookmark at 00000010"),
                      "the part's own address, which is the one drawn beside it: \(titles)")
    }

    // MARK: - The Go To form

    /// Opened over a panel, the form lists the part's addresses — and going to
    /// one goes to it in the part.
    func testTheFormListsThePartsAddresses() throws {
        let part = try makePart(at: 0x100, length: 0x40)
        part.controller.fragments.expand(part.id, animated: false)
        var forms: [GoToBookmarksController] = []
        part.controller.goToFormPresenter = { form in
            form.loadViewIfNeeded()
            form.dismissForm = {}
            forms.append(form)
        }
        part.controller.windowModel.bookmarkStore.add(rowContaining: 0x120, name: "inside")

        part.controller.goToPosition()

        let form = try XCTUnwrap(forms.first)
        XCTAssertNil(form.unavailable)
        XCTAssertEqual(form.bookmarks, [Bookmark(row: 0x20, name: "inside")])
    }

    /// Opened over a decompressed body it opens with the list closed, saying
    /// why rather than looking empty — an empty list would read as "you have
    /// not made any", which is a different thing.
    func testTheFormClosesItsListOverADecompressedPart() throws {
        let part = try makePart(at: 0x100, length: 0x40, kind: .decompressed)
        part.controller.fragments.expand(part.id, animated: false)
        var forms: [GoToBookmarksController] = []
        part.controller.goToFormPresenter = { form in
            form.loadViewIfNeeded()
            form.dismissForm = {}
            forms.append(form)
        }
        part.controller.windowModel.bookmarkStore.add(rowContaining: 0x120, name: "inside")

        part.controller.goToPosition()

        let form = try XCTUnwrap(forms.first)
        let message = try XCTUnwrap(form.unavailable)
        XCTAssertTrue(message.contains("part"), message)
        XCTAssertTrue(form.bookmarks.isEmpty, "the dump's marks are not this pane's")
        XCTAssertTrue(form.bookmarkTable.refusesFirstResponder,
                      "and the list is closed to the keyboard too")
        XCTAssertNil(form.bookmarkTable.menu)
    }

    // MARK: - Helpers

    /// A window with a file in pane 1 and a panel holding the part of it at
    /// `offset` — the arrangement every question here is about.
    private func makePart(at offset: UInt64, length: Int,
                          kind: DocumentOrigin.Kind = .copy) throws
        -> (controller: MainViewController, pane: PaneViewModel, id: FragmentDock.PanelID) {
        let controller = MainViewController()
        let window = makeTestWindow(width: 900, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x400))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.contentView?.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            for id in controller.fragments.dock.panels {
                controller.fragments.close(id, animated: false)
            }
            controller.windowModel.pane1.close()
            try? FileManager.default.removeItem(at: url)
        }

        let bytes = [UInt8](repeating: 0xAA, count: length)
        let origin = try XCTUnwrap(DocumentOrigin(
            parent: controller.windowModel.pane1,
            source: offset..<(offset + UInt64(length)), partName: "part",
            layout: .image, kind: kind, content: bytes))
        let id = try XCTUnwrap(controller.openFragment(bytes, named: "part", origin: origin,
                                                       animated: false))
        window.contentView?.layoutSubtreeIfNeeded()
        return (controller, try XCTUnwrap(controller.fragments.pane(id)), id)
    }
}
