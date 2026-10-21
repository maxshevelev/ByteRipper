import AppKit
import BytePattern

/// One thing to look for: the bytes, how their letters compare, and the
/// encoding the field was read in to get them.
public struct ToolPatternAttempt: Equatable, Sendable {
    public var pattern: MaskedPattern
    /// The encoding's code — what `ToolPatternQuery.found(encoding:)` is told
    /// back when this attempt is the one that finds something.
    public var encoding: String
    /// What to call the encoding to the reader: "ASCII", "UTF-16 LE",
    /// "Hex bytes".
    public var encodingName: String

    public init(pattern: MaskedPattern, encoding: String, encodingName: String) {
        self.pattern = pattern
        self.encoding = encoding
        self.encodingName = encodingName
    }
}

/// The app's controls for what to look for, handed to a tool-module that
/// searches bytes (`ToolHost.makePatternQuery()`): the same field, menu,
/// encoding, Smart Search and case toggle the dump's Find bar has, with the
/// same recent queries and the same pattern library.
///
/// The module lays `view` out where its own search goes, runs the search
/// itself, and tells the controls how it went: the history keeps only
/// searches that found something, and with Smart Search on the encoding the
/// field shows is the one that did.
@MainActor public protocol ToolPatternQuery: AnyObject {
    /// The controls, in one row: the field, the encoding, Smart Search, the
    /// case toggle. The field grows; the rest keep their width.
    var view: NSView { get }

    /// Return in the field, or a row of its menu picked: the module searches.
    var onSubmit: (() -> Void)? { get set }
    /// The field was edited: a result shown for the last pattern no longer
    /// describes what is in it.
    var onEdited: (() -> Void)? { get set }
    /// What is wrong with the field, as a short verdict and the sentence
    /// behind it — or nil, nothing is. The module shows it where it reports
    /// how a search went.
    var onProblem: ((_ label: String?, _ detail: String?) -> Void)? { get set }

    /// The text in the field.
    var text: String { get set }

    /// What the field asks for, in the order to look: one attempt for the
    /// encoding chosen, or Smart Search's, one encoding after another — the
    /// first that finds anything is the answer. Nil when it asks for nothing,
    /// said through `onProblem`.
    func attempts() -> [ToolPatternAttempt]?

    /// The attempt in `encoding` found something: the search is written into
    /// the recent queries, and the encoding shown.
    func found(encoding: String)

    /// The field takes the keyboard, its text selected.
    func focus()

    /// Takes the find pasteboard's string into the field when it is new to
    /// the field (`FindPasteboard`) — or, with `intoEmptyField`, whenever the
    /// field is empty: what a Find Next asks for, where a field merely opened
    /// keeps the emptiness it was left with. Returns whether the field
    /// changed; a change is reported through `onEdited`.
    @discardableResult
    func adoptFindPasteboard(intoEmptyField: Bool) -> Bool

    /// The panel's type size moved.
    func applyFont(_ font: NSFont)
}
