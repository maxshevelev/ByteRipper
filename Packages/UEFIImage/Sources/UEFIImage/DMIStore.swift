import Foundation

/// Where an image keeps the board's identity — the serial numbers, the UUID,
/// the model, the Windows key — in a store the tree reads as a row of its
/// own: Lenovo's DMI store (`LenovoDMIStore`), AMI's GPNV store, ASUS's
/// (`GPNVRecord`), or Acer's DMI area (`AcerDMIStore`). What a bench looks
/// for first in a dump, and what can sit several levels down: in padding
/// inside a region, or after a volume's free space.
public struct DMIStore: Equatable, Sendable {
    /// The row's kind: `.lenovoDMIStore`, `.gpnvStore` or `.acerDMIStore`.
    public var kind: UEFINodeKind
    /// Where the row is in the file — what tells the row apart from the
    /// others of its kind on the way to it.
    public var range: Range<UInt64>

    public init(kind: UEFINodeKind, range: Range<UInt64>) {
        self.kind = kind
        self.range = range
    }

    /// The kinds that are one.
    public static func isStore(_ kind: UEFINodeKind) -> Bool {
        kind == .lenovoDMIStore || kind == .gpnvStore || kind == .acerDMIStore
    }

    /// Every store in `nodes` and below, in file order. Only in the file:
    /// none of the formats turns up inside a compressed section.
    public static func all(in nodes: [UEFINode]) -> [DMIStore] {
        nodes.flatMap(\.flattened)
            .filter { isStore($0.kind) && $0.space == .file }
            .map { DMIStore(kind: $0.kind, range: $0.range) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
