import Foundation

/// A sum typed where an offset or a length is asked for: `0x1FE000 + 4096`,
/// `196608 - 0x200` (issue #9).
///
/// The numbers of this work arrive as arithmetic — a region's start plus a
/// structure's distance into it, a component's length minus its header — and a
/// sum done in another program and typed back is where a wrong digit gets in.
///
/// The grammar is as small as it can be and still cover that:
/// - terms joined by `+` and `-`, taken left to right;
/// - each term read exactly as `OffsetParser` reads a field that holds one
///   number, so the bases mix freely and there is one rule to know, not two;
/// - whitespace anywhere between a term and an operator;
/// - no brackets, no multiplication, no precedence to get wrong, and no sign in
///   front of the first term — a leading `+` or `-` is refused rather than
///   guessed at, which keeps it free to mean "from here" one day.
///
/// A single number is an expression of one term, so a field hands everything
/// it holds to `parse` and need not know which it was given.
///
/// The sum may dip below zero on the way (`0x100 - 0x200 + 0x200`); only what
/// it comes to has to be an offset — neither negative nor past 64 bits.
public struct OffsetExpression: Equatable, Sendable {
    public enum ParseError: Error, Equatable, Sendable {
        /// Not a sum of numbers: a stray character, an operator with nothing
        /// before it, two operators in a row — or a term too large to be a
        /// number at all, which is as much a typo as a stray character.
        case invalidInput
        /// A sum still being typed: it ends at an operator, or at a term that is
        /// so far only its `0x`. Told apart from `invalidInput` so a field
        /// can wait for the rest instead of calling it an error.
        case incomplete
        /// The sum comes to less than zero.
        case negative
        /// The sum does not fit in 64 bits, though every term does.
        case outOfRange
    }

    public struct Term: Equatable, Sendable {
        /// True for a term the sum takes away.
        public let isSubtracted: Bool
        public let value: UInt64

        public init(isSubtracted: Bool, value: UInt64) {
            self.isSubtracted = isSubtracted
            self.value = value
        }
    }

    /// The terms in the order they were typed. Never empty; the first is never
    /// subtracted.
    public let terms: [Term]
    /// What the sum comes to.
    public let value: UInt64

    /// True when there is an operator: a lone number has nothing to work out.
    public var isSum: Bool { terms.count > 1 }

    /// The sum with every term in hex, as it was read: `0x1FE000 + 0x28` for
    /// `0x1FE000 + 40`. Shown beside the result, it is how a `40` that was
    /// meant as `0x40` is seen before the result is used.
    public var hexText: String {
        var text = Self.hex(terms[0].value)
        for term in terms.dropFirst() {
            text += term.isSubtracted ? " - " : " + "
            text += Self.hex(term.value)
        }
        return text
    }

    /// The result in the form the fields write an address in: `0x1FE028`.
    public var hexValue: String { Self.hex(value) }

    /// `0x` and uppercase digits — the form every address field is filled in.
    public static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    public static func parse(_ text: String) throws -> OffsetExpression {
        var terms: [Term] = []
        var subtracting = false
        var current = ""

        func closeTerm(last: Bool) throws {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            do {
                terms.append(Term(isSubtracted: subtracting, value: try OffsetParser.parse(piece)))
            } catch OffsetParser.ParseError.outOfRange {
                // A term too large is a mistake in that term, not a result
                // that overflowed: the field's own "invalid" names it.
                throw ParseError.invalidInput
            } catch {
                // The last term may simply not be finished: nothing after the
                // operator yet, or a prefix waiting for its digits.
                // Only after an operator, though: a field holding nothing but
                // its `0x` is not a sum being typed, it is not an offset.
                let unfinished = !terms.isEmpty && (piece.isEmpty || piece.lowercased() == "0x")
                throw last && unfinished ? ParseError.incomplete : ParseError.invalidInput
            }
        }

        for character in text {
            if character == "+" || character == "-" {
                try closeTerm(last: false)
                subtracting = character == "-"
            } else {
                current.append(character)
            }
        }
        try closeTerm(last: true)

        // Added and taken away are summed apart, each in 128 bits, so neither
        // the order of the terms nor a dip below zero on the way matters —
        // only what the whole comes to.
        var added = Wide()
        var taken = Wide()
        for term in terms {
            if term.isSubtracted { taken.add(term.value) } else { added.add(term.value) }
        }
        guard !(added < taken) else { throw ParseError.negative }
        let difference = added.subtracting(taken)
        guard difference.high == 0 else { throw ParseError.outOfRange }
        return OffsetExpression(terms: terms, value: difference.low)
    }

    private init(terms: [Term], value: UInt64) {
        self.terms = terms
        self.value = value
    }

    /// An unsigned 128-bit sum: enough for any number of 64-bit terms a field
    /// can hold, and available on macOS 14 where `UInt128` is not.
    private struct Wide {
        var high: UInt64 = 0
        var low: UInt64 = 0

        mutating func add(_ value: UInt64) {
            let (sum, carried) = low.addingReportingOverflow(value)
            low = sum
            if carried { high += 1 }
        }

        static func < (lhs: Wide, rhs: Wide) -> Bool {
            lhs.high != rhs.high ? lhs.high < rhs.high : lhs.low < rhs.low
        }

        /// `self - other`, for `other` no greater than `self`.
        func subtracting(_ other: Wide) -> Wide {
            let (difference, borrowed) = low.subtractingReportingOverflow(other.low)
            return Wide(high: high - other.high - (borrowed ? 1 : 0), low: difference)
        }
    }
}
