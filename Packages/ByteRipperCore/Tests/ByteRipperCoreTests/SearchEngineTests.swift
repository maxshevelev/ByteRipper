import XCTest
@testable import ByteRipperCore

/// The dump's search, run the way the find bar runs it: `ByteFindContent`
/// over `PatternScan` (#33). Find Next and Find Previous are its `firstMatch`,
/// Find All and the highlight its `matchStarts`. Holes and the overlap of a
/// run are `ByteFindContentTests`; this is everything else a search owes —
/// parsing, edges, windows, unsaved content, cancellation, progress, and the
/// case rules of each encoding.
final class SearchEngineTests: XCTestCase {
    private func parse(_ text: String, _ encoding: SearchEncoding) throws -> [UInt8] {
        try SearchEngine.parsePattern(text, encoding: encoding).bytes
    }

    private func query(_ pattern: [UInt8], folding: CaseFolding = .exact) -> ByteQuery {
        ByteQuery(pattern: SearchPattern(bytes: pattern, encoding: .hex), folding: folding)
    }

    /// Find Next (`.forward`) or Find Previous (`.backward`) from `from`.
    private func find(_ pattern: [UInt8], in storage: ByteStorage, from: UInt64 = 0,
                      direction: SearchDirection = .forward, folding: CaseFolding = .exact,
                      chunkSize: Int = 7, shouldCancel: () -> Bool = { false },
                      progress: (Double) -> Void = { _ in }) throws -> Range<UInt64>? {
        try ByteFindContent(storage: storage, chunkSize: chunkSize)
            .firstMatch(of: query(pattern, folding: folding), from: from, direction: direction,
                        shouldCancel: shouldCancel, progress: progress)
    }

    private func find(_ pattern: [UInt8], in bytes: [UInt8], from: UInt64 = 0,
                      direction: SearchDirection = .forward, folding: CaseFolding = .exact,
                      chunkSize: Int = 7) throws -> Range<UInt64>? {
        try find(pattern, in: ArrayStorage(bytes), from: from, direction: direction,
                 folding: folding, chunkSize: chunkSize)
    }

    /// Every match, as the index that greys the dump and fills Find All gets them.
    private func findAll(_ pattern: [UInt8], in storage: ByteStorage, folding: CaseFolding = .exact,
                         chunkSize: Int = 7) async throws -> [Range<UInt64>] {
        let content = ByteFindContent(storage: storage, chunkSize: chunkSize)
        var found: [Range<UInt64>] = []
        for try await batch in content.matchStarts(of: query(pattern, folding: folding),
                                                   shouldCancel: { false }, progress: { _ in }) {
            found += batch.starts.map { $0..<($0 + UInt64(pattern.count)) }
        }
        return found
    }

    private func findAll(_ pattern: [UInt8], in bytes: [UInt8], folding: CaseFolding = .exact,
                         chunkSize: Int = 7) async throws -> [Range<UInt64>] {
        try await findAll(pattern, in: ArrayStorage(bytes), folding: folding, chunkSize: chunkSize)
    }

    // MARK: - Pattern parsing

    func testParseHexVariants() throws {
        XCTAssertEqual(try parse("DEADBEEF", .hex), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try parse("DE AD BE EF", .hex), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try parse("0xDE 0xAD", .hex), [0xDE, 0xAD])
        XCTAssertEqual(try parse("deadbeef", .hex), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try parse("ff", .hex), [0xFF])
        XCTAssertEqual(try parse("00", .hex), [0x00])
    }

    func testParseHexInvalid() {
        let bad = ["", "  ", "0x", "0X", "DEADBEE", "XYZ", "12G", "0x1G", "DE 0x", "abcde"]
        for text in bad {
            XCTAssertThrowsError(try parse(text, .hex), text) { error in
                XCTAssertEqual(error as? SearchError, .invalidHexPattern, text)
            }
        }
    }

