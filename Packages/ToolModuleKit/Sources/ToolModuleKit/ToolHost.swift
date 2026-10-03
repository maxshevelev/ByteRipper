import Foundation
import PartCodec

/// The open file, as the tool-module bound to it is allowed to see it: read it,
/// write it, say what the dump should draw and what just happened, and send the
/// view somewhere.
///
/// One host stands for one pane. A session gets it at birth and holds it until
/// `stop()`; everything it can ask for is here, which is also the list of what
/// a tool-module can do to this app at all.
///
/// Two things this deliberately does not carry. There is no way to reach the
/// other pane — a tool-module works on the file it was opened for. And there is
/// no rule about the file's size: whether an operation may move the bytes after
/// it is the tool-module's own business (for a flash dump the answer is usually
/// no, and `Design/UEFI/FIT_TABLE_FORMAT.md` §9.2 says why), and the app's
/// standing rule — overwrite by default, warn on a shift — covers what reaches
/// the document.
@MainActor public protocol ToolHost: AnyObject {
    /// What the panel's header calls the file it is working on.
    var fileName: String { get }
    /// The content's size *now*, unsaved edits included.
    var contentSize: UInt64 { get }
    /// A read-only file refuses `apply`; a tool-module can ask beforehand and
    /// show its own controls as disabled rather than let them fail.
    var isReadOnly: Bool { get }

    /// Where the caret is in the bound pane.
    var caret: UInt64 { get }
    /// What the user has selected there, or nil for a bare caret. A
    /// tool-module reads it to act on what the user is pointing at — "make a
    /// zone of this", "what is this?" — rather than asking them to type an
    /// offset they can already see.
    var selection: Range<UInt64>? { get }

    /// A small read on the main actor: a header, a table, the 48 bytes that
    /// answer "is there really a microcode at this address".
    func read(_ range: Range<UInt64>) throws -> [UInt8]

    /// An immutable view of the whole content, readable from any thread — what
    /// a parse of a 16 MiB image runs over.
    ///
    /// It costs nothing to take (the app already does this for Duplicate) and
    /// it cannot drift: the bytes it answers with are the bytes at the moment
    /// it was taken, whatever the document does afterwards. So a parse never
    /// has to hold the main actor, and never has to worry that an edit landed
    /// halfway through it — the edit arrives as `ToolContentChange` and the
    /// tool-module decides what to do about it.
    func snapshot() throws -> any ToolContentReader

    /// Writes the transaction as one undo step named by it. Throws if the file
    /// is read-only, if the transaction does not validate, or if it reaches
    /// outside the file.
    func apply(_ transaction: ToolTransaction) throws

    /// What the dump draws. Replaces the whole previous map; `.empty` clears it.
    func publish(_ zones: ZoneMap)

    /// Scrolls the dump to `range` — and selects it, when the point is what the
    /// bytes are rather than where they are.
    func reveal(_ range: Range<UInt64>, select: Bool)

    /// Shows a short-lived notice over the window — the plate a search result
    /// is reported in — about something the panel *did* rather than something
    /// it found in the bytes: a copy that went to the clipboard, a write that
    /// landed.
    ///
    /// The panel names the glyph and writes the lines, because the panel is
    /// what knows what happened; where the plate appears, how long it holds,
    /// and that a new one replaces the one before are the window's
    /// conventions, so they are asked for here rather than re-decided by every
    /// tool-module that has something to confirm. Which is the whole reason
    /// this is on the seam: a panel drawing its own plate would be a second
    /// convention, and the user would see two.
    ///
    /// For a report that is nothing but a sign, `lines` is empty.
    func showNotice(symbol: String, lines: [String])

    /// Asks the user for a file and hands back its bytes. The panel is the
    /// app's because choosing a file is the app's chrome, like the notice
    /// above: one panel, one size cap, one wording of a file that cannot be
    /// read, rather than one per tool-module. A tool-module gets bytes and is
    /// never handed a URL to open, hold or write back to.
    /// Nil when the user cancels or the file cannot be read.
    func requestFile(kinds: [String]) async -> ToolFile?

