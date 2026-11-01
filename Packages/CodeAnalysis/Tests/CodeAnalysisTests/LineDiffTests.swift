import XCTest
@testable import CodeAnalysis

/// The line diff the code panel shows a revision by: what two texts share,
/// what only one of them has, and that the script is the shortest there is.
final class LineDiffTests: XCTestCase {
    private func text(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    func testTheSameTextIsAllShared() {
        let diff = LineDiff.between(text(["a", "b"]), text(["a", "b"]))
        XCTAssertEqual(diff.rows, [.same(old: 1, new: 1, text: "a"), .same(old: 2, new: 2, text: "b")])
        XCTAssertEqual(diff.added, 0)
        XCTAssertEqual(diff.removed, 0)
    }

    /// A line changed reads as GitHub shows it: what left, then what came.
    func testAChangedLineReadsRemovedThenAdded() {
        let diff = LineDiff.between(text(["a", "b", "c"]), text(["a", "B", "c"]))
        XCTAssertEqual(diff.rows, [
            .same(old: 1, new: 1, text: "a"),
            .removed(old: 2, text: "b"),
            .added(new: 2, text: "B"),
            .same(old: 3, new: 3, text: "c")
        ])
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 1)
    }

    func testLinesOnlyOneTextHasAtEitherEnd() {
        let added = LineDiff.between(text(["a"]), text(["x", "a", "y"]))
        XCTAssertEqual(added.rows, [
            .added(new: 1, text: "x"),
            .same(old: 1, new: 2, text: "a"),
            .added(new: 3, text: "y")
        ])
        let removed = LineDiff.between(text(["x", "a", "y"]), text([]))
        XCTAssertEqual(removed.removed, 3)
        XCTAssertEqual(removed.added, 0)
        XCTAssertEqual(removed.rows.first, .removed(old: 1, text: "x"))
    }

    func testEmptyTexts() {
        let both = LineDiff.between("", "")
        XCTAssertTrue(both.rows.isEmpty)
        let fromNothing = LineDiff.between("", text(["a"]))
        XCTAssertEqual(fromNothing.rows, [.added(new: 1, text: "a")])
    }

    /// A last line without a closing newline is still a line, and one more
    /// newline does not make an empty one.
    func testTheClosingNewlineIsNotALine() {
        XCTAssertEqual(LineDiff.lines("a\n"), ["a"])
        XCTAssertEqual(LineDiff.lines("a"), ["a"])
        XCTAssertEqual(LineDiff.lines(""), [])
        XCTAssertEqual(LineDiff.lines("a\nb\n"), ["a", "b"])
        XCTAssertEqual(LineDiff.between("a\n", "a").rows, [.same(old: 1, new: 1, text: "a")])
    }

    /// Whatever the texts, the matching lines come out in order, the same
    /// text on both sides, and the kept lines are the most any order can
    /// keep: the script is the shortest edit there is.
    func testTheScriptIsTheShortestAndWellFormed() {
        let alphabet = ["a", "b", "c"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let a = (0..<Int.random(in: 0...6, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            let b = (0..<Int.random(in: 0...6, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            let pairs = LineDiff.matches(a, b)
            XCTAssertEqual(pairs.count, lcs(a, b).count, "\(a) vs \(b)")
            var previous = (-1, -1)
            for (x, y) in pairs {
                XCTAssertGreaterThan(x, previous.0)
                XCTAssertGreaterThan(y, previous.1)
                XCTAssertEqual(a[x], b[y])
                previous = (x, y)
            }
        }
    }

    /// The rows keep every line of both texts, once each.
    private func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
