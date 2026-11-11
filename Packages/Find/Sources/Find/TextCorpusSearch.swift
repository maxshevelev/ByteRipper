import Foundation

/// One occurrence of a search in one text, with the line it stands on — what
/// a results list shows under the text's name.
public struct TextSearchHit: Equatable, Sendable {
    /// Where the match is in the text, in UTF-16 units.
    public let range: Range<UInt64>
    /// The line the match starts on, counted from 0.
    public let line: Int
    /// That line, without its indentation.
    public let lineText: String
    /// Where the match is in `lineText`, in UTF-16 units; it may run past
    /// the end of the line when the match itself spans lines.
    public let rangeInLine: Range<Int>

    public init(range: Range<UInt64>, line: Int, lineText: String, rangeInLine: Range<Int>) {
        self.range = range
        self.line = line
        self.lineText = lineText
        self.rangeInLine = rangeInLine
    }
}

/// The occurrences of a search in one text of a corpus.
public struct TextSearchGroup<ID: Hashable & Sendable>: Equatable, Sendable {
    public let id: ID
    public let hits: [TextSearchHit]

    public init(id: ID, hits: [TextSearchHit]) {
        self.id = id
        self.hits = hits
    }
}

/// What a search of a corpus found: the texts with matches, in the corpus's
/// order, and whether it stopped at the limit.
public struct TextCorpusResult<ID: Hashable & Sendable>: Equatable, Sendable {
    public let groups: [TextSearchGroup<ID>]
    /// True when the limit was reached: there are more matches than listed.
    public let isTruncated: Bool

    public var hitCount: Int { groups.reduce(0) { $0 + $1.hits.count } }

    public init(groups: [TextSearchGroup<ID>], isTruncated: Bool) {
        self.groups = groups
        self.isTruncated = isTruncated
    }
}

/// One query over many texts — the C of every function of a module (#41).
/// Matches are a text's own search's: the same case and whole-word rules,
/// never overlapping.
public enum TextCorpusSearch {
    /// How many matches a search lists before it stops: past this a pattern
    /// is too general to read through, and the count says so.
    public static let defaultLimit = 5000

    public static func search<ID: Hashable & Sendable>(
        _ query: TextQuery, in texts: [(id: ID, text: String)],
        limit: Int = defaultLimit, shouldCancel: () -> Bool = { false }
    ) throws -> TextCorpusResult<ID> {
        var groups: [TextSearchGroup<ID>] = []
        var total = 0
        for (id, text) in texts {
            if shouldCancel() { throw CancellationError() }
            let ranges = TextFindContent(text: text).allMatches(of: query)
            guard !ranges.isEmpty else { continue }
            if total >= limit { return TextCorpusResult(groups: groups, isTruncated: true) }
            let kept = Array(ranges.prefix(limit - total))
            groups.append(TextSearchGroup(id: id, hits: hits(kept, in: text)))
            total += kept.count
            if kept.count < ranges.count { return TextCorpusResult(groups: groups, isTruncated: true) }
        }
        return TextCorpusResult(groups: groups, isTruncated: false)
    }

    /// The lines `ranges` stand on, read in one pass over the text.
    static func hits(_ ranges: [Range<UInt64>], in text: String) -> [TextSearchHit] {
        let string = text as NSString
        var hits: [TextSearchHit] = []
        var line = 0
        var lineStart = 0
        var scanned = 0
        for range in ranges {
            let start = Int(range.lowerBound)
            // Count the line breaks between the last match and this one.
            while scanned < start {
                if string.character(at: scanned) == 0x0A {
                    line += 1
                    lineStart = scanned + 1
                }
                scanned += 1
            }
            var lineEnd = start
            while lineEnd < string.length, string.character(at: lineEnd) != 0x0A { lineEnd += 1 }
            var shown = lineStart
            while shown < start, let scalar = Unicode.Scalar(string.character(at: shown)),
                  CharacterSet.whitespaces.contains(scalar) { shown += 1 }
            let lineText = string.substring(with: NSRange(location: shown, length: lineEnd - shown))
            let length = Int(range.upperBound - range.lowerBound)
            hits.append(TextSearchHit(range: range, line: line, lineText: lineText,
                                      rangeInLine: (start - shown)..<(start - shown + length)))
        }
        return hits
    }
}

extension TextFindContent {
    /// Every match of `query`, at once: for a text small enough to scan in
    /// one go, as a function's C is.
    public func allMatches(of query: TextQuery) -> [Range<UInt64>] {
        let scanner = Scanner(text: text, query: query)
        guard scanner.isSearchable else { return [] }
        var found: [Range<UInt64>] = []
        var from = 0
        while let range = scanner.next(from: from) {
            if scanner.isWhole(range) {
                found.append(scanner.offsets(range))
                from = range.location + range.length
            } else {
                from = range.location + 1
            }
        }
        return found
    }
}
