import Foundation

/// How a scan compares letters (§11).
///
/// Folding is what makes a case-insensitive search possible without a second
/// pass over the file: fold both the pattern and the data and the fast
/// `Data.range(of:)` search does the rest. What may be folded depends on the
/// encoding, which is why this is a type rather than a `Bool`.
public enum CaseFolding: Sendable, Equatable {
    /// Byte-exact: no letter is folded. Hex is always this, and so is any
    /// encoding when the user asks for a case-sensitive search.
    case exact
    /// Fold ASCII letter *bytes*, wherever they sit — exact for a single-byte
    /// ASCII-compatible encoding (ASCII, UTF-8).
    case asciiBytes
    /// Compare UTF-16 *code units*, folding one only when it encodes an ASCII
    /// letter — that is, when its other byte is zero. A byte-wise fold cannot do
    /// this: it would fold the high byte of `U+6100` (`00 61` LE) as if it were
    /// the letter `a` and match `U+4100`, a different character (§11).
    ///
    /// Units are counted from each candidate's own start, so a string is found
    /// wherever it sits in the file. That rules out folding a whole window ahead
    /// of the search — see `firstMatch` — which costs speed and buys the truth:
    /// ~230 ms over a 16 MB dump against 3 ms for an exact scan.
    case utf16(littleEndian: Bool)
}

public enum SearchError: Error, Equatable, Sendable {
    /// The pattern resolved to zero bytes (e.g. empty input or an empty hex).
    case emptyPattern
    /// Hex input was malformed: non-hex characters or an odd number of digits.
    case invalidHexPattern
    /// The text could not be encoded in the requested encoding.
    case undecodableText
}
