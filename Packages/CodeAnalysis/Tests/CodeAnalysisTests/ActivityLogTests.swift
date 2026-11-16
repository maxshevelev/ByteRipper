import XCTest
@testable import CodeAnalysis

/// The log the console's Activity page reads: numbered, kept across a
/// restart, two weeks long, pruned at most once a day.
final class ActivityLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A clock the test moves.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private var file: URL { directory.appendingPathComponent("private/events.jsonl") }

    func testEventsAreNumberedAndAReaderAsksForWhatCameAfter() {
        let log = ActivityLog(file: file)
        log.append(.init(kind: ActivityLog.Kind.leaseTake, module: "aa", name: "CpuPei", holder: "local MCP"))
        let second = log.append(.init(kind: ActivityLog.Kind.publish, module: "aa", name: "CpuPei",
                                      holder: "local MCP", revision: 6))
        XCTAssertEqual(second.seq, 2)
        XCTAssertFalse(second.at.isEmpty)
        XCTAssertEqual(log.events().map(\.kind), [ActivityLog.Kind.leaseTake, ActivityLog.Kind.publish])
        XCTAssertEqual(log.events(after: 1).map(\.revision), [6])
        XCTAssertEqual(log.events(after: 0, limit: 1).map(\.seq), [2], "the newest when there are more")
    }

    func testARestartedServerReadsTheLogAndNumbersOn() throws {
        let first = ActivityLog(file: file)
        first.append(.init(kind: ActivityLog.Kind.serverStart, version: "v0.10-686", commit: "746207a7", pid: 1))
        let again = ActivityLog(file: file)
        XCTAssertEqual(again.events().map(\.version), ["v0.10-686"])
        XCTAssertEqual(again.append(.init(kind: ActivityLog.Kind.serverStop)).seq, 2)
        XCTAssertEqual(again.last(of: [ActivityLog.Kind.serverStart, ActivityLog.Kind.serverStop])?.kind,
                       ActivityLog.Kind.serverStop)
        // A line written by a newer server, or cut short, does not stop the rest.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        XCTAssertEqual(ActivityLog(file: file).events().count, 2)
    }

    func testTwoWeeksAreKeptAndTheFileIsPrunedAtMostOnceADay() throws {
        let clock = Clock()
        let start = clock.now
        let day: TimeInterval = 86_400
        func at(_ offset: TimeInterval) -> ActivityLog {
            clock.now = start.addingTimeInterval(offset)
            return ActivityLog(file: file, now: { clock.now })
        }
        at(0).append(.init(kind: ActivityLog.Kind.leaseTake, module: "old"))
        at(2 * day).append(.init(kind: ActivityLog.Kind.leaseTake, module: "recent"))
        // A pruning just before "old" turns two weeks: nothing to drop yet.
        XCTAssertEqual(at(14 * day - 3_600).events().map(\.module), ["old", "recent"])
        // Two hours on "old" is past two weeks, but the last pruning was two hours ago: kept.
        XCTAssertEqual(at(14 * day + 3_600).events().map(\.module), ["old", "recent"])
        // A day after that pruning: it goes, from the file too.
        let due = at(15 * day)
        XCTAssertEqual(due.events().map(\.module), ["recent"])
        XCTAssertEqual(at(15 * day + 60).events().map(\.module), ["recent"])
        XCTAssertEqual(due.append(.init(kind: ActivityLog.Kind.serverStart)).seq, 3, "numbers are never reused")
        // Every event pruned: the next is numbered on, not from 1 again.
        XCTAssertEqual(at(40 * day).events(), [])
        XCTAssertEqual(at(40 * day + 60).append(.init(kind: ActivityLog.Kind.serverStart)).seq, 4)
    }
}