    func testParseAsciiAndUtf8() throws {
        XCTAssertEqual(try parse("Hello", .ascii), [0x48, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertThrowsError(try parse("é", .ascii)) { error in
            XCTAssertEqual(error as? SearchError, .undecodableText)
        }
        XCTAssertEqual(try parse("Hello", .utf8), [0x48, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertEqual(try parse("é", .utf8), [0xC3, 0xA9])
        XCTAssertThrowsError(try parse("", .utf8)) { error in
            XCTAssertEqual(error as? SearchError, .emptyPattern)
        }
    }

    func testParseUtf16() throws {
        // "A" = 0x0041; "é" = 0x00E9.
        XCTAssertEqual(try parse("A", .utf16LE), [0x41, 0x00])
        XCTAssertEqual(try parse("A", .utf16BE), [0x00, 0x41])
        XCTAssertEqual(try parse("é", .utf16LE), [0xE9, 0x00])
        XCTAssertEqual(try parse("é", .utf16BE), [0x00, 0xE9])
    }

    func testEmptyPatternThrows() {
        for direction in [SearchDirection.forward, .backward] {
            XCTAssertThrowsError(try find([], in: [1, 2, 3], from: direction == .forward ? 0 : 3,
                                          direction: direction)) { error in
                XCTAssertEqual(error as? SearchError, .emptyPattern, "\(direction)")
            }
        }
    }

    // MARK: - Find

    func testFindAtStartMiddleEnd() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xDE, 0xAD]
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 0), 0..<2)
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 1), 5..<7)
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 5), 5..<7)
        XCTAssertNil(try find([0xDE, 0xAD], in: bytes, from: 6))
        XCTAssertEqual(try find([0xBE, 0xEF], in: bytes, from: 0), 2..<4)
    }

    /// The edges of a search: nothing to find, nothing that could fit, a
    /// one-byte pattern (the shortest window there is), and a match ending
    /// exactly at EOF.
    func testFindEdges() throws {
        let cases: [(name: String, pattern: [UInt8], bytes: [UInt8], from: UInt64,
                     direction: SearchDirection, expected: Range<UInt64>?)] = [
            ("no match, forward", [0xAA, 0xBB], [0x00, 0x01, 0x02], 0, .forward, nil),
            ("no match, backward from EOF", [0xAA, 0xBB], [0x00, 0x01, 0x02], 3, .backward, nil),
            ("no match for a single byte", [0x05], [0x00, 0x01, 0x02], 0, .forward, nil),
            ("a pattern longer than the file", [0x00, 0x01, 0x02, 0x03], [0x00, 0x01], 0, .forward, nil),
            ("a pattern longer than the file, backward", [0x00, 0x01, 0x02, 0x03], [0x00, 0x01], 2, .backward, nil),
            ("a single byte at the start", [0xAA], [0xAA, 0x00, 0xAA, 0x00], 0, .forward, 0..<1),
            ("a single byte past the first match", [0xAA], [0xAA, 0x00, 0xAA, 0x00], 1, .forward, 2..<3),
            ("a match ending at EOF", [0xAA, 0xBB], [0x00, 0x01, 0xAA, 0xBB], 0, .forward, 2..<4),
            ("the last byte of the file", [0xBB], [0x00, 0x01, 0xAA, 0xBB], 0, .forward, 3..<4),
        ]
        for testCase in cases {
            XCTAssertEqual(try find(testCase.pattern, in: testCase.bytes, from: testCase.from,
                                    direction: testCase.direction),
                           testCase.expected, testCase.name)
        }
    }

    func testFindBackward() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xDE, 0xAD]
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 7, direction: .backward), 5..<7)
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 5, direction: .backward), 0..<2)
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 4, direction: .backward), 0..<2)
        // A caret at 0 has nothing before it, so there is no previous match.
        XCTAssertNil(try find([0xDE, 0xAD], in: bytes, from: 0, direction: .backward))

        // A one-byte pattern: the shortest window, where the overlap arithmetic
        // that walks backward has nothing to spare.
        let single: [UInt8] = [0xAA, 0x00, 0xAA, 0x00]
        XCTAssertEqual(try find([0xAA], in: single, from: 4, direction: .backward), 2..<3)
        XCTAssertEqual(try find([0xAA], in: single, from: 1, direction: .backward), 0..<1)
        XCTAssertNil(try find([0xAA], in: single, from: 0, direction: .backward))
    }

    func testFindBackwardExcludesMatchStartingAtCaret() throws {
        // [AA] at index 4 starts exactly at the caret; it must NOT be returned.
        // Otherwise Find Previous from a caret sitting on a match would re-find
        // that same match instead of moving backward.
        let bytes: [UInt8] = [0xAA, 0x00, 0xAA, 0x00, 0xAA]
        XCTAssertEqual(try find([0xAA], in: bytes, from: 4, direction: .backward), 2..<3)
    }

    /// Changed with #33: Find Previous is the last match *starting* before the
    /// caret, so one that starts before it and runs past it counts (the old
    /// scan wanted the match to end at or before the caret, and found 0..<2).
    func testFindBackwardIncludesAMatchRunningPastTheCaret() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xDE, 0xAD]
        XCTAssertEqual(try find([0xDE, 0xAD], in: bytes, from: 6, direction: .backward), 5..<7)
    }

    func testFindAcrossChunkBoundary() throws {
        // Chunk size 3; pattern straddles offsets 2..<5 (boundary at 3).
        let bytes: [UInt8] = [0x00, 0x01, 0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x00]
        XCTAssertEqual(try find([0xAA, 0xBB, 0xCC], in: bytes, chunkSize: 3), 2..<5)
        // Backward search across the same boundary.
        XCTAssertEqual(try find([0xAA, 0xBB, 0xCC], in: bytes, from: 8, direction: .backward, chunkSize: 3), 2..<5)
    }

    func testFindUsesCurrentUnsavedContent() throws {
        let base = ArrayStorage([0xAA, 0x00, 0x00, 0x00])
        let storage = EditOverlayStorage(base: base)
        try storage.overwrite(range: 1..<2, with: [0xBB])

        XCTAssertEqual(try find([0xBB], in: storage), 1..<2)
        XCTAssertEqual(try find([0x00, 0x00], in: storage), 2..<4)
        XCTAssertNil(try find([0x00, 0x00], in: storage, from: 3))
        XCTAssertEqual(try find([0xAA], in: storage), 0..<1)
        XCTAssertEqual(try find([0xBB], in: storage, from: 4, direction: .backward), 1..<2)
    }

    func testFindCancellationThrows() throws {
        let storage = ArrayStorage([UInt8](repeating: 0, count: 32))
        for direction in [SearchDirection.forward, .backward] {
            XCTAssertThrowsError(try find([0xAA], in: storage, from: direction == .forward ? 0 : 32,
                                          direction: direction, chunkSize: 4,
                                          shouldCancel: { true })) { error in
                XCTAssertTrue(error is CancellationError, "\(direction)")
            }
        }
    }

    // MARK: - Case-insensitive find (§11)

    func testFindCaseInsensitiveAscii() throws {
        // "Hi there" — pattern "HI" matches the lowercase 'i' at 0..<2.
        let bytes = Array("Hi there".utf8)
        XCTAssertEqual(try find(Array("HI".utf8), in: bytes, folding: .asciiBytes), 0..<2)
        XCTAssertEqual(try find(Array("hi".utf8), in: bytes, folding: .asciiBytes), 0..<2)
        XCTAssertEqual(try find(Array("THE".utf8), in: bytes, folding: .asciiBytes), 3..<6)
        // Case-sensitive is exact: uppercase "HI" does not match "Hi".
        XCTAssertNil(try find(Array("HI".utf8), in: bytes))
        XCTAssertEqual(try find(Array("Hi".utf8), in: bytes), 0..<2)
    }

    func testFindCaseInsensitiveUtf8() throws {
        // "Café" = C a f é (5 bytes). The ASCII 'C' folds to 'c', so a lowercase
        // pattern matches; but É (0xC3 0x89) never folds to é (0xC3 0xA9), so a
        // case-swapped pattern with the accent does not.
        let bytes = Array("Café".utf8)
        XCTAssertEqual(try find(Array("café".utf8), in: bytes, folding: .asciiBytes), 0..<5)
        // Case-sensitive: only the exact bytes match ("Café"), not "café" or "CAFÉ".
        XCTAssertEqual(try find(Array("Café".utf8), in: bytes), 0..<5)
        XCTAssertNil(try find(Array("café".utf8), in: bytes))
        XCTAssertNil(try find(Array("CAFÉ".utf8), in: bytes, folding: .asciiBytes))
        XCTAssertNil(try find(Array("CAFÉ".utf8), in: bytes))
    }

    func testFindCaseInsensitiveUtf16() throws {
        let bytes = Array("Hi there".data(using: .utf16LittleEndian)!)
        let pattern = Array("HI".data(using: .utf16LittleEndian)!)
        // "HI" UTF-16LE = 48 00 49 00; folds 'I' against the 'i' in "Hi".
        XCTAssertEqual(try find(pattern, in: bytes, folding: .utf16(littleEndian: true)), 0..<4)
        XCTAssertNil(try find(pattern, in: bytes))
    }

    func testFindCaseInsensitiveBackward() throws {
        let bytes = Array("ab AB ab".utf8)
        // Last case-insensitive "ab" is at 6..<8; a case-sensitive search from
        // 5 finds the exact "ab" at 0..<2, the "AB" at 3..<5 being only
        // reachable case-insensitively.
        XCTAssertEqual(try find(Array("AB".utf8), in: bytes, from: 8, direction: .backward,
                                folding: .asciiBytes), 6..<8)
        XCTAssertEqual(try find(Array("ab".utf8), in: bytes, from: 5, direction: .backward), 0..<2)
        // Case-insensitive backward from the last "ab" lands on "AB".
        XCTAssertEqual(try find(Array("ab".utf8), in: bytes, from: 6, direction: .backward,
                                folding: .asciiBytes), 3..<5)
    }

    func testFindCaseInsensitiveAcrossChunkBoundary() throws {
        // Chunk size 3; "AbC" straddles offsets 2..<5 (boundary at 3) and is
        // matched by lowercase "abc" across the boundary.
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.replaceSubrange(2..<5, with: Array("AbC".utf8))
        XCTAssertEqual(try find(Array("abc".utf8), in: bytes, folding: .asciiBytes, chunkSize: 3), 2..<5)
        XCTAssertEqual(try find(Array("abc".utf8), in: bytes, from: 8, direction: .backward,
                                folding: .asciiBytes, chunkSize: 3), 2..<5)
    }

    func testFindExactSearchDistinguishesRawBytes() throws {
        // Case-sensitivity lives in the byte domain: folding only rewrites ASCII
        // letters, so an exact (case-sensitive) search treats 0x41 'A' and
        // 0x61 'a' as different bytes. The Find bar keeps this for hex patterns
        // (its Aa toggle is disabled when the encoding is hex).
        let bytes: [UInt8] = [0x41, 0x62, 0x63]
        XCTAssertEqual(try find([0x41, 0x62, 0x63], in: bytes), 0..<3)
        XCTAssertNil(try find([0x61, 0x62, 0x63], in: bytes))
    }

    // MARK: - Find All (§11)

    func testFindAllFindsEveryOccurrence() async throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0x00, 0xDE, 0xAD, 0xBE, 0xDE, 0xAD]
        let deAd = try await findAll([0xDE, 0xAD], in: bytes)
        XCTAssertEqual(deAd, [0..<2, 4..<6, 7..<9])
        let be = try await findAll([0xBE], in: bytes)
        XCTAssertEqual(be, [2..<3, 6..<7])
    }

    /// The same edges for Find All, whose answer is a list rather than one
    /// range: every byte matching, nothing matching, nothing that could fit, and
    /// a match ending exactly at EOF.
    func testFindAllEdges() async throws {
        let cases: [(name: String, pattern: [UInt8], bytes: [UInt8], expected: [Range<UInt64>])] = [
            ("a single byte matching every byte", [0xAA], [0xAA, 0xAA, 0xAA], [0..<1, 1..<2, 2..<3]),
            ("no match", [0xAA, 0xBB], [0x00, 0x01, 0x02], []),
            ("a pattern longer than the file", [0x00, 0x01, 0x02, 0x03], [0x00, 0x01], []),
            ("a match ending at EOF", [0xAA, 0xBB], [0x00, 0x01, 0xAA, 0xBB], [2..<4]),
        ]
        for testCase in cases {
            let found = try await findAll(testCase.pattern, in: testCase.bytes)
            XCTAssertEqual(found, testCase.expected, testCase.name)
        }
    }

    /// Changed with #33: matches overlap, so "AAAAAA" holds "AAA" at every
    /// start from 0 to 3 — the old scan resumed past each match's end and
    /// reported only 0..<3 and 3..<6.
    func testFindAllReportsOverlappingMatches() async throws {
        let bytes: [UInt8] = [0x41, 0x41, 0x41, 0x41, 0x41, 0x41]  // "AAAAAA"
        let found = try await findAll([0x41, 0x41, 0x41], in: bytes)
        XCTAssertEqual(found, [0..<3, 1..<4, 2..<5, 3..<6])
    }

    func testFindAllAcrossChunkBoundary() async throws {
        // Chunk size 3; the match straddles offset 2..<5 (boundary at 3).
        let bytes: [UInt8] = [0x00, 0x01, 0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x00]
        let found = try await findAll([0xAA, 0xBB, 0xCC], in: bytes, chunkSize: 3)
        XCTAssertEqual(found, [2..<5])
    }

    /// Matches spanning several chunk boundaries, some ending exactly at a
    /// boundary — the overlap must neither drop nor double-count a match.
    func testFindAllAcrossMultipleChunkBoundaries() async throws {
        let bytes: [UInt8] = [0xAA, 0xBB, 0xAA, 0xBB, 0xAA, 0xBB, 0xAA, 0xBB]
        let found = try await findAll([0xAA, 0xBB], in: bytes, chunkSize: 3)
        XCTAssertEqual(found, [0..<2, 2..<4, 4..<6, 6..<8])
    }

    /// A match starting exactly at a chunk boundary is found once, by the
    /// window that owns the fresh portion the boundary opens — never twice.
    func testFindAllMatchAtChunkBoundaryIsCountedOnce() async throws {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0x00]
        let found = try await findAll([0xAA, 0xBB], in: bytes, chunkSize: 4)
        XCTAssertEqual(found, [4..<6])
    }

    func testFindAllCaseInsensitive() async throws {
        let bytes = Array("Hi hi HI".utf8)  // "Hi" at 0, "hi" at 3, "HI" at 6
        let folded = try await findAll(Array("hi".utf8), in: bytes, folding: .asciiBytes)
        XCTAssertEqual(folded, [0..<2, 3..<5, 6..<8])
        // Case-sensitive finds only the exact lowercase pair.
        let exact = try await findAll(Array("hi".utf8), in: bytes)
        XCTAssertEqual(exact, [3..<5])
    }

    func testFindAllAcrossChunkBoundaryCaseInsensitive() async throws {
        // Chunk size 3; "AbC" straddles offsets 2..<5 and matches "abc".
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.replaceSubrange(2..<5, with: Array("AbC".utf8))
        let found = try await findAll(Array("abc".utf8), in: bytes, folding: .asciiBytes, chunkSize: 3)
        XCTAssertEqual(found, [2..<5])
    }

    func testFindAllUsesCurrentUnsavedContent() async throws {
        let base = ArrayStorage([0xAA, 0x00, 0xAA, 0x00])
        let storage = EditOverlayStorage(base: base)
        try storage.overwrite(range: 1..<2, with: [0xAA])
        // After the edit the file is AA AA AA 00: every single-byte match at
        // 0, 1, and 2 is reported.
        let found = try await findAll([0xAA], in: storage)
        XCTAssertEqual(found, [0..<1, 1..<2, 2..<3])
    }

    func testFindAllReportsProgress() async throws {
        let log = ProgressLog()
        let content = ByteFindContent(storage: ArrayStorage([UInt8](repeating: 0, count: 16)), chunkSize: 4)
        var starts: [UInt64] = []
        for try await batch in content.matchStarts(of: query([0xFF]), shouldCancel: { false },
                                                   progress: { log.add($0) }) {
            starts += batch.starts
        }
        XCTAssertEqual(starts, [])
        XCTAssertLessThanOrEqual(log.values.max() ?? 0, 1.0)
        XCTAssertEqual(log.values.last, 1.0)
    }

    // MARK: - matchStarts (the highlighting scan)

    /// The highlighting scan and Find Next agree on every match — the greys,
    /// the results panel and the step must not disagree about what a match is.
    /// Walking Find Next one byte past each start visits exactly the starts
    /// the scan reports, and Find Previous walks them back.
    func testMatchStartsAgreesWithFindNextAndPrevious() async throws {
        let bytes: [UInt8] = [0xAA, 0xAA, 0xAA, 0xAA, 0x00, 0xDE, 0xAA, 0xAA, 0xBE, 0xAA]
        let storage = ArrayStorage(bytes)
        let streamed = try await findAll([0xAA, 0xAA], in: storage, chunkSize: 3).map(\.lowerBound)

        var forward: [UInt64] = []
        var anchor: UInt64 = 0
        while let match = try find([0xAA, 0xAA], in: storage, from: anchor, chunkSize: 3) {
            forward.append(match.lowerBound)
            anchor = match.lowerBound + 1
        }
        var backward: [UInt64] = []
        anchor = storage.size
        while let match = try find([0xAA, 0xAA], in: storage, from: anchor, direction: .backward,
                                   chunkSize: 3) {
            backward.append(match.lowerBound)
            anchor = match.lowerBound
        }
        XCTAssertEqual(streamed, [0, 1, 2, 6])
        XCTAssertEqual(forward, streamed)
        XCTAssertEqual(backward, streamed.reversed())
    }

    /// A batch is a delivery cost, not a limit: the batches partition the
    /// matches in order — a window at a time, and within a window
    /// `defaultBatchSize` at a time, the last one short.
    func testMatchStartsBatchesInOrder() async throws {
        let small = ByteFindContent(storage: ArrayStorage([UInt8](repeating: 0xAA, count: 10)), chunkSize: 4)
        var windows: [[UInt64]] = []
        for try await batch in small.matchStarts(of: query([0xAA]), shouldCancel: { false },
                                                 progress: { _ in }) {
            windows.append(batch.starts)
        }
        XCTAssertEqual(windows, [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]])

        let batchSize = SearchEngine.defaultBatchSize
        let count = 2 * batchSize + 3
        let large = ByteFindContent(storage: ArrayStorage([UInt8](repeating: 0xAA, count: count)))
        var sizes: [Int] = []
        var covered: [UInt64] = []
        var all: [UInt64] = []
        for try await batch in large.matchStarts(of: query([0xAA]), shouldCancel: { false },
                                                 progress: { _ in }) {
            sizes.append(batch.starts.count)
            covered.append(batch.scannedUpTo)
            all += batch.starts
        }
        XCTAssertEqual(sizes, [batchSize, batchSize, 3], "one window, cut into batches")
        XCTAssertEqual(covered, [UInt64(batchSize), UInt64(2 * batchSize), UInt64(count)],
                       "mid-window, what is known is every start up to the batch's last")
        XCTAssertEqual(all, (0..<UInt64(count)).map { $0 }, "in order, none lost, none twice")
    }

    /// The scan is uncapped: the count it feeds is the Find bar's diagnosis of
    /// the pattern, and `defaultMaxResults` is a limit on *listing*, not on
    /// counting.
    func testMatchStartsIsNotCappedByTheResultsLimit() async throws {
        let count = SearchEngine.defaultMaxResults + 500
        let found = try await findAll([0xAA], in: [UInt8](repeating: 0xAA, count: count), chunkSize: 1024)
        XCTAssertEqual(found.count, count, "every occurrence is counted, however many there are")
    }

    /// End to end: the scan fills a `MatchSet` whose picture is exactly the
    /// navigation's own list of matches.
    func testMatchStartsFillsAMatchSet() async throws {
        var bytes = [UInt8](repeating: 0x00, count: 4096)
        let placed: [Int] = [0, 17, 1000, 2048, 4092]
        for offset in placed { bytes[offset] = 0xFF }
        let storage = ArrayStorage(bytes)
        let pattern = SearchPattern(bytes: [0xFF], encoding: .hex)

        var builder = ByteMatchSetBuilder(pattern: pattern, folding: .exact, extent: storage.size)
        for try await batch in ByteFindContent(storage: storage)
            .matchStarts(of: query(pattern.bytes), shouldCancel: { false }, progress: { _ in }) {
            builder.add(batch.starts)
        }
        let set = builder.finish()
        XCTAssertEqual(set.total, placed.count)
        XCTAssertEqual(set.matches(intersecting: 0..<storage.size),
                       placed.map { UInt64($0)..<UInt64($0) + 1 })
        XCTAssertEqual(set.index(atOrAfter: 18), 2, "the ordinal the Find bar shows")
    }

    /// Each instalment says how far the scan has got, and that is what makes a
    /// half-built index usable: every match below the offset is in hand, so the
    /// dump can grey that stretch while the rest is still being scanned (§11).
    func testMatchStartsReportsHowFarItHasScanned() async throws {
        // Four windows of four bytes, a match in the first and the last.
        var bytes = [UInt8](repeating: 0x00, count: 16)
        bytes[1] = 0xFF
        bytes[14] = 0xFF
        let storage = ArrayStorage(bytes)

        var covered: [UInt64] = []
        var starts: [UInt64] = []
        for try await batch in ByteFindContent(storage: storage, chunkSize: 4)
            .matchStarts(of: query([0xFF]), shouldCancel: { false }, progress: { _ in }) {
            covered.append(batch.scannedUpTo)
            starts.append(contentsOf: batch.starts)
        }
        XCTAssertEqual(starts, [1, 14])
        XCTAssertEqual(covered, [4, 8, 12, 16],
                       "a window at a time, including the windows with nothing in them")
        XCTAssertEqual(covered.last, storage.size, "and the last one covers the file")
    }

    /// A set built from part of a scan says so, and the greys read it: what has
    /// been covered is exact, and the total is only "so far".
    func testAPartialSetKnowsItIsPartial() async throws {
        let storage = ArrayStorage([UInt8](repeating: 0xAA, count: 16))
        let pattern = SearchPattern(bytes: [0xAA], encoding: .hex)
        var builder = ByteMatchSetBuilder(pattern: pattern, folding: .exact, extent: storage.size)
        var partial: ByteMatchSet?

        for try await batch in ByteFindContent(storage: storage, chunkSize: 4)
            .matchStarts(of: query(pattern.bytes), shouldCancel: { false }, progress: { _ in }) {
            builder.add(batch.starts)
            if partial == nil { partial = builder.snapshot(indexedUpTo: batch.scannedUpTo) }
        }
        let half = try XCTUnwrap(partial)
        XCTAssertFalse(half.isComplete, "four of sixteen bytes is not the file")
        XCTAssertEqual(half.indexedUpTo, 4)
        XCTAssertEqual(half.total, 4, "the matches in what was covered")
        XCTAssertEqual(half.matches(intersecting: 0..<4), [0..<1, 1..<2, 2..<3, 3..<4],
                       "and they are exact — a snapshot is not an estimate")
        XCTAssertEqual(half.index(atOrAfter: 2), 2, "with the index still answering")

        let whole = builder.finish()
        XCTAssertTrue(whole.isComplete)
        XCTAssertEqual(whole.indexedUpTo, storage.size)
        XCTAssertEqual(whole.total, 16)
    }

    func testMatchStartsEmptyPatternThrows() async {
        let stream = ByteFindContent(storage: ArrayStorage([1, 2, 3]))
            .matchStarts(of: query([]), shouldCancel: { false }, progress: { _ in })
        do {
            for try await _ in stream {}
            XCTFail("an empty pattern must fail the stream")
        } catch {
            XCTAssertEqual(error as? SearchError, .emptyPattern)
        }
    }

    /// A pattern longer than the file finishes the stream with nothing, rather
    /// than failing: an unfinished pattern in the field is not an error.
    /// Changed with #33: the scan still says it covered the file — one empty
    /// batch — where the old stream yielded no batch at all.
    func testMatchStartsPatternLongerThanTheFileYieldsNothing() async throws {
        var batches: [MatchBatch] = []
        for try await batch in ByteFindContent(storage: ArrayStorage([1, 2]))
            .matchStarts(of: query([1, 2, 3, 4]), shouldCancel: { false }, progress: { _ in }) {
            batches.append(batch)
        }
        XCTAssertEqual(batches.flatMap(\.starts), [])
        XCTAssertEqual(batches.last?.scannedUpTo, 2, "and the index knows the file holds none")
    }

    /// A cancelled scan ends the stream normally, delivering whatever complete
    /// batches it had: a superseded search must not throw at the app.
    func testMatchStartsStopsMidScanOnShouldCancel() async throws {
        let counter = CancellationCounter()
        let stream = ByteFindContent(storage: ArrayStorage([UInt8](repeating: 0xAA, count: 32)), chunkSize: 4)
            .matchStarts(of: query([0xAA]), shouldCancel: { counter.bump() > 1 }, progress: { _ in })

        var starts: [UInt64] = []
        do {
            for try await batch in stream { starts.append(contentsOf: batch.starts) }
        } catch {
            XCTFail("a shouldCancel stop must finish the stream normally, got \(error)")
        }
        XCTAssertEqual(starts, [0, 1, 2, 3],
                       "the first chunk's matches arrive, the rest of the file is never scanned")
    }

    // MARK: - Progress contract (0...1)

    /// Windows overlap by `patternLength - 1`, so summing their lengths
    /// overshoots the file: the old forward scan once reported up to 1.36.
    func testForwardProgressNeverExceedsOne() throws {
        let data = MemoryBackedStorage(bytes: [UInt8](repeating: 0x00, count: 100))
        var reported: [Double] = []
        _ = try find([0xFF, 0xFF, 0xFF, 0xFF, 0xFF], in: data, chunkSize: 10,
                     progress: { reported.append($0) })
        XCTAssertFalse(reported.isEmpty, "a multi-chunk scan reports progress")
        XCTAssertLessThanOrEqual(reported.max() ?? 0, 1.0, "progress stays within its contract")
        XCTAssertGreaterThanOrEqual(reported.min() ?? 1, 0.0)
        XCTAssertEqual(reported.last, 1.0, "a completed scan ends at 100 %")
    }

    /// A backward search covers `[0, caret)`, so its progress must be measured
    /// over that span. Measured against the whole file it opened at 91 % for a
    /// caret at 10 % and crawled to 100 %.
    func testBackwardProgressMeasuresTheSearchedSpan() throws {
        let data = MemoryBackedStorage(bytes: [UInt8](repeating: 0x00, count: 1000))
        var reported: [Double] = []
        _ = try find([0xFF], in: data, from: 100, direction: .backward, chunkSize: 10,
                     progress: { reported.append($0) })
        XCTAssertFalse(reported.isEmpty)
        XCTAssertLessThan(reported.first ?? 1, 0.2,
                          "a scan that has just begun must not report near-completion")
        XCTAssertLessThanOrEqual(reported.max() ?? 0, 1.0)
        XCTAssertEqual(reported.last, 1.0, "and it still ends at 100 %")
    }

    // MARK: - Folding is chosen by the encoding (§11)

    /// The byte-wise fold is exactly that — bytes, wherever they sit. It models
    /// case for a single-byte ASCII-compatible encoding and for nothing else,
    /// which is why `CaseFolding` exists: a caller asks for the rule that fits
    /// its encoding instead of a bare Bool.
    func testTheByteWiseFoldIsByteLevel() throws {
        let data = MemoryBackedStorage(bytes: [0x41, 0x00])   // UTF-16BE U+4100
        // A UTF-16BE pattern for U+6100 is 61 00 — a different character.
        let pattern = try SearchEngine.parsePattern("\u{6100}", encoding: .utf16BE)
        XCTAssertEqual(pattern.bytes, [0x61, 0x00])

        XCTAssertNil(try find(pattern.bytes, in: data),
                     "exact matching keeps the two characters apart")
        XCTAssertNotNil(try find(pattern.bytes, in: data, folding: .asciiBytes),
                        "the byte-wise fold cannot tell a code unit's high byte from a letter")
    }

    /// Hex is bytes, and bytes have no case: the rule for hex is exact whatever
    /// the user asked for.
    func testTheRuleForHexIsAlwaysExact() {
        XCTAssertEqual(CaseFolding(encoding: .hex, caseSensitive: false), .exact)
        XCTAssertEqual(CaseFolding(encoding: .hex, caseSensitive: true), .exact)
        XCTAssertEqual(CaseFolding(encoding: .ascii, caseSensitive: false), .asciiBytes)
        XCTAssertEqual(CaseFolding(encoding: .utf8, caseSensitive: false), .asciiBytes)
        XCTAssertEqual(CaseFolding(encoding: .utf16LE, caseSensitive: false), .utf16(littleEndian: true))
        XCTAssertEqual(CaseFolding(encoding: .utf16BE, caseSensitive: false), .utf16(littleEndian: false))
        XCTAssertEqual(CaseFolding(encoding: .utf16LE, caseSensitive: true), .exact)
    }

    /// UTF-16 IS text, so a case-insensitive search has to work there — it just
    /// cannot be done a byte at a time. Folding a *code unit*, and only when its
    /// other byte is zero (i.e. when it encodes an ASCII letter), finds `a` for a
    /// pattern of `A` and leaves `U+6100` alone.
    func testUTF16FoldingMatchesLettersAndNothingElse() throws {
        // "Setup" in UTF-16LE, upper-case S.
        let text = MemoryBackedStorage(bytes: try SearchEngine.parsePattern("Setup", encoding: .utf16LE).bytes)
        let lower = try SearchEngine.parsePattern("setup", encoding: .utf16LE).bytes

        XCTAssertNil(try find(lower, in: text), "exact matching is case-sensitive, as ever")
        XCTAssertEqual(try find(lower, in: text, folding: .utf16(littleEndian: true)),
                       0..<UInt64(lower.count), "and the code-unit fold finds it")

        // The hazard the byte-wise fold walked into: U+6100 (00 61 LE) must not
        // match U+4100 (00 41 LE) — neither code unit encodes an ASCII letter,
        // since the byte that would be the letter is the zero one.
        let u6100 = try SearchEngine.parsePattern("\u{6100}", encoding: .utf16LE)
        let u4100 = MemoryBackedStorage(bytes: try SearchEngine.parsePattern("\u{4100}", encoding: .utf16LE).bytes)
        XCTAssertNil(try find(u6100.bytes, in: u4100, folding: .utf16(littleEndian: true)),
                     "two different characters stay different")
    }

    /// The same, big-endian: the letter is the second byte of the pair.
    func testUTF16BigEndianFoldingMatchesLetters() throws {
        let text = MemoryBackedStorage(bytes: try SearchEngine.parsePattern("BIOS", encoding: .utf16BE).bytes)
        let lower = try SearchEngine.parsePattern("bios", encoding: .utf16BE).bytes

        XCTAssertEqual(try find(lower, in: text, folding: .utf16(littleEndian: false)),
                       0..<UInt64(lower.count))
        XCTAssertNil(try find(lower, in: text, folding: .utf16(littleEndian: true)),
                     "the wrong byte order folds the wrong byte, so nothing matches")
    }

    /// A code unit is two bytes counted from the *string's* own start, not from
    /// any grid in the file — so a UTF-16 string is found wherever it sits, at an
    /// even offset or an odd one. The first version of this folded whole windows
    /// on the file's 2-byte grid, which was faster and missed every upper-case
    /// string at an odd offset.
    func testUTF16FoldingFindsStringsAtAnyOffsetEvenOrOdd() async throws {
        let word = try SearchEngine.parsePattern("Setup", encoding: .utf16LE).bytes
        let pattern = try SearchEngine.parsePattern("setup", encoding: .utf16LE).bytes
        let folding = CaseFolding.utf16(littleEndian: true)

        for padding in 0...3 {
            let data = MemoryBackedStorage(bytes: [UInt8](repeating: 0xFF, count: padding) + word)
            let expected = UInt64(padding)..<UInt64(padding + word.count)

            XCTAssertEqual(try find(pattern, in: data, folding: folding),
                           expected, "forward, at offset \(padding)")
            XCTAssertEqual(try find(pattern, in: data, from: UInt64(padding + word.count),
                                    direction: .backward, folding: folding),
                           expected, "backward, at offset \(padding)")
            let all = try await findAll(pattern, in: data, folding: folding)
            XCTAssertEqual(all, [expected], "Find All, at offset \(padding)")
        }
    }

    /// The same for big-endian, where the letter is the second byte of the pair.
    func testUTF16BigEndianFoldingFindsStringsAtAnyOffset() throws {
        let word = try SearchEngine.parsePattern("BIOS", encoding: .utf16BE).bytes
        let pattern = try SearchEngine.parsePattern("bios", encoding: .utf16BE).bytes

        for padding in 0...3 {
            let data = MemoryBackedStorage(bytes: [UInt8](repeating: 0xFF, count: padding) + word)
            XCTAssertEqual(try find(pattern, in: data, folding: .utf16(littleEndian: false)),
                           UInt64(padding)..<UInt64(padding + word.count),
                           "at offset \(padding)")
        }
    }

    /// A match crossing a window boundary is still found: the candidate walk uses
    /// the same overlapped windows as every other search.
    func testUTF16FoldingFindsAMatchAcrossAWindowBoundary() async throws {
        let word = try SearchEngine.parsePattern("Setup", encoding: .utf16LE).bytes
        let pattern = try SearchEngine.parsePattern("setup", encoding: .utf16LE).bytes
        // The string straddles the boundary of a 16-byte chunk.
        let padding = 13
        let data = MemoryBackedStorage(bytes: [UInt8](repeating: 0xFF, count: padding) + word)
        let expected = UInt64(padding)..<UInt64(padding + word.count)

        XCTAssertEqual(try find(pattern, in: data, folding: .utf16(littleEndian: true), chunkSize: 16),
                       expected)
        XCTAssertEqual(try find(pattern, in: data, from: data.size, direction: .backward,
                                folding: .utf16(littleEndian: true), chunkSize: 16),
                       expected)
        let all = try await findAll(pattern, in: data, folding: .utf16(littleEndian: true), chunkSize: 16)
        XCTAssertEqual(all, [expected])
    }

    /// Find All folds the same way, so a case-insensitive UTF-16 sweep reports
    /// every occurrence whatever its case.
    func testUTF16FoldingInFindAll() async throws {
        let mixed = try SearchEngine.parsePattern("EfiEFIefi", encoding: .utf16LE).bytes
        let data = MemoryBackedStorage(bytes: mixed)
        let pattern = try SearchEngine.parsePattern("efi", encoding: .utf16LE).bytes

        let hits = try await findAll(pattern, in: data, folding: .utf16(littleEndian: true))
        XCTAssertEqual(hits, [0..<6, 6..<12, 12..<18], "all three, one per spelling")
    }
}

