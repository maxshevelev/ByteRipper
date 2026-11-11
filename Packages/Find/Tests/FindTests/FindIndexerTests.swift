import XCTest
@testable import Find

/// A text, searched by exact substring, in UTF-16 units. `gate`, when set,
/// holds every scan until it is opened, so a test can look at a search while
/// it is still running.
struct TextContent: FindContent {
    let units: [UInt16]
    var gate: Gate?
    /// How many units each index batch covers.
    var batch = 4

    init(_ text: String, gate: Gate? = nil) {
        units = Array(text.utf16)
        self.gate = gate
    }

    var extent: UInt64 { UInt64(units.count) }

    func matchLength(of query: String) -> Int { query.utf16.count }

    private func starts(of query: String, in range: Range<Int>) -> [UInt64] {
        let needle = Array(query.utf16)
        guard !needle.isEmpty, needle.count <= units.count else { return [] }
        var found: [UInt64] = []
        var i = range.lowerBound
        while i < range.upperBound, i + needle.count <= units.count {
            if Array(units[i..<i + needle.count]) == needle {
                found.append(UInt64(i))
                i += needle.count
            } else {
                i += 1
            }
        }
        return found
    }

    func firstMatch(of query: String, from anchor: UInt64, direction: SearchDirection,
                    shouldCancel: () -> Bool, progress: (Double) -> Void) throws -> Range<UInt64>? {
        try gate?.wait(shouldCancel: shouldCancel)
        let all = starts(of: query, in: 0..<units.count)
        let length = UInt64(query.utf16.count)
        switch direction {
        case .forward:
            return all.first { $0 >= anchor }.map { $0..<$0 + length }
        case .backward:
            return all.last { $0 + length <= anchor }.map { $0..<$0 + length }
        }
    }

