import Foundation
import Localization

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

/// One value of a vendor's identity area where the area keeps it as a field
/// of its own bytes — Acer's block, HP's `HP_MUD` — shown in the tree as a
/// row under the area's (`UEFINodeKind.dmiField`), the way Lenovo's entries
/// are under their block. The row's subtype is the field's `Encoding`, so
/// the row reads its value from its own bytes.
public struct DMIField: Equatable, Sendable {
    /// How the value is written in the field's bytes.
    public enum Encoding: UInt8, Sendable {
        /// Printable ASCII, to the first NUL, FF or byte that is not.
        case ascii
        /// UTF-16 little-endian, to the first NUL.
        case utf16
        /// A UUID as SMBIOS stores one: the first three groups little-endian.
        case smbiosUUID
        /// A UUID as Acer stores one: the first two groups little-endian, the
        /// third as it reads (`AcerDMIArea.uuidText`).
        case acerUUID
    }

    public var name: LocalizedText
    public var range: Range<UInt64>
    public var encoding: Encoding

    public init(_ name: LocalizedText, range: Range<UInt64>, encoding: Encoding) {
        self.name = name
        self.range = range
        self.encoding = encoding
    }

    /// The field's row: all body, no header.
    public func node(isFixed: Bool) -> UEFINode {
        UEFINode(kind: .dmiField, subtype: encoding.rawValue, named: name,
                 header: range.lowerBound..<range.lowerBound, body: range, isFixed: isFixed)
    }

    /// The value `bytes` hold, written as `encoding`; empty where nothing
    /// readable is written.
    public static func text(of bytes: [UInt8], as encoding: Encoding) -> String {
        switch encoding {
        case .ascii:
            let text = bytes.prefix { (0x20...0x7E).contains($0) }
            return String(decoding: text, as: UTF8.self)
        case .utf16:
            return HPDMIArea.text(bytes[...]) ?? ""
        case .smbiosUUID:
            guard bytes.count == 16 else { return "" }
            return EFIGUID(bytes: bytes).description
        case .acerUUID:
            guard bytes.count == 16 else { return "" }
            return AcerDMIArea.uuidText(bytes)
        }
    }

    /// The value a `dmiField` row holds, read from its bytes; nil for any
    /// other row, or one whose bytes are not there.
    public static func text(of node: UEFINode, reader: ImageReader) -> String? {
        guard node.kind == .dmiField, let encoding = node.subtype.flatMap(Encoding.init(rawValue:)),
              let bytes = reader.bytes(node.body)
        else { return nil }
        return text(of: bytes, as: encoding)
    }
}
