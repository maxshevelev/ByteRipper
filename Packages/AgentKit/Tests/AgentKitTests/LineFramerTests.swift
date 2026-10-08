import XCTest
@testable import AgentKit

final class LineFramerTests: XCTestCase {
    private func lines(_ framer: inout LineFramer, _ text: String) -> [String] {
        framer.append(Data(text.utf8)).map {
            switch $0 {
            case .message(let data): return String(decoding: data, as: UTF8.self)
            case .tooLong: return "<too long>"
            }
        }
    }

    func testAMessageSplitAcrossChunksIsHeldUntilItsNewline() {
        var framer = LineFramer()
        XCTAssertEqual(lines(&framer, #"{"a":"#), [])
        XCTAssertEqual(lines(&framer, "1}"), [])
        XCTAssertEqual(lines(&framer, "\n"), [#"{"a":1}"#])
    }

    func testSeveralMessagesInOneChunk() {
        var framer = LineFramer()
        XCTAssertEqual(lines(&framer, "one\ntwo\nthr"), ["one", "two"])
        XCTAssertEqual(lines(&framer, "ee\n"), ["three"])
    }

    func testACarriageReturnBeforeTheNewlineIsDropped() {
        var framer = LineFramer()
        XCTAssertEqual(lines(&framer, "one\r\ntwo\r"), ["one"])
        XCTAssertEqual(lines(&framer, "\n"), ["two"])
    }

    func testBlankLinesAreNotMessages() {
        var framer = LineFramer()
        XCTAssertEqual(lines(&framer, "\n\r\none\n\n"), ["one"])
    }

    /// A character split between two reads is put back together, because the
    /// framer cuts bytes, not characters.
    func testAMultiByteCharacterSplitBetweenChunks() {
        var framer = LineFramer()
        let bytes = Array("\"дамп\"\n".utf8)
        XCTAssertEqual(framer.append(Data(bytes[0..<2])), [])
        XCTAssertEqual(framer.append(Data(bytes[2...])), [.message(Data(bytes.dropLast()))])
    }

    func testALineOverTheBoundIsRefusedOnceAndTheNextOneIsRead() {
        var framer = LineFramer(maxLineBytes: 8)
        XCTAssertEqual(lines(&framer, "0123456789\nok\n"), ["<too long>", "ok"])
    }

    /// A peer that never sends a newline costs the bound, not the memory: the
    /// line is refused as soon as it passes it, and its tail is skipped.
    func testALineThatOverrunsAcrossChunksIsSkippedToItsNewline() {
        var framer = LineFramer(maxLineBytes: 8)
        XCTAssertEqual(lines(&framer, "01234"), [])
        XCTAssertEqual(lines(&framer, "56789"), ["<too long>"])
        XCTAssertEqual(lines(&framer, "abcdefghijklmn"), [])
        XCTAssertEqual(lines(&framer, "op\nnext\n"), ["next"])
    }

    func testALineExactlyAtTheBoundIsRead() {
        var framer = LineFramer(maxLineBytes: 4)
        XCTAssertEqual(lines(&framer, "abcd\n"), ["abcd"])
    }
}
