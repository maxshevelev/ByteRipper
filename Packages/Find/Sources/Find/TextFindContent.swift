import Foundation

/// What a search of a text looks for: the string, whether letters compare by
/// case, and whether a match has to be a whole word.
public struct TextQuery: Equatable, Sendable {
    public let text: String
    public let caseSensitive: Bool
    /// A match that starts or ends with a word character must not run on into
    /// another one: `Status` does not find the middle of `EfiStatus`.
    public let wholeWord: Bool

    public init(text: String, caseSensitive: Bool = false, wholeWord: Bool = false) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }
}

/// A text as something `FindIndexer` searches: the C of a function, a module
/// description.
///
/// Positions are UTF-16 units — the offsets `NSString` and a text view count
/// in — so a match range is a selection range as it stands. Letters compare
/// unit by unit (with case folded or not), never by Unicode equivalence, so
/// every match is exactly as long as the query: what an index of starts needs.
public struct TextFindContent: FindContent {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public var extent: UInt64 { UInt64((text as NSString).length) }

    public func matchLength(of query: TextQuery) -> Int { max((query.text as NSString).length, 1) }

    public func firstMatch(of query: TextQuery, from anchor: UInt64, direction: SearchDirection,
                           shouldCancel: () -> Bool,
                           progress: (Double) -> Void) throws -> Range<UInt64>? {
        let scanner = Scanner(text: text, query: query)
        guard scanner.isSearchable else { return nil }
        let anchor = Int(min(anchor, UInt64(scanner.length)))
        var found: Range<UInt64>?
        switch direction {
        case .forward:
            var from = anchor
            while let range = scanner.next(from: from) {
                if shouldCancel() { throw CancellationError() }
                if scanner.isWhole(range) { found = scanner.offsets(range); break }
                from = range.location + 1
            }
        case .backward:
            // The last match ending at or before the anchor.
            var upTo = anchor
            while let range = scanner.previous(upTo: upTo) {
                if shouldCancel() { throw CancellationError() }
                if scanner.isWhole(range) { found = scanner.offsets(range); break }
                upTo = range.location + range.length - 1
            }
        }
        progress(1)
        return found
    }

    public func matchStarts(of query: TextQuery,
                            shouldCancel: @escaping @Sendable () -> Bool,
                            progress: @escaping @Sendable (Double) -> Void)
        -> AsyncThrowingStream<MatchBatch, any Error> {
        let text = text
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let scanner = Scanner(text: text, query: query)
                let length = scanner.length
                guard scanner.isSearchable else {
                    continuation.yield(MatchBatch(starts: [], scannedUpTo: UInt64(length)))
                    continuation.finish()
                    return
                }
                // A batch per stretch, so a long text shows what is covered
                // while the rest is scanned.
                let stretch = 1 << 16
                var starts: [UInt64] = []
                var from = 0
                var reported = 0
                while let range = scanner.next(from: from) {
                    if shouldCancel() || Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    if range.location - reported >= stretch {
                        continuation.yield(MatchBatch(starts: starts, scannedUpTo: UInt64(range.location)))
                        progress(Double(range.location) / Double(max(length, 1)))
                        starts = []
                        reported = range.location
                    }
                    // Matches do not overlap, as in a dump's search (§11): the
                    // scan resumes past each one it counts.
                    if scanner.isWhole(range) {
                        starts.append(UInt64(range.location))
                        from = range.location + range.length
                    } else {
                        from = range.location + 1
                    }
                }
                continuation.yield(MatchBatch(starts: starts, scannedUpTo: UInt64(length)))
                progress(1)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A text's search, held by whatever shows the text.
public typealias TextFindIndexer = FindIndexer<TextFindContent>
/// Where every occurrence of a text's search is.
public typealias TextMatchSet = MatchSet<TextQuery>

/// One query over one text, in `NSString`'s terms.
private struct Scanner {
    let string: NSString
    let pattern: String
    let patternLength: Int
    let options: NSString.CompareOptions
    let wholeWord: Bool

    init(text: String, query: TextQuery) {
        string = text as NSString
        pattern = query.text
        patternLength = (query.text as NSString).length
        options = query.caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        wholeWord = query.wholeWord
    }

    var length: Int { string.length }
    var isSearchable: Bool { patternLength > 0 && patternLength <= length }

    /// The first match starting at or after `from`.
    func next(from: Int) -> NSRange? {
        guard from <= length - patternLength else { return nil }
        let found = string.range(of: pattern, options: options,
                                 range: NSRange(location: from, length: length - from))
        return found.location == NSNotFound ? nil : found
    }

    /// The last match ending at or before `upTo`.
    func previous(upTo: Int) -> NSRange? {
        guard upTo >= patternLength else { return nil }
        let found = string.range(of: pattern, options: options.union(.backwards),
                                 range: NSRange(location: 0, length: upTo))
        return found.location == NSNotFound ? nil : found
    }

    /// Whether `range` stands on its own as a word, when that is asked for.
    /// An edge of the pattern that is not a word character needs no boundary:
    /// `->Size` is found after any name.
    func isWhole(_ range: NSRange) -> Bool {
        guard wholeWord else { return true }
        let first = string.character(at: range.location)
        let last = string.character(at: range.location + range.length - 1)
        if Self.isWordUnit(first), range.location > 0,
           Self.isWordUnit(string.character(at: range.location - 1)) { return false }
        let end = range.location + range.length
        if Self.isWordUnit(last), end < length, Self.isWordUnit(string.character(at: end)) {
            return false
        }
        return true
    }

    func offsets(_ range: NSRange) -> Range<UInt64> {
        UInt64(range.location)..<UInt64(range.location + range.length)
    }

    /// A letter, a digit or `_`: what a C name is made of.
    static func isWordUnit(_ unit: unichar) -> Bool {
        if unit == 0x5F { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
