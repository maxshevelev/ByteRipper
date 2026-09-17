import Foundation

/// What a selection becomes when it is used as a find pattern — the text the
/// Find bar's field holds and the encoding its popup names (§11, Use Selection
/// for Find).
///
/// The pair travels together because either half alone is a lie: `41 42` under
/// UTF-8 searches for the four characters `4`, `1`, `4`, `2`, and `AB` under
/// hex does not parse at all.
public struct SelectionFindPattern: Equatable, Sendable {
    public let text: String
    public let encoding: SearchEncoding

    public init(text: String, encoding: SearchEncoding) {
        self.text = text
        self.encoding = encoding
    }

    /// A selection made in the **hex** column: the bytes, written the way a
    /// dump writes them (`DE AD BE EF`) and searched as bytes.
    ///
    /// The same form `SearchPattern.hexText` shows back after a search, so a
    /// pattern taken from the dump and one typed into the field are the same
    /// text — and the history, which records what the field holds, keeps one
    /// form rather than two.
    public static func forBytes(_ bytes: [UInt8]) -> SelectionFindPattern {
        SelectionFindPattern(text: SearchPattern(bytes: bytes, encoding: .hex).hexText,
                             encoding: .hex)
    }

    /// A selection made in the **decoded-text** column: the bytes read as
    /// UTF-8 where that is what they are, and the bytes themselves where it is
    /// not.
    ///
    /// The fallback is the whole point of the rule. A pattern is a thing to
    /// search *with*, so it has to say what was selected: bytes that do not
    /// decode — a selection starting mid-character, a run of `FF` fill, a
    /// stretch of code — would become replacement characters, and a search for
    /// those finds nothing that is in the file. Bytes always find themselves,
    /// so that is what they become, and the caller can see the fallback
    /// happened by the encoding it gets back.
    ///
    /// The column is drawn through a single-byte decoder, which is not UTF-8:
    /// over ASCII the two agree, and a high byte the code page draws as a
    /// letter is not UTF-8 by itself, so it comes back as its byte. That is the
    /// honest reading — a search for the *character* would have to guess which
    /// of the encodings the file uses, and the bar's own Smart Search is where
    /// that guess belongs.
    public static func forText(_ bytes: [UInt8]) -> SelectionFindPattern {
        guard let text = readableUTF8(bytes) else { return forBytes(bytes) }
        return SelectionFindPattern(text: text, encoding: .utf8)
    }

    /// `bytes` as UTF-8 text a reader can see and retype, or nil when they are
    /// not that.
    ///
    /// Strict on both counts: the whole selection must decode (a partial
    /// decode would silently shorten the pattern), and every scalar must be
    /// printable. Controls are excluded because a pattern carrying them cannot
    /// be read back off the field, corrected or kept — `NUL` is invisible and a
    /// newline does not survive a single-line field at all — so bytes like
    /// those are better searched for as bytes.
    public static func readableUTF8(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty, let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        guard text.unicodeScalars.allSatisfy(isPrintable) else { return nil }
        return text
    }

    /// Whether a scalar is one the field can show: not a C0 control, not
    /// `DEL`, not a C1 control. Everything else — letters, digits, punctuation,
    /// spaces, and the whole of Unicode above them — is text.
    private static func isPrintable(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F, 0x80...0x9F:
            return false
        default:
            return true
        }
    }
}
