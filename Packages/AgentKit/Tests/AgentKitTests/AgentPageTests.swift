import XCTest
@testable import AgentKit

/// A list answer cut to fit the answer bound, and the cursor that goes on
/// from where it stopped.
final class AgentPageTests: XCTestCase {
    private func items(_ count: Int, size: Int = 100) -> [JSONValue] {
        (0..<count).map { .object(["n": .count($0), "pad": .string(String(repeating: "x", count: size))]) }
    }

    private func page(after: String? = nil, fingerprint: String = "f") throws -> AgentPage {
        var values: [String: JSONValue] = [:]
        if let after { values["after"] = .string(after) }
        return try AgentPage(AgentArguments(values), fingerprint: fingerprint)
    }

    func testAPageThatFitsIsUnchanged() throws {
        let answer = try page().answer(["total": 3], key: "items", items: items(3), total: 3, bound: 24 << 10)
        XCTAssertEqual(answer["items"]?.arrayValue?.count, 3)
        XCTAssertEqual(answer["next"], .null)
        XCTAssertNil(answer["truncated"])
    }

    func testAPageCutByLimitHasANextAndNoMark() throws {
        let answer = try page().answer([:], key: "items", items: Array(items(10).prefix(4)), total: 10, bound: 24 << 10)
        XCTAssertEqual(answer["items"]?.arrayValue?.count, 4)
        XCTAssertEqual(answer["next"], "4:f")
        XCTAssertNil(answer["truncated"])
    }

    /// Twice the bound's worth: the page stays within it, says why it is
    /// short, and the pages one after another are every item once.
    func testPagesCutBySizeStayInTheBoundAndAddUpToTheWhole() throws {
        let all = items(100, size: 400)
        let bound = 20_000
        var seen: [JSONValue] = []
        var after: String?
        var pages = 0
        repeat {
            let paging = try page(after: after)
            let candidates = Array(all.dropFirst(paging.first).prefix(1000))
            let answer = try paging.answer(["totals": ["items": 100]], key: "items", items: candidates,
                                           total: all.count, bound: bound)
            XCTAssertLessThanOrEqual(answer.encoded().count, bound)
            let got = try XCTUnwrap(answer["items"]?.arrayValue)
            XCTAssertFalse(got.isEmpty)
            seen += got
            after = answer["next"]?.stringValue
            if after != nil { XCTAssertEqual(answer["truncated"], "size") }
            pages += 1
        } while after != nil
        XCTAssertEqual(seen, all, "no item twice, none left out")
        XCTAssertGreaterThan(pages, 2)
    }

    /// Several lists in turn: each keeps its key, and the cursor counts across.
    func testListsInTurnArePagedAsOne() throws {
        let sequence: [(key: String, item: JSONValue)] = [("a", 1), ("a", 2), ("b", 3), ("c", 4)]
        let first = try page().answer([:], keys: ["a", "b", "c"], items: Array(sequence.prefix(3)), total: 4, bound: 1000)
        XCTAssertEqual(first["a"], [1, 2])
        XCTAssertEqual(first["b"], [3])
        XCTAssertEqual(first["c"], [])
        XCTAssertEqual(first["next"], "3:f")
        let second = try page(after: "3:f").answer([:], keys: ["a", "b", "c"], items: Array(sequence.dropFirst(3)),
                                                    total: 4, bound: 1000)
        XCTAssertEqual(second["a"], [])
        XCTAssertEqual(second["c"], [4])
        XCTAssertEqual(second["next"], .null)
    }

    func testAnItemTooLargeAloneIsShortenedOrNamed() throws {
        let huge: JSONValue = ["pad": .string(String(repeating: "x", count: 5000))]
        let shortened = try page().answer([:], key: "items", items: [huge, 1], total: 2, bound: 1000) { _ in
            ["pad": "xxx", "truncated": "item"]
        }
        XCTAssertEqual(shortened["items"], [["pad": "xxx", "truncated": "item"], 1], "and the page goes on")
        XCTAssertEqual(shortened["next"], .null)
        XCTAssertNil(shortened["truncated"], "the page itself is not cut")

        XCTAssertThrowsError(try page(after: "7:f").answer([:], key: "items", items: [huge], total: 9, bound: 1000)) {
            XCTAssertEqual(($0 as? AgentToolError)?.message,
                           "Item 7 alone is over the 1000-byte bound for one answer, even shortened; "
                           + "narrow the question so it is not among the answers.")
        }
    }

    /// Items each too large alone are each shortened, as many to a page as
    /// fit shortened; one that fits a page of its own is not shortened.
    func testEveryItemTooLargeAloneIsShortenedWhereverItFalls() throws {
        let huge: JSONValue = ["pad": .string(String(repeating: "x", count: 5000))]
        let small: JSONValue = ["pad": .string(String(repeating: "y", count: 600))]
        let answer = try page().answer([:], key: "items", items: [huge, huge, small, small, huge], total: 5, bound: 1000) { item in
            item == huge ? ["pad": "xxx", "truncated": "item"] : nil
        }
        XCTAssertEqual(answer["items"], [["pad": "xxx", "truncated": "item"], ["pad": "xxx", "truncated": "item"], small],
                       "the small one whole, and the page full after it")
        XCTAssertEqual(answer["next"], "3:f")
        XCTAssertEqual(answer["truncated"], "size")
    }

    func testACursorFromAnotherQuestionIsRefused() {
        XCTAssertThrowsError(try page(after: "3:old", fingerprint: "new")) {
            XCTAssertEqual(($0 as? AgentToolError)?.message,
                           "A document changed since that page, or the question did; ask again without `after`.")
        }
        XCTAssertThrowsError(try page(after: "three")) {
            XCTAssertEqual(($0 as? AgentToolError)?.message, "`after` is not a `next` this tool gave.")
        }
        XCTAssertEqual(try page(after: "3:f").first, 3)
    }
}
