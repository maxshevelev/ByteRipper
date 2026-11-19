import XCTest
@testable import ByteRipper

/// M6 tests for the external-change watcher (§5.5): it fires on an external
/// write, stops watching after `stop()`, and `rebind(to:)` moves it to a new
/// file (atomic saves can replace the inode).
final class FileChangeWatcherTests: XCTestCase {
    private func tempFile(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-\(name)-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    override func setUp() {
        super.setUp()
        // A 20 ms debounce instead of the shipping 0.4 s: these tests wait it
        // out three times over, and what they check is the coalescing and the
        // cancellation, not the interval.
        FileChangeWatcher.debounceInterval = 0.02
    }

    override func tearDown() {
        FileChangeWatcher.debounceInterval = 0.4
        super.tearDown()
    }

    private func settle() async {
        // Let the dispatch source register before we trigger events.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func testFiresOnExternalWrite() async throws {
        let url = try tempFile("fire", [0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        let fired = expectation(description: "watcher fired")

        let watcher = FileChangeWatcher(url: url)
        watcher.onChange = { fired.fulfill() }
        await settle()

        try Data([0x01]).write(to: url)

        await fulfillment(of: [fired], timeout: 5)
        watcher.stop()
    }

    func testDoesNotFireAfterStop() async throws {
        let url = try tempFile("stop", [0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        let unexpected = expectation(description: "should not fire")
        unexpected.isInverted = true

        let watcher = FileChangeWatcher(url: url)
        watcher.onChange = { unexpected.fulfill() }
        await settle()
        watcher.stop()

        try Data([0x01]).write(to: url)

        // Long enough to outlast the debounce several times over — the point is
        // that nothing arrives, not how long we are willing to wait.
        await fulfillment(of: [unexpected], timeout: 0.3)
    }

    func testRebindWatchesNewFile() async throws {
        let url1 = try tempFile("old", [0x00])
        let url2 = try tempFile("new", [0x00])
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }
        let fired = expectation(description: "rebound watcher fired")

        let watcher = FileChangeWatcher(url: url1)
        watcher.onChange = { fired.fulfill() }
        await settle()
        watcher.rebind(to: url2)
        await settle()

        try Data([0x01]).write(to: url2)

        await fulfillment(of: [fired], timeout: 5)
        watcher.stop()
    }

    // MARK: - The descriptor

    /// How many of this process's descriptors are open on `url`.
    private func descriptors(on url: URL) -> Int {
        let wanted = url.resolvingSymlinksInPath().path
        var count = 0
        for fd in 0..<getdtablesize() {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &path) == 0,
               URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path == wanted {
                count += 1
            }
        }
        return count
    }

    /// Waits up to two seconds for `count` descriptors on `url`: a source's
    /// cancel handler, which closes it, runs on the watcher's queue.
    private func waitFor(_ count: Int, on url: URL) async -> Int {
        for _ in 0..<40 where descriptors(on: url) != count {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return descriptors(on: url)
    }

    /// A watcher let go of closes its descriptor. Its cancel handler held
    /// itself weakly, so a watcher that went with its document — the usual
    /// end — left the file open for the life of the process: one more
    /// descriptor per document closed, on a file that may long be deleted.
    func testAWatcherLetGoClosesItsFile() async throws {
        let url = try tempFile("released", [1, 2, 3])
        defer { try? FileManager.default.removeItem(at: url) }
        var watcher: FileChangeWatcher? = FileChangeWatcher(url: url)
        XCTAssertEqual(descriptors(on: url), 1, "the watcher holds the file open")
        watcher = nil
        XCTAssertNil(watcher)
        let left = await waitFor(0, on: url)
        XCTAssertEqual(left, 0, "nothing holds the file once the watcher is gone")
    }

    /// Rebinding closes the old file's descriptor, not the new one's: the old
    /// source's cancel handler runs after the new descriptor is open, and it
    /// closed whichever one the watcher held by then.
    func testRebindClosesTheOldFileAndKeepsTheNew() async throws {
        let old = try tempFile("old", [1])
        let new = try tempFile("new", [2])
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        let watcher = FileChangeWatcher(url: old)
        defer { watcher.stop() }
        watcher.rebind(to: new)
        let onOld = await waitFor(0, on: old)
        XCTAssertEqual(onOld, 0, "the old file is let go")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(descriptors(on: new), 1, "the new file stays watched")
    }
}
