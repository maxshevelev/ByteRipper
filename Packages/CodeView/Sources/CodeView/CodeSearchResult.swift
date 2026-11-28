import Find
import Foundation
import Localization

/// The words of the Search tab apart from their drawing: the line over the
/// tree, and an occurrence's line brought forward to its match.
enum CodeSearchResult {
    /// The line over the tree for these counts. One result, or one function,
    /// is said in the singular: each count has a key of its own for one.
    static func summary(hits: Int, functions: Int, inDescription: Bool, truncated: Bool) -> String {
        let count = String(hits), names = String(functions)
        if hits == 0 { return L("No results") }
        if truncated {
            return functions == 1
                ? L("The first %1$@ results in 1 function — refine the pattern", count)
                : L("The first %1$@ results in %2$@ functions — refine the pattern", count, names)
        }
        switch (functions, inDescription) {
        case (0, _):
            return hits == 1 ? L("1 result in the description") : L("%1$@ results in the description", count)
        case (1, true): return L("%1$@ results in 1 function and the description", count)
        case (_, true): return L("%1$@ results in %2$@ functions and the description", count, names)
        case (1, false):
            return hits == 1 ? L("1 result in 1 function") : L("%1$@ results in 1 function", count)
        default: return L("%1$@ results in %2$@ functions", count, names)
        }
    }

    /// How much of a line before the match stays when the match stands far
    /// into it: the rest gives way to an ellipsis, so the match is in the
    /// three lines shown.
    static let leadingContext = 32

    /// The occurrence's line as the tab shows it, and where the match is in
    /// it (UTF-16 units). A tab reads as a space; a match far into a long
    /// line is brought forward, the start cut to "…" at a word's start.
    static func shownLine(of hit: TextSearchHit) -> (text: String, match: Range<Int>) {
        // A tab — after a list's bullet in the description — reads as a
        // space here; one unit for one, so the match's range holds.
        var shown = hit.lineText.replacingOccurrences(of: "\t", with: " ") as NSString
        var start = min(hit.rangeInLine.lowerBound, shown.length)
        var end = min(hit.rangeInLine.upperBound, shown.length)
        if start > leadingContext + 8 {
            var cut = start - leadingContext
            // From a word's start, not its middle.
            let separators = CharacterSet.whitespaces.union(.punctuationCharacters)
            while cut < start, let scalar = Unicode.Scalar(shown.character(at: cut - 1)),
                  !separators.contains(scalar) { cut += 1 }
            let rest = shown.substring(from: cut)
            shown = ("…" + rest) as NSString
            let removed = cut - 1
            start -= removed
            end -= removed
        }
        return (shown as String, start..<max(start, end))
    }
}