    /// Puts a modal sheet over the pane's window for an operation that changes
    /// the file, and returns the handle to move it along with: the title says
    /// what is being done, `rename` what it is doing now, `finish` closes it.
    ///
    /// For work that has to run to its end with the window left alone — it
    /// reads the file, takes seconds, and writes back into it — so that nothing
    /// can be typed into the dump meanwhile and no second change lands under
    /// the first. `onCancel` is called when the user presses Cancel; the
    /// tool-module stops its work and calls `finish`.
    func beginBlockingWork(title: String, onCancel: @escaping () -> Void) -> any ToolWork

    /// Tells the user how an operation ended, in a modal sheet over the pane's
    /// window — the same place its progress was. A problem is worded as one.
    /// What an operation says about itself belongs here, not in a line of the
    /// panel: the panel is a strip beside the dump, and a result nobody was
    /// waiting at goes unread.
    func report(title: String, message: String, isProblem: Bool)

    /// Offers bytes to the user as a file to save. False when they cancel or
    /// the write fails.
    func exportFile(_ bytes: [UInt8], suggestedName: String) async -> Bool

    /// Opens a part of this file as a panel over it, linked to `source`
    /// (`Design/FRAGMENT_PANELS_PLAN.md`, `Design/UEFI/UPDATE_IN_PARENT.md`).
    ///
    /// `codec` is the whole of what the part is: what the panel shows is what
    /// it decodes from `source`, and what Update in Parent writes back is what
    /// it encodes from the panel. A copy, a body decompressed, a block
    /// decrypted — each is a codec, and the host opens and puts back all of
    /// them the same way.
    ///
    /// The app opens parts of its own accord too — a zone, a selection — and
    /// this is the same opening: the tool-module only supplies the codec.
    ///
    /// Where it opens is the app's business, not the tool-module's — which is
    /// why this is named after what it opens rather than after where.
    func openPart(named name: String, linkedTo source: Range<UInt64>, codec: any PartCodec)

    /// The reader is about to choose something else in the panel on purpose —
    /// a click on a row, a search match, a Go To from a row — and the place
    /// they are leaving, the panel's choice (`ToolSession.navigationMark`) and
    /// the dump's view together, goes into the window's navigation history.
    /// Called before the choice changes. An arrow key walking the rows is not
    /// such a choice.
    func noteNavigationStep()
}

public extension ToolHost {
    /// A host with no history to keep — a test double — keeps nothing.
    func noteNavigationStep() {}
}

/// The handle on a sheet `ToolHost.beginBlockingWork` put up.
@MainActor public protocol ToolWork: AnyObject {
    /// What the operation is doing now, under the title.
    func rename(_ phase: String)
    /// The operation is over, however it ended: the sheet goes.
    func finish()
}

/// Bytes that do not change under the reader, from any thread.
///
/// `Sendable` is the whole point: this is what crosses to a detached task so a
/// parse can run off the main actor.
public protocol ToolContentReader: Sendable {
    var size: UInt64 { get }
    /// Reads `length` bytes at `offset`. Throws rather than truncates when the
    /// range runs past the end — a parser reading past the end is a parser that
    /// trusted a size field it should have checked.
    func read(at offset: UInt64, length: Int) throws -> [UInt8]
}

extension ToolContentReader {
    /// The half-open form, for the ranges everything else in this project
    /// speaks.
    public func read(_ range: Range<UInt64>) throws -> [UInt8] {
        try read(at: range.lowerBound, length: Int(range.upperBound - range.lowerBound))
    }
}

/// A file the user picked, already read.
public struct ToolFile: Equatable, Sendable {
    /// The file's name, without its path — what a tool-module shows and what it
    /// can build a suggested name from.
    public var name: String
    public var bytes: [UInt8]

    public init(name: String, bytes: [UInt8]) {
        self.name = name
        self.bytes = bytes
    }
}
