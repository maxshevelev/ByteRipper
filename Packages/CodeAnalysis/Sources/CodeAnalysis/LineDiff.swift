import Foundation

/// A line-by-line diff of two texts as an editor shows it: the lines both
/// texts share, the ones only the old text has and the ones only the new one
/// has, in the order a reader follows them. A change reads the way GitHub
/// shows one — the removed lines first, then the added ones.
///
/// The algorithm is Myers': the shortest edit script, found in O(ND) over the
/// lines, so a function of a few thousand lines costs no table of their
/// product. It is a type of this package because the panel and any other
/// reader of artifacts diff the same way, and a test can tell them apart
/// without a window.
public struct LineDiff: Equatable, Sendable {
    /// One line of the diff. The numbers are 1-based, as an editor numbers
    /// them; a removed line has no number in the new text and the other way
    /// round.
    public enum Row: Equatable, Sendable {
        case same(old: Int, new: Int, text: String)
        case removed(old: Int, text: String)
        case added(new: Int, text: String)
    }

    public let rows: [Row]
    /// How many lines the new text adds and the old one loses.
    public let added: Int
    public let removed: Int

    public init(rows: [Row], added: Int, removed: Int) {
        self.rows = rows
        self.added = added
        self.removed = removed
    }

    /// The diff from `old` to `new`, line by line.
    public static func between(_ old: String, _ new: String) -> LineDiff {
        let a = lines(old), b = lines(new)
        var rows: [Row] = []
        var added = 0, removed = 0
        var i = 0, j = 0
        for (x, y) in matches(a, b) {
            while i < x {
                rows.append(.removed(old: i + 1, text: a[i]))
                removed += 1
                i += 1
            }
            while j < y {
                rows.append(.added(new: j + 1, text: b[j]))
                added += 1
                j += 1
            }
            rows.append(.same(old: x + 1, new: y + 1, text: a[x]))
            i = x + 1
            j = y + 1
        }
        while i < a.count {
            rows.append(.removed(old: i + 1, text: a[i]))
            removed += 1
            i += 1
        }
        while j < b.count {
            rows.append(.added(new: j + 1, text: b[j]))
            added += 1
            j += 1
        }
        return LineDiff(rows: rows, added: added, removed: removed)
    }

    /// The text's lines. A closing newline ends the last line rather than
    /// starting an empty one — the way a file's line count is read.
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if text.hasSuffix("\n") || text.hasSuffix("\r\n") { result.removeLast() }
        return result
    }

    /// The pairs of lines, in order, the two texts share: Myers' shortest
    /// edit script, kept only along its diagonals.
    static func matches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        let max = n + m
        var v = [Int](repeating: 0, count: 2 * max + 1)
        var trace: [[Int]] = []
        var d = 0
        var done = false
        while !done, d <= max {
            trace.append(v)
            var k = -d
            while k <= d {
                let index = k + max
                var x: Int
                if k == -d || (k != d && v[index - 1] < v[index + 1]) {
                    x = v[index + 1]
                } else {
                    x = v[index - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[index] = x
                if x >= n, y >= m {
                    done = true
                    break
                }
                k += 2
            }
            d += 1
        }

        // Backtrack from the end over the states kept before each round: the
        // diagonals walked are the matching lines, collected backwards.
        var pairs: [(Int, Int)] = []
        var x = n, y = m
        var depth = trace.count - 1
        while depth > 0 {
            let state = trace[depth]
            let k = x - y
            let index = k + max
            let previousK: Int
            if k == -depth || (k != depth && state[index - 1] < state[index + 1]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = state[previousK + max]
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                x -= 1
                y -= 1
                pairs.append((x, y))
            }
            x = previousX
            y = previousY
            depth -= 1
        }
        while x > 0, y > 0 {
            x -= 1
            y -= 1
            pairs.append((x, y))
        }
        return pairs.reversed()
    }
}
