import Foundation
import ToolModuleKit
import UEFIImage

/// The decisions the UEFI structure panel makes, built and tested without a
/// window (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// The panel is a tree of thousands of nodes and a detail for the one in focus.
/// What crosses the seam to the dump is the one node the user is looking at,
/// and what the detail says comes from the node's header, read through the
/// reader the parse used. Both of those are decided here.
public enum UEFIPresenter {
    /// What separates a part of a node from the node in a zone id. A path is
    /// digits and dots, so nothing this can be confused with ever appears in
    /// one.
    private static let partSeparator = "#"
    private static let bodyPart = "body"

    /// The zones a selected node publishes: the node itself, and — when it has
    /// a header of its own — its body as a zone inside it, which is the focus.
    /// Nil is "nothing selected yet" — the honest state before a choice, and
    /// the one a re-parse that lost the node lands on.
    ///
    /// Two zones, not three. Almost every level of this format is a header
    /// followed by a body the next level parses, and "where does the header
    /// end" is the question a bench opens a dump to answer — but the body's
    /// own start answers it, and a third zone over the header would draw a
    /// boundary the other two already show. The node's zone stays because it
    /// is what says how far the structure reaches, and it is what the *tail* of
    /// an FFSv1 file falls inside — so the body does not have to reach the end
    /// of it.
    ///
    /// Still only this node, never its children: a UEFI parse is a tree of
    /// thousands of nodes and drawing them all is how the hex view stops being
    /// readable.
    ///
    /// A node inside a compressed section is not a range of the file, and its
    /// buffer offsets drawn over the dump would outline unrelated bytes. What
    /// it publishes is the section that holds it — the bytes that really are
    /// it — named after both, and picking that zone brings back the section,
    /// which is all the file can say (`COMPRESSED_SECTIONS.md` §5.3). `image`
    /// is where that section is found; without it such a node publishes
    /// nothing.
    public static func zones(for node: UEFINode?, in image: UEFIImage? = nil) -> ZoneMap {
        guard let node else { return .empty }
        guard let outermost = node.space.outermostSection else {
            return zones(of: node, named: node.name)
        }
        guard let image,
              let section = image.innermostNode(containing: outermost),
              section.space == .file, section.header.lowerBound == outermost
        else { return .empty }
        let name = node.name.isEmpty ? "Compressed" : node.name
        return zones(of: section, named: "\(name) (in \(section.name))")
    }

    private static func zones(of node: UEFINode, named name: String) -> ZoneMap {
        let whole = Zone(id: zoneID(for: node.id), name: name, range: node.range)

        // A node with no header of its own — padding, free space, data nobody
        // claimed — is all body, and a node with no body has none to draw.
        // Either way the body's zone would be the node's own drawn twice, so
        // the node is the whole of what is published, and the focus.
        guard !node.header.isEmpty, !node.body.isEmpty else {
            return ZoneMap(zones: [whole], focus: whole.id)
        }

        let body = Zone(
            id: whole.id + partSeparator + bodyPart,
            name: node.name.isEmpty ? "Body" : "\(node.name) body",
            range: node.body
        )
        // Outermost first, which is the order the dump draws and the minimap
        // lanes read (`ZoneMap.normalized`). The body is the focus: it is what
        // the node holds, and what is in front of it is the header.
        return ZoneMap(zones: [whole, body], focus: body.id)
    }

    /// What "Export Decompressed…" saves, and "Open Decompressed… in New Tab"
    /// opens, for a node (`COMPRESSED_SECTIONS.md` §8.2).
    public struct DecompressedExport: Equatable, Sendable {
        /// The buffer to read.
        public var space: ByteSpace
        /// The part of it to save, or nil for all of it.
        public var range: Range<UInt64>?
        public var suggestedName: String
        public var menuTitle: String
        public var openTitle: String

        /// The new tab's name: the dump it came out of, then what it is —
        /// `bios_LZMA compressed section.bin` — the way a zone's tab is named.
        public func tabName(fileName: String) -> String {
            let stem = (fileName as NSString).deletingPathExtension
            return stem.isEmpty ? suggestedName : "\(stem)_\(suggestedName)"
        }
    }

    /// A compressed section that opened exports everything it decompressed
    /// to; a node inside one exports its own bytes from that buffer. Nothing
    /// else has anything decompressed to save — its bytes are the file's, and
    /// the dump already exports those.
    public static func decompressedExport(for node: UEFINode) -> DecompressedExport? {
        let base = (node.name.isEmpty ? "decompressed" : node.name)
            .map { "/:".contains($0) ? "_" : $0 }
        if node.kind == .section, node.children.contains(where: { $0.space != node.space }) {
            return DecompressedExport(
                space: node.space.inside(sectionAt: node.header.lowerBound),
                range: nil,
                suggestedName: String(base) + ".bin",
                menuTitle: "Export Decompressed Body…",
                openTitle: "Open Decompressed Body in New Tab"
            )
        }
        if node.space != .file {
            return DecompressedExport(
                space: node.space,
                range: node.range,
                suggestedName: String(base) + ".bin",
                menuTitle: "Export Decompressed Bytes…",
                openTitle: "Open Decompressed Bytes in New Tab"
            )
        }
        return nil
    }

    /// Where a node's bytes are held in the file: its own range, or — for a
    /// node inside a compressed section — the outermost section's. What a tab
    /// opened from the node is linked to (`UPDATE_IN_PARENT.md` §2.1).
    public static func fileSource(of node: UEFINode, in image: UEFIImage) -> Range<UInt64>? {
        if let range = node.fileRange { return range }
        guard let outermost = node.space.outermostSection,
              let section = image.innermostNode(containing: outermost),
              section.header.lowerBound == outermost
        else { return nil }
        return section.fileRange
    }

    /// A node's path as a zone id: `1.2.0`. Stable across a re-parse of the same
    /// image — which is what lets a selection survive the re-read an edit causes
    /// — and the route a diagnostic about a node three levels down needs.
    public static func zoneID(for id: NodeID) -> String { id.description }

    /// The trip back: the user picked a zone in the dump and the panel has to
    /// expand to the node it came from. Nil for an id this module did not make.
    ///
    /// A part's zone leads to the same node as the whole of it — the reader
    /// picked "MyDriver body" in the dump and the row they want is MyDriver.
    public static func nodeID(ofZone id: String) -> NodeID? {
        let path = id.split(separator: partSeparator, omittingEmptySubsequences: false)[0]
        guard !path.isEmpty else { return nil }
        let fields = path.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == fields.count else { return nil }
        return NodeID(numbers)
    }
}
