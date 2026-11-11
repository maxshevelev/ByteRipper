import XCTest
@testable import Find

/// The text a code panel searches: substrings in UTF-16 units, case folded or
/// not, whole words when asked (#41).
final class TextFindContentTests: XCTestCase {
    private func all(_ text: String, _ query: TextQuery) async throws -> [UInt64] {
        var starts: [UInt64] = []
        for try await batch in TextFindContent(text: text)
            .matchStarts(of: query, shouldCancel: { false }, progress: { _ in }) {
            starts += batch.starts
        }
        return starts
    }

    private func first(_ text: String, _ query: TextQuery, from anchor: UInt64,
                       _ direction: SearchDirection = .forward) throws -> Range<UInt64>? {
        try TextFindContent(text: text).firstMatch(of: query, from: anchor, direction: direction,
                                                   shouldCancel: { false }, progress: { _ in })
    }

    func testCaseIsFoldedUnlessAskedNot() async throws {
        let text = "Status = EFI_STATUS; status++;"
        let folded = try await all(text, TextQuery(text: "status"))
        XCTAssertEqual(folded, [0, 13, 21])
        let exact = try await all(text, TextQuery(text: "status", caseSensitive: true))
        XCTAssertEqual(exact, [21])
    }

    func testAWholeWordDoesNotFindTheMiddleOfAName() async throws {
        let text = "EfiStatus = Status; Status_1 = Status;"
        let found = try await all(text, TextQuery(text: "Status", wholeWord: true))
        XCTAssertEqual(found, [12, 31], "not EfiStatus, not Status_1")
    }

    func testAPatternEdgeThatIsNotAWordNeedsNoBoundary() async throws {
        let text = "Entry->Size; Header->SizeOfImage"
        let found = try await all(text, TextQuery(text: "->Size", wholeWord: true))
        XCTAssertEqual(found, [5], "after any name, but not running on into SizeOfImage")
    }

    func testMatchesDoNotOverlap() async throws {
        let found = try await all("aaaa", TextQuery(text: "aa"))
        XCTAssertEqual(found, [0, 2])
    }

    func testPositionsAreUTF16Units() async throws {
        // "é" is one unit, "😀" two: offsets are a text view's.
        let text = "é😀 Foo"
        let found = try await all(text, TextQuery(text: "Foo"))
        XCTAssertEqual(found, [4])
        XCTAssertEqual(TextFindContent(text: text).extent, 7)
    }

    func testFirstMatchEachWay() throws {
        let text = "ab ab ab"
        let query = TextQuery(text: "ab")
        XCTAssertEqual(try first(text, query, from: 1), 3..<5)
        XCTAssertEqual(try first(text, query, from: 5, .backward), 3..<5, "the last ending at or before")
        XCTAssertEqual(try first(text, query, from: 1, .backward), nil)
        XCTAssertEqual(try first(text, query, from: 7), nil)
    }

    func testFirstMatchSkipsWhatIsNotAWholeWord() throws {
        let text = "EfiStatus Status"
        let query = TextQuery(text: "Status", wholeWord: true)
        XCTAssertEqual(try first(text, query, from: 0), 10..<16)
        XCTAssertEqual(try first(text, query, from: 16, .backward), 10..<16)
        XCTAssertEqual(try first(text, query, from: 9, .backward), nil)
    }

    func testNothingToFindInAnEmptyPatternOrAShortText() async throws {
        let empty = try await all("abc", TextQuery(text: ""))
        XCTAssertEqual(empty, [])
        let long = try await all("ab", TextQuery(text: "abc"))
        XCTAssertEqual(long, [])
        XCTAssertNil(try first("ab", TextQuery(text: "abc"), from: 0))
    }

    /// The indexer runs over a text as it does over a dump: a pass, then the
    /// index, then steps that wrap.
    @MainActor
    func testTheIndexerSearchesAText() async throws {
        let finder = TextFindIndexer()
        finder.content = TextFindContent(text: "x = Foo(); y = foo(); Foo2();")
        let query = TextQuery(text: "Foo", caseSensitive: true, wholeWord: true)
        let outcome = await finder.find([query], from: 0, direction: .forward)
        XCTAssertEqual(outcome, .found(index: 0, query: query, range: 4..<7, wrapped: false))
        for _ in 0..<200 where finder.matches?.isComplete != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(finder.matches?.total, 1, "not foo, not Foo2")
        let step = await finder.step(.forward, from: 7)
        guard case .indexed(let next) = step else { return XCTFail("an index step: \(step)") }
        XCTAssertEqual(next.range, 4..<7)
        XCTAssertTrue(next.wrapped, "the only match, come round to")
    }
}

/// One query over many texts (#41): groups in the corpus's order, each hit
/// with its line, and a limit that says it stopped.
final class TextCorpusSearchTests: XCTestCase {
    func testGroupsHoldTheirHitsWithTheirLines() throws {
        let texts: [(id: Int, text: String)] = [
            (0, "x = 1;\n  Status = Read();\n  return Status;"),
            (1, "return 0;"),
            (2, "Status_1 = Status;")
        ]
        let result = try TextCorpusSearch.search(TextQuery(text: "Status", caseSensitive: true,
                                                           wholeWord: true), in: texts)
        XCTAssertEqual(result.groups.map(\.id), [0, 2], "only the texts that hold it")
        XCTAssertEqual(result.hitCount, 3)
        XCTAssertFalse(result.isTruncated)
        let first = result.groups[0].hits
        XCTAssertEqual(first.map(\.line), [1, 2])
        XCTAssertEqual(first[0].lineText, "Status = Read();", "the line without its indentation")
        XCTAssertEqual(first[0].rangeInLine, 0..<6)
        XCTAssertEqual(first[1].lineText, "return Status;")
        XCTAssertEqual(first[1].rangeInLine, 7..<13)
        XCTAssertEqual(first[0].range, 9..<15, "the range is the text's own")
        XCTAssertEqual(result.groups[1].hits.map(\.rangeInLine), [11..<17], "not Status_1")
    }

    func testTheLimitStopsTheSearchAndSaysSo() throws {
        let texts: [(id: Int, text: String)] = [(0, "a a a"), (1, "a"), (2, "b")]
        let cut = try TextCorpusSearch.search(TextQuery(text: "a"), in: texts, limit: 2)
        XCTAssertEqual(cut.hitCount, 2)
        XCTAssertTrue(cut.isTruncated)
        let exact = try TextCorpusSearch.search(TextQuery(text: "a"), in: texts, limit: 4)
        XCTAssertEqual(exact.hitCount, 4)
        XCTAssertFalse(exact.isTruncated, "the limit met, with nothing past it")
        let more = try TextCorpusSearch.search(TextQuery(text: "a"), in: texts, limit: 3)
        XCTAssertTrue(more.isTruncated, "the last text's match did not fit")
    }
}
