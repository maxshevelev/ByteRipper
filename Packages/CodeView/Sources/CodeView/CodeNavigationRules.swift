import CodeAnalysis
import Foundation

/// Back and Forward over the places the reader moved through, apart from how
/// a place is shown: a move keeps the place left, drops what was ahead of it
/// and makes the new place current; Back and Forward walk the list.
struct CodeNavigationHistory<Place> {
    private(set) var places: [Place] = []
    /// The current place in `places`; -1 while there is none.
    private(set) var index = -1

    var current: Place? { places.indices.contains(index) ? places[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < places.count }

    /// The current place as the reader has it now, before they leave it.
    mutating func update(_ place: Place) {
        guard places.indices.contains(index) else { return }
        places[index] = place
    }

    /// A move to `place`; nothing when `same` says it is where the reader is.
    @discardableResult
    mutating func move(to place: Place, unless same: (Place, Place) -> Bool = { _, _ in false }) -> Bool {
        if let current, same(current, place) { return false }
        places = Array(places.prefix(index + 1)) + [place]
        index = places.count - 1
        return true
    }

    /// The place before the current one, now current; nil at the first.
    mutating func back() -> Place? {
        guard canGoBack else { return nil }
        index -= 1
        return places[index]
    }

    /// The place after the current one, now current; nil at the last.
    mutating func forward() -> Place? {
        guard canGoForward else { return nil }
        index += 1
        return places[index]
    }

    /// A history of these places, `index` the current one.
    init(places: [Place] = [], index: Int? = nil) {
        self.places = places
        self.index = index ?? places.count - 1
    }
}

/// What a token of the code names, and the highlighted name's occurrences.
enum CodeSymbolMatch {
    /// The symbol a token is an occurrence of, over the text's UTF-16 units;
    /// nil for one that is not a name: a keyword, a type, a constant, an
    /// address. A caller that asks for many tokens makes the units once: a
    /// copy of the whole text per token made a click in a long function's C
    /// cost seconds.
    static func symbol(of token: CodeToken, in units: [UTF16.CodeUnit]) -> CodeSymbol? {
        func name() -> String {
            guard token.start >= 0, token.start + token.length <= units.count else { return "" }
            return String(decoding: units[token.start..<token.start + token.length], as: UTF16.self)
        }
        switch token.kind {
        case .label:
            // By name: a `goto` links to its label and the definition links
            // nowhere, and a click on either highlights both.
            return .named(.label, name())
        case .function, .global, .pcode:
            if let link = token.link { return .target(link) }
            return .named(token.kind, name())
        case .parameter, .local:
            return .variable(name())
        default:
            return nil
        }
    }

    /// The ranges of the tokens that name `symbol`.
    static func ranges(of symbol: CodeSymbol, in tokens: [CodeToken], of text: String) -> [NSRange] {
        let units = Array(text.utf16)
        return tokens.filter { self.symbol(of: $0, in: units) == symbol }
            .map { NSRange(location: $0.start, length: $0.length) }
    }

    /// The occurrence a step goes to, of `count`, and whether it went round.
    /// From the current one it moves by one; with none current it starts
    /// from the reader's place: `positions` are where each occurrence stands
    /// in reading order and `anchor` where the reader is.
    static func step(forward: Bool, current: Int?, positions: [Int], anchor: Int)
        -> (index: Int, wrapped: Bool)? {
        let count = positions.count
        guard count > 0 else { return nil }
        var target: Int
        if let current, positions.indices.contains(current) {
            target = current + (forward ? 1 : -1)
        } else {
            target = forward ? (positions.firstIndex { $0 > anchor } ?? count)
                             : (positions.lastIndex { $0 < anchor } ?? -1)
        }
        if target >= count { return (0, true) }
        if target < 0 { return (count - 1, true) }
        return (target, false)
    }
}
