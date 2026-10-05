import XCTest
@testable import ByteRipper

/// §3.1: the recent files on the landing screen, under the version — the left
/// half of the bottom row, with the release notes on the right. The window's
/// bookmarks take the left half when it has any.
@MainActor
final class EmptyStateRecentFilesTests: XCTestCase {
    private func makeEmptyView() -> EmptyStateView {
        let view = EmptyStateView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        return view
    }

    private func release() throws -> Release {
        Release(
            version: try XCTUnwrap(AppVersion("0.9.0")),
            page: try XCTUnwrap(URL(string: "https://github.com/maxshevelev/ByteRipper/releases/tag/v0.9.0")),
            body: "A release about the structure tree.",
        )
    }

    /// With no recent files there is no section: a heading over nothing.
    func testNoRecentFilesMeansNoSection() {
        let view = makeEmptyView()

        view.setRecentFiles([])

        XCTAssertFalse(view.isShowingRecentFilesForTesting)
    }

    /// One row per file, most recent first, in the order given.
    func testRecentFilesAreListedInOrder() {
        let view = makeEmptyView()

        view.setRecentFiles(["/tmp/b.bin", "/tmp/a.bin"])

        XCTAssertTrue(view.isShowingRecentFilesForTesting)
        XCTAssertEqual(view.recentRowsForTesting, ["/tmp/b.bin", "/tmp/a.bin"])
    }

    /// Setting the list again replaces it rather than appending.
    func testRebuildingTheListReplacesTheRows() {
        let view = makeEmptyView()

        view.setRecentFiles(["/tmp/a.bin", "/tmp/b.bin"])
        view.setRecentFiles(["/tmp/c.bin"])

        XCTAssertEqual(view.recentRowsForTesting, ["/tmp/c.bin"])
    }

    /// A click on a row hands the controller that row's path.
    func testClickingARowOpensThatFile() {
        let view = makeEmptyView()
        var opened: [String] = []
        view.onOpenRecent = { opened.append($0) }
        view.setRecentFiles(["/tmp/a.bin", "/tmp/b.bin"])

        view.clickRecentRowForTesting(1)

        XCTAssertEqual(opened, ["/tmp/b.bin"])
    }

    /// Bookmarks have priority: with any, the recent files stay off, and they
    /// come back when the last mark goes.
    func testBookmarksTakeThePlaceOfTheRecentFiles() {
        let view = makeEmptyView()
        view.setRecentFiles(["/tmp/a.bin"])
        XCTAssertTrue(view.isShowingRecentFilesForTesting)

        view.setBookmarks([Bookmark(row: 0x10, name: "one")])
        XCTAssertTrue(view.isShowingBookmarksForTesting)
        XCTAssertFalse(view.isShowingRecentFilesForTesting)

        view.setBookmarks([])
        XCTAssertFalse(view.isShowingBookmarksForTesting)
        XCTAssertTrue(view.isShowingRecentFilesForTesting)
    }

    /// The order the two are told in does not matter: marks told first still win.
    func testBookmarksWinWhateverTheOrder() {
        let view = makeEmptyView()

        view.setBookmarks([Bookmark(row: 0x10, name: "one")])
        view.setRecentFiles(["/tmp/a.bin"])

        XCTAssertFalse(view.isShowingRecentFilesForTesting)
    }

    /// With the release notes too, the row splits into equal halves.
    func testTheNotesWithRecentFilesSplitTheRowInHalves() throws {
        let view = makeEmptyView()  // 600 wide
        view.setRecentFiles(["/tmp/a.bin"])
        view.showReleaseNotes(try release(), isRunningBuild: true)

        let half = max(200.0, min(400.0, (600 - 96 - 36) / 2.0))
        XCTAssertEqual(view.releaseNotesWidthForTesting, half)
        XCTAssertEqual(view.recentListWidthForTesting, half)
    }
}
