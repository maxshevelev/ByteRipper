import XCTest
@testable import ByteRipper

/// File ▸ Open Recent's data source: the list of opened paths, newest first.
/// The store touches no disk of its own, so no temp files are needed — a path
/// is just a string to it.
final class RecentFilesStoreTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        RecentFilesStore.defaults = store
    }

    override func tearDown() {
        RecentFilesStore.defaults = AppDefaults.store
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/var/tmp/ByteRipper/\(name)")
    }

    /// A re-open of an older file moves it to the front, and the older entry
    /// is dropped rather than duplicated.
    func testRecordMovesAnOlderEntryToTheFront() {
        RecentFilesStore.record(file("a.bin"))
        RecentFilesStore.record(file("b.bin"))
        RecentFilesStore.record(file("a.bin"))

        XCTAssertEqual(RecentFilesStore.recent,
                       [file("a.bin").standardizedFileURL.path,
                        file("b.bin").standardizedFileURL.path])
    }

    /// The list is capped at `limit`, newest first.
    func testRecordCapsAtTheLimit() {
        for i in 0..<12 {
            RecentFilesStore.record(file("f\(i).bin"))
        }

        XCTAssertEqual(RecentFilesStore.recent.count, RecentFilesStore.limit)
        // Newest first: the last recorded file is at the front, and the two
        // oldest are the ones dropped.
        XCTAssertEqual(RecentFilesStore.recent.first, file("f11.bin").standardizedFileURL.path)
        XCTAssertFalse(RecentFilesStore.recent.contains(file("f0.bin").standardizedFileURL.path))
        XCTAssertFalse(RecentFilesStore.recent.contains(file("f1.bin").standardizedFileURL.path))
    }

    /// Re-recording the file already at the front changes nothing — the common
    /// case, since the open pipeline records on every success.
    func testRecordingTheFirstEntryChangesNothing() {
        RecentFilesStore.record(file("a.bin"))

        XCTAssertFalse(RecentFilesStore.record(file("a.bin")))
        XCTAssertEqual(RecentFilesStore.recent, [file("a.bin").standardizedFileURL.path])
    }

    /// A first record does change the list.
    func testRecordingIntoAnEmptyListChangesIt() {
        XCTAssertTrue(RecentFilesStore.record(file("a.bin")))
        XCTAssertEqual(RecentFilesStore.recent, [file("a.bin").standardizedFileURL.path])
    }

    /// **Clear Menu** empties the list, and it stays empty.
    func testClearEmptiesTheList() {
        RecentFilesStore.record(file("a.bin"))
        RecentFilesStore.record(file("b.bin"))

        RecentFilesStore.clear()

        XCTAssertTrue(RecentFilesStore.recent.isEmpty)
    }

    /// A row whose file is gone is a greyed ghost, so the launch-time prune
    /// drops it — the same reading the bookmark store's pruneNow gets (§D9).
    func testPruneMissingDropsDeadPathsAndKeepsTheLiveOnes() throws {
        let live = try tempFile([0x41])
        let dead = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString).bin")
        try Data([0x42]).write(to: dead)
        RecentFilesStore.record(live)
        RecentFilesStore.record(dead)
        try FileManager.default.removeItem(at: dead)

        RecentFilesStore.pruneMissing()

        XCTAssertEqual(RecentFilesStore.recent, [live.standardizedFileURL.path])
    }

    /// A list with nothing dead is not rewritten.
    func testPruneMissingLeavesAHealthyListAlone() throws {
        let a = try tempFile([0x41])
        let b = try tempFile([0x42])
        RecentFilesStore.record(a)
        RecentFilesStore.record(b)

        RecentFilesStore.pruneMissing()

        XCTAssertEqual(RecentFilesStore.recent,
                       [b.standardizedFileURL.path, a.standardizedFileURL.path])
    }

    /// The swappable domain is the seam: a write does not leak into the app's
    /// own defaults, and the store reads what the domain holds.
    func testTheDomainIsSwappable() {
        RecentFilesStore.record(file("a.bin"))

        XCTAssertFalse((AppDefaults.store.array(forKey: RecentFilesStore.userDefaultsKey) as? [String] ?? []).contains(
            file("a.bin").standardizedFileURL.path),
            "a record must not leak into the app's own defaults")
        XCTAssertEqual(store.array(forKey: RecentFilesStore.userDefaultsKey) as? [String],
                       RecentFilesStore.recent)
    }
}
