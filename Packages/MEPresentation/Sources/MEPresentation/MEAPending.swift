import Foundation

/// What the analysis on screen has not been read with yet.
///
/// The ME panel shows a first reading of the dump as soon as it has one — read
/// with whatever of `FileTable.dat` and `Huffman.dat` was already in hand — and
/// reads it again once they arrive. A value that depends on one of them says
/// "Loading…" until then, rather than a value the second reading may change.
public struct MEAPending: Sendable, Equatable {
    /// A file table is wanted and was not read with: an EFS volume's files are
    /// not known, so neither is whether it holds any.
    public var fileTable: Bool
    /// Dictionaries are wanted and were not read with: the Huffman modules
    /// have not been checked.
    public var huffman: Bool

    public init(fileTable: Bool = false, huffman: Bool = false) {
        self.fileTable = fileTable
        self.huffman = huffman
    }

    /// Everything known: the analysis read every database it wanted, or the
    /// ones it could not get are not coming. Not called `none`: where the
    /// value is optional that reads as `Optional.none` — nil, "nothing to
    /// say" — and a final reading handed `.none` kept the first one's
    /// "Loading…".
    public static let nothing = MEAPending()
}
