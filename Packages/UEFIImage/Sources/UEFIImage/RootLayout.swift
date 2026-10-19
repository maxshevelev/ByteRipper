import Foundation

/// What the bytes at offset 0 of a source are, when that is known from outside
/// them — a part of another image opened on its own
/// (`Design/UEFI/UPDATE_IN_PARENT.md` §2.1).
///
/// A whole image announces itself: a capsule GUID, a descriptor signature, the
/// volumes a scan finds. A part cut out of one does not always: the body of a
/// Tiano or LZMA section is a run of sections, and a signature scan reads it as
/// padding. The tree that parsed the whole knew what the part was, so it says.
public enum UEFIRootLayout: Hashable, Sendable, Codable {
    /// Whatever the bytes announce — the default, and the answer for a whole
    /// image or for a part that is none of the others.
    case image
    /// One firmware volume at offset 0.
    case volume
    /// One FFS file at offset 0, read by the rules of the volume it came from.
    case file(ffsVersion: Int, volumeRevision: UInt8)
    /// A run of sections from offset 0: a file's body, one section, or what a
    /// compressed section decompressed to.
    case sections(ffsVersion: Int)
    /// NVRAM stores from offset 0 — a VSS store, an FTW block, an FDC: what
    /// an NVRAM volume's body is walked as. A store opened on its own has no
    /// volume around it, and the signature scan an image gets does not look
    /// for stores, so without this its variables read as padding.
    case nvramStores
    /// One node from offset 0, as the parent's tree knew it: what a part is
    /// that the bytes alone do not say — a region the descriptor laid out, a
    /// range the flash device map names (`SMBIOS Update`), a structure the
    /// FIT points at, an NVAR variable. Read by the bytes' own reader where
    /// one finds it; otherwise the node is the root it was in the parent,
    /// over what the bytes hold.
    case node(Node)

    /// What the parent's tree knew of a node: enough to stand it up again as
    /// a root over the same bytes.
    public struct Node: Hashable, Sendable, Codable {
        public var kind: UEFINodeKind
        public var subtype: UInt8?
        public var name: String
        public var guid: EFIGUID?
        /// How long its header is; the body is the rest.
        public var headerLength: UInt64
        public var isFixed: Bool
        /// Nothing under it in the parent, and nothing to open: an ME region
        /// is a format of its own, which a scan would only misread.
        public var isLeaf: Bool

        public init(_ node: UEFINode) {
            kind = node.kind
            subtype = node.subtype
            name = node.name
            guid = node.guid
            headerLength = UInt64(node.header.count)
            isFixed = node.isFixed
            isLeaf = node.children.isEmpty && !node.isExpandable
        }
    }

    /// What a compressed section decompresses to: sections, by the FFSv3 rules
    /// every buffer is read with (`COMPRESSED_SECTIONS.md` §6.1).
    public static let decompressedBody = UEFIRootLayout.sections(ffsVersion: 3)

    /// What `node`'s bytes, header through tail, are when opened as a root.
    public static func of(_ node: UEFINode, in image: UEFIImage) -> UEFIRootLayout {
        switch node.kind {
        case .volume:
            return .volume
        case .file:
            let volume = enclosingVolume(of: node, in: image)
            return .file(
                ffsVersion: ffsVersion(of: node, volume: volume),
                volumeRevision: volume?.subtype ?? 2
            )
        case .section:
            return .sections(ffsVersion: ffsVersion(of: node, volume: enclosingVolume(of: node, in: image)))
        case .vssStore, .vss2Store, .ftwStore, .fdcStore, .sysFStore, .flashMapStore, .evsaStore, .cmdbStore:
            return .nvramStores
        case .padding, .freeSpace:
            // Bytes nobody claimed: whatever they announce is all there is.
            return .image
        default:
            return .node(Node(node))
        }
    }

    /// What `node`'s body alone is when opened as a root: a sectioned file's
    /// body, and an encapsulation section's that is not compressed, are runs of
    /// sections. Any other body stands on its own only as bytes.
    public static func ofBody(of node: UEFINode, in image: UEFIImage) -> UEFIRootLayout {
        let version = ffsVersion(of: node, volume: enclosingVolume(of: node, in: image))
        switch node.kind {
        case .file where node.subtype.map(FFS.hasSections) ?? false:
            return .sections(ffsVersion: version)
        case .section where node.compression == nil
            && node.children.contains(where: { $0.space == node.space }):
            return .sections(ffsVersion: version)
        default:
            return .image
        }
    }

    /// What the bytes at `range` of the file are, from the innermost node that
    /// covers exactly that range — or whose body does. `.image` when no node
    /// the tree has materialized does.
    public static func forFileRange(_ range: Range<UInt64>, in image: UEFIImage) -> UEFIRootLayout {
        let nodes = image.allNodes
        if let node = nodes.last(where: { $0.fileRange == range }) {
            return of(node, in: image)
        }
        if let node = nodes.last(where: { $0.space == .file && !$0.header.isEmpty && $0.body == range }) {
            return ofBody(of: node, in: image)
        }
        return .image
    }

    // MARK: - Private

    /// The volume a node's bytes are laid out in, in the node's own space: nil
    /// for a node inside a buffer with no volume of its own around it.
    private static func enclosingVolume(of node: UEFINode, in image: UEFIImage) -> UEFINode? {
        var path = node.id.path
        while !path.isEmpty {
            path.removeLast()
            guard let ancestor = image.node(NodeID(path)) else { continue }
            if ancestor.space != node.space { return nil }
            if ancestor.kind == .volume { return ancestor }
        }
        return nil
    }

    /// The FFS rules the node is read by: its volume's file system, or FFSv3
    /// inside a buffer, or FFSv2 when neither says.
    private static func ffsVersion(of node: UEFINode, volume: UEFINode?) -> Int {
        if let version = volume?.guid.flatMap(KnownGUIDs.ffsVersion(ofFileSystem:)) {
            return version
        }
        return node.space == .file ? 2 : 3
    }
}