/// A thread-safe counter for driving `shouldCancel` in tests: the closure runs
/// on the scan's detached task, so a plain captured `var` would not compile
/// cleanly.
private final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// The progress a scan on its detached task reported, for the test to read
/// once the stream has finished.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [Double] = []
    func add(_ value: Double) {
        lock.lock()
        reported.append(value)
        lock.unlock()
    }
    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return reported
    }
}

/// §11: the one form a hex pattern is shown back in — the form a dump prints,
/// so the text in the field can be compared against the bytes beside it.
final class HexPatternTextTests: XCTestCase {
    func testTheBytesComeBackAsUppercasePairs() throws {
        let pattern = try SearchEngine.parsePattern("deadbeef", encoding: .hex)
        XCTAssertEqual(pattern.hexText, "DE AD BE EF")
    }

    /// Every form the parser accepts leads to the same text, because the text
    /// is derived from the bytes rather than from what was typed.
    func testEveryAcceptedFormLeadsToTheSameText() throws {
        for typed in ["DEADBEEF", "de ad be ef", "DE AD BE EF", "0xDE 0xAD 0xBE 0xEF"] {
            let pattern = try SearchEngine.parsePattern(typed, encoding: .hex)
            XCTAssertEqual(pattern.hexText, "DE AD BE EF", "typed as \(typed)")
        }
    }

    func testASingleByteHasNoSeparator() throws {
        XCTAssertEqual(try SearchEngine.parsePattern("0xff", encoding: .hex).hexText, "FF")
    }

    /// A text pattern's bytes can be written this way too — the property is
    /// about the bytes — but nothing shows them so: the field holds the string
    /// the user is looking for, not its encoding.
    func testTextBytesCanAlsoBeWrittenOut() throws {
        XCTAssertEqual(try SearchEngine.parsePattern("AB", encoding: .ascii).hexText, "41 42")
    }
}
