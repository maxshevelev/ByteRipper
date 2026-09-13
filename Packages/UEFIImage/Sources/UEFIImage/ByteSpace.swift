import Foundation

/// Which bytes a node's ranges are in (`Design/UEFI/COMPRESSED_SECTIONS.md` §5).
///
/// Almost every node is a place in the open file. A node found inside a
/// compressed section is not: its offsets are into the buffer that section
/// decompresses to, and put next to file offsets they are wrong in the worst
/// way — plausible. A lookup by file offset would descend into a driver whose
/// buffer offset happens to match the caret; a zone would draw over unrelated
/// bytes of the dump. So every node says which space its ranges are in, and
/// ranges are only ever compared within one space.
public enum ByteSpace: Hashable, Sendable {
    /// The open file.
    case file

    /// The decompressed body of a compressed section.
    ///
    /// The section is named by where it is rather than by `NodeID`, so the
    /// name survives the tree being cut back and grown again: the first offset
    /// is the outermost compressed section's header in the file, and each one
    /// after it a nested compressed section's header inside the buffer before
    /// it.
    case decompressed(chain: [UInt64])

    /// The space of what a compressed section at `offset` — in this space —
    /// decompresses to.
    public func inside(sectionAt offset: UInt64) -> ByteSpace {
        switch self {
        case .file: return .decompressed(chain: [offset])
        case .decompressed(let chain): return .decompressed(chain: chain + [offset])
        }
    }

    /// The header offset, in the file, of the outermost compressed section
    /// this space is inside — the bytes of the file that actually hold a node
    /// in it. Nil for the file itself.
    public var outermostSection: UInt64? {
        switch self {
        case .file: return nil
        case .decompressed(let chain): return chain.first
        }
    }
}
