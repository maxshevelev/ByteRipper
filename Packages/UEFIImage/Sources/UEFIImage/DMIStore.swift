import Foundation

/// Where an image keeps the board's identity — the serial numbers, the UUID,
/// the model, the Windows key — in a store the tree reads as a row of its
/// own: Lenovo's DMI store (`LenovoDMIStore`), AMI's GPNV store, ASUS's
/// (`GPNVRecord`), Acer's DMI area (`AcerDMIStore`), or HP's `HP_MUD`
/// variable (`HPDMIArea`), an NVRAM entry rather than a row of its own, or
/// Apple's SysF store (`AppleDMIArea`), which is a row of its own but one the
/// tree has for every Mac. What a bench looks
/// for first in a dump, and what can sit several levels down: in padding
/// inside a region, or after a volume's free space.
public struct DMIStore: Equatable, Sendable {
    /// The row's kind: `.lenovoDMIStore`, `.gpnvStore`, `.acerDMIStore`, or
    /// `.vssEntry` for HP's `HP_MUD`, `.sysFStore` for Apple's.
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
    /// none of the formats turns up inside a compressed section. HP's is
    /// found only with `reader`: a VSS entry is told for one by its name, and
    /// a marked entry's name is in its bytes, not on the node. So is Apple's:
    /// a SysF store is one only when it holds the serial or the board's.
    public static func all(in nodes: [UEFINode], reader: ImageReader? = nil) -> [DMIStore] {
        let inFile = nodes.flatMap(\.flattened).filter { $0.space == .file }
        let rows = inFile
            .filter { isStore($0.kind) }
            .map { DMIStore(kind: $0.kind, range: $0.range) }
        let hp = reader.map { reader in
            inFile
                .filter { $0.kind == .vssStore || $0.kind == .vss2Store }
                .compactMap { HPDMIArea.read(store: $0, reader: reader) }
                .map { DMIStore(kind: .vssEntry, range: $0.entry) }
        } ?? []
        let apple = reader.map { reader in
            inFile
                .filter { $0.kind == .sysFStore }
                .compactMap { AppleDMIArea.read(store: $0, reader: reader) }
                .map { DMIStore(kind: .sysFStore, range: $0.store) }
        } ?? []
        return (rows + hp + apple).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