    func matchStarts(of query: String, shouldCancel: @escaping @Sendable () -> Bool,
                     progress: @escaping @Sendable (Double) -> Void)
        -> AsyncThrowingStream<MatchBatch, any Error> {
        let content = self
        return AsyncThrowingStream { continuation in
            Task.detached {
                do {
                    try content.gate?.wait(shouldCancel: shouldCancel)
                    // Whole matches only: a batch ends where no match straddles it.
                    var cursor = 0
                    let all = content.starts(of: query, in: 0..<content.units.count)
                    while cursor < content.units.count {
                        if shouldCancel() { throw CancellationError() }
                        let end = min(cursor + content.batch, content.units.count)
                        let inBatch = all.filter { $0 >= UInt64(cursor) && $0 < UInt64(end) }
                        continuation.yield(MatchBatch(starts: inBatch, scannedUpTo: UInt64(end)))
                        cursor = end
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Holds the scans that wait on it until it is opened.
final class Gate: @unchecked Sendable {
    private let lock = NSCondition()
    private var open = false
    private(set) var waiting = 0

    func wait(shouldCancel: () -> Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        waiting += 1
        while !open {
            if shouldCancel() { throw CancellationError() }
            _ = lock.wait(until: Date().addingTimeInterval(0.005))
        }
    }

    func release() {
        lock.lock()
        open = true
        lock.broadcast()
        lock.unlock()
    }

    var waiters: Int {
        lock.lock(); defer { lock.unlock() }
        return waiting
    }
}

final class Activity: FindActivity, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var finished = false
    func report(_ fraction: Double) {}
    func finish() { lock.lock(); finished = true; lock.unlock() }
}

@MainActor
final class FindIndexerTests: XCTestCase {
    /// Waits until the index has stopped being built.
    private func settle(_ indexer: FindIndexer<TextContent>, file: StaticString = #filePath,
                        line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while indexer.isIndexing, Date() < deadline { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(indexer.isIndexing, "the index finished", file: file, line: line)
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    /// The pass goes through the candidates in order and the first that finds
    /// something is the search: its match is the reader's, and its index fills
    /// to the whole content.
    func testThePassTakesTheFirstCandidateThatFindsAndIndexesIt() async {
        let indexer = FindIndexer(content: TextContent("one two three two"))
        let outcome = await indexer.find(["four", "two"], from: 0, direction: .forward)
        XCTAssertEqual(outcome, .found(index: 1, query: "two", range: 4..<7, wrapped: false))
        XCTAssertEqual(indexer.current, 4..<7, "the reader is on the match")
        XCTAssertTrue(indexer.isHighlighting)
        await settle(indexer)
        XCTAssertEqual(indexer.matches?.query, "two")
        XCTAssertEqual(indexer.matches?.total, 2)
        XCTAssertEqual(indexer.matches?.isComplete, true)
        XCTAssertEqual(indexer.currentIndex, 0)
    }

    /// Nothing anywhere is a finished search with no matches, in the last
    /// candidate's name.
    func testNothingFoundIsAFinishedEmptySearch() async {
        let indexer = FindIndexer(content: TextContent("abc"))
        let outcome = await indexer.find(["x", "y"], from: 0, direction: .forward)
        XCTAssertEqual(outcome, .nothing)
        XCTAssertEqual(indexer.matches?.query, "y")
        XCTAssertEqual(indexer.matches?.isComplete, true)
        XCTAssertEqual(indexer.matches?.isEmpty, true)
        XCTAssertFalse(indexer.isIndexing)
    }

    /// From past the last match, the pass comes round the end and says so.
    func testThePassWrapsAndSaysSo() async {
        let indexer = FindIndexer(content: TextContent("ab ab"))
        let outcome = await indexer.find(["ab"], from: 4, direction: .forward)
        XCTAssertEqual(outcome, .found(index: 0, query: "ab", range: 0..<2, wrapped: true))
    }

    /// Without landing, the search is only listed: nobody is put on a match.
    func testAListedSearchPutsNobodyOnAMatch() async {
        let indexer = FindIndexer(content: TextContent("ab ab"))
        _ = await indexer.find(["ab"], from: 0, direction: .forward, landing: false)
        XCTAssertNil(indexer.current)
        await settle(indexer)
        XCTAssertEqual(indexer.matches?.total, 2)
    }

    /// A finished index answers a step at once, both ways, and wraps.
    func testAFinishedIndexAnswersStepsAndWraps() async {
        let indexer = FindIndexer(content: TextContent("ab ab ab"))
        _ = await indexer.find(["ab"], from: 0, direction: .forward)
        await settle(indexer)

        let next = await indexer.step(.forward, from: 2)
        XCTAssertEqual(next, .indexed(MatchStep(index: 1, range: 3..<5, wrapped: false)))
        XCTAssertEqual(indexer.current, 3..<5)
        let round = await indexer.step(.forward, from: 8)
        XCTAssertEqual(round, .indexed(MatchStep(index: 0, range: 0..<2, wrapped: true)))
        let back = await indexer.step(.backward, from: 0)
        XCTAssertEqual(back, .indexed(MatchStep(index: 2, range: 6..<8, wrapped: true)))
        XCTAssertEqual(indexer.currentIndex, 2)
    }

    /// While the index is still filling, "nothing ahead" may mean "not found
    /// yet": the step scans instead of wrapping, and the index goes on.
    func testAStepPastAHalfBuiltIndexScansAndLeavesTheIndexRunning() async {
        let gate = Gate()
        var content = TextContent("ab ab ab", gate: nil)
        let indexer = FindIndexer(content: content)
        _ = await indexer.find(["ab"], from: 0, direction: .forward)
        await settle(indexer)
        // Now an index that cannot finish: the gate holds it.
        content.gate = gate
        indexer.content = content
        indexer.index("ab")
        XCTAssertTrue(indexer.isIndexing)
        await waitFor { gate.waiters >= 1 }

        // The step's own scan waits on the gate too; open it once the step is
        // under way, and the index finishes behind it.
        async let stepped = indexer.step(.forward, from: 7)
        await waitFor { gate.waiters >= 2 }
        XCTAssertTrue(indexer.isIndexing, "the step did not stop the index")
        gate.release()
        let outcome = await stepped
        XCTAssertEqual(outcome, .scanned(range: 0..<2, wrapped: true))
        XCTAssertEqual(indexer.current, 0..<2)
        await settle(indexer)
        XCTAssertEqual(indexer.matches?.total, 3)
    }

    /// A second press for the same candidates while the pass still looks is
    /// answered by that pass.
    func testASecondPressForTheSameSearchIsAlreadyRunning() async {
        let gate = Gate()
        let indexer = FindIndexer(content: TextContent("ab", gate: gate))
        async let first = indexer.find(["ab"], from: 0, direction: .forward)
        await waitFor { indexer.passInFlight != nil }
        let second = await indexer.find(["ab"], from: 0, direction: .forward)
        XCTAssertEqual(second, .alreadyRunning)
        gate.release()
        let outcome = await first
        XCTAssertEqual(outcome, .found(index: 0, query: "ab", range: 0..<2, wrapped: false))
    }

    /// A pass stopped through its activity's (×) answers `cancelled`, and its
    /// activity is finished.
    func testAStoppedPassIsCancelled() async {
        let gate = Gate()
        let indexer = FindIndexer(content: TextContent("ab", gate: gate))
        var activities: [Activity] = []
        var cancels: [() -> Void] = []
        indexer.beginActivity = { cancel in
            let activity = Activity()
            activities.append(activity)
            cancels.append(cancel)
            return activity
        }
        async let outcome = indexer.find(["ab"], from: 0, direction: .forward)
        await waitFor { gate.waiters >= 1 }
        cancels.first?()
        let result = await outcome
        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(indexer.passInFlight)
        XCTAssertTrue(activities.first?.finished == true)
    }

    /// A new search drops the batches of the index before it: they say
    /// nothing about this one.
    func testANewSearchIgnoresTheIndexBeforeIt() async {
        let gate = Gate()
        let indexer = FindIndexer(content: TextContent("ab cd ab", gate: gate))
        indexer.index("ab")
        await waitFor { gate.waiters >= 1 }
        indexer.content = TextContent("ab cd ab")
        let outcome = await indexer.find(["cd"], from: 0, direction: .forward)
        XCTAssertEqual(outcome, .found(index: 0, query: "cd", range: 3..<5, wrapped: false))
        gate.release()
        await settle(indexer)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(indexer.matches?.query, "cd")
        XCTAssertEqual(indexer.matches?.total, 1)
    }

    /// The content changed: the set goes, the index stops, and both are said.
    func testInvalidatingDropsTheSetAndStopsTheIndex() async {
        let gate = Gate()
        let indexer = FindIndexer(content: TextContent("ab ab", gate: gate))
        var setChanges = 0
        indexer.onSetChanged = { setChanges += 1 }
        indexer.index("ab")
        XCTAssertEqual(setChanges, 1)
        indexer.invalidate()
        XCTAssertNil(indexer.matches)
        XCTAssertFalse(indexer.isIndexing)
        XCTAssertEqual(setChanges, 2)
        gate.release()
    }

    /// An index started without a pass says once that it found something.
    func testAnIndexSaysOnceThatItFoundSomething() async {
        var content = TextContent("ab ab ab ab")
        content.batch = 2
        let indexer = FindIndexer(content: content)
        indexer.publishInterval = 0
        var found: [String] = []
        indexer.onFoundSomething = { found.append($0) }
        indexer.index("ab")
        await settle(indexer)
        XCTAssertEqual(found, ["ab"])
    }

    /// Two indexers are two searches: stopping one leaves the other alone.
    func testTwoIndexersAreIndependent() async {
        let gate = Gate()
        let left = FindIndexer(content: TextContent("ab ab", gate: gate))
        let right = FindIndexer(content: TextContent("ab ab", gate: gate))
        left.index("ab")
        right.index("ab")
        left.invalidate()
        XCTAssertTrue(right.isIndexing, "the other search goes on")
        gate.release()
        await settle(right)
        XCTAssertEqual(right.matches?.total, 2)
        XCTAssertNil(left.matches)
    }

    /// Ending the showing keeps the set; showing it again on an index puts
    /// the reader there.
    func testEndingTheShowingKeepsTheSet() async {
        let indexer = FindIndexer(content: TextContent("ab ab"))
        _ = await indexer.find(["ab"], from: 0, direction: .forward)
        await settle(indexer)
        indexer.endHighlighting()
        XCTAssertNil(indexer.highlightedMatches)
        XCTAssertNil(indexer.current)
        XCTAssertEqual(indexer.matches?.total, 2, "the set stays")
        XCTAssertTrue(indexer.matchRanges(intersecting: 0..<5).isEmpty, "and is not drawn")
        indexer.highlight(current: 1)
        XCTAssertEqual(indexer.current, 3..<5)
        XCTAssertEqual(indexer.matchRanges(intersecting: 0..<5), [0..<2, 3..<5])
    }
}
