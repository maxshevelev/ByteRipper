import Foundation
import Localization
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
        return zones(of: section, named: L("%1$@ (in %2$@)", name, section.name))
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

    /// What "Save Decompressed Body as…" saves, and "Open Decompressed Body"
    /// opens, for a compressed section (`COMPRESSED_SECTIONS.md` §8.2).
    public struct DecompressedBody: Equatable, Sendable {
        /// The buffer to read, all of it.
        public var space: ByteSpace
        /// What a panel opened on it reads the bytes as: a run of sections
        /// out of a compressed section, a stretch of flash out of the BIOS
        /// image the AMD PSP inflates.
        public var layout: UEFIRootLayout
        public var suggestedName: String
        public var saveTitle: String
        public var openTitle: String

        /// The new tab's name: the dump it came out of, then what it is —
        /// `bios_LZMA compressed section.bin` — the way a zone's tab is named.
        public func tabName(fileName: String) -> String {
            let stem = (fileName as NSString).deletingPathExtension
            return stem.isEmpty ? suggestedName : "\(stem)_\(suggestedName)"
        }
    }

    /// What opening a node — or its body alone — as a panel of its own means
    /// (`Design/FRAGMENT_PANELS_PLAN.md`).
    ///
    /// Every node can be opened: a volume, a file, a section, and a node inside
    /// a compressed section as much as one in the file. The way to study a part
    /// of an image is often to read it as a file — its own offsets from zero,
    /// its own search, its own tree — and the tree is where the reader is
    /// already pointing at the part they mean.
    public struct NodeOpen: Equatable, Sendable {
        /// The buffer the bytes are read from: the file, or what a compressed
        /// section opened to.
        public var space: ByteSpace
        /// The bytes, in that space.
        public var range: Range<UInt64>
        /// The file bytes the panel links back to — the node's own where they
        /// are the file's, and the compressed section they came out of where
        /// they are not.
        public var source: Range<UInt64>
        /// What a UEFI panel opened on the part should read the bytes as.
        public var layout: UEFIRootLayout
        /// Where the bytes go back to through the rebuild planner, when the
        /// part is something the image's structure can be laid out around
        /// again (`Design/UEFI/UPDATE_IN_PARENT.md` §6).
        public var rebuild: UEFIRebuild.Target?
        public var suggestedName: String
        public var menuTitle: String

        /// The panel's name: the dump it came out of, then what it is — the way
        /// a zone's and a decompressed body's are named.
        public func partName(fileName: String) -> String {
            let stem = (fileName as NSString).deletingPathExtension
            return stem.isEmpty ? suggestedName : "\(stem)_\(suggestedName)"
        }
    }

    /// What opening `node` would do, or nil when there is nothing there to
    /// open: an empty range, or a part of a buffer whose compressed section
    /// cannot be traced back to the file.
    ///
    /// `body` asks for the body alone, which is worth offering only where the
    /// node has a header to tell the two apart — the caller decides whether to
    /// offer it, and this refuses a body that is the whole node anyway.
    /// What the tree's menu calls opening `node`, or nil when there is nothing
    /// there to open. The title alone, for a menu built where the image is not
    /// at hand; `nodeOpen` answers the rest.
    ///
    /// A node inside a compressed section is read from the buffer the section
    /// decoded to, and its titles say so: there is no second item for "the
    /// bytes it decompressed to" — they are what opening it opens.
    public static func nodeOpenTitle(for node: UEFINode, body: Bool) -> String? {
        let range = body ? node.body : node.range
        guard !range.isEmpty, !(body && range == node.range) else { return nil }
        let decompressed = node.space != .file
        guard !node.name.isEmpty else {
            switch (decompressed, body) {
            case (false, false): return L("Open Node")
            case (false, true): return L("Open Node Body")
            case (true, false): return L("Open Decompressed Node")
            case (true, true): return L("Open Decompressed Node Body")
            }
        }
        // The name is poured in, never spelled into the key: a key built at
        // run time is a key no translator can find.
        switch (decompressed, body) {
        case (false, false): return L("Open “%1$@”", node.name)
        case (false, true): return L("Open Body of “%1$@”", node.name)
        case (true, false): return L("Open Decompressed “%1$@”", node.name)
        case (true, true): return L("Open Decompressed Body of “%1$@”", node.name)
        }
    }

    /// What the tree's menu calls saving `node` — or its body alone — to a
    /// file: offered wherever opening it is, since it is the same bytes.
    public static func nodeSaveTitle(for node: UEFINode, body: Bool) -> String? {
        guard nodeOpenTitle(for: node, body: body) != nil else { return nil }
        let decompressed = node.space != .file
        guard !node.name.isEmpty else {
            switch (decompressed, body) {
            case (false, false): return L("Save Node as…")
            case (false, true): return L("Save Node Body as…")
            case (true, false): return L("Save Decompressed Node as…")
            case (true, true): return L("Save Decompressed Node Body as…")
            }
        }
        switch (decompressed, body) {
        case (false, false): return L("Save “%1$@” as…", node.name)
        case (false, true): return L("Save Body of “%1$@” as…", node.name)
        case (true, false): return L("Save Decompressed “%1$@” as…", node.name)
        case (true, true): return L("Save Decompressed Body of “%1$@” as…", node.name)
        }
    }

    /// What a double click on a node's row opens: the body a compressed section
    /// decompresses to, otherwise the node's body, and the whole node where it
    /// has no body apart from itself (padding, free space, a node with a header
    /// and nothing after it). The same choices the tree's menu offers, taken
    /// without asking.
    public enum Content: Equatable, Sendable {
        case decompressedBody
        case body
        case node
    }

    public static func content(of node: UEFINode) -> Content {
        if decompressedBody(for: node) != nil { return .decompressedBody }
        if !node.header.isEmpty, nodeOpenTitle(for: node, body: true) != nil { return .body }
        return .node
    }

    public static func nodeOpen(for node: UEFINode, in image: UEFIImage, body: Bool) -> NodeOpen? {
        guard let title = nodeOpenTitle(for: node, body: body) else { return nil }
        let range = body ? node.body : node.range

        // Where it links back to. A node in the file is its own source; one in
        // a buffer is linked to the compressed section that buffer came out of,
        // and goes back through it.
        let source: Range<UInt64>?
        if node.space == .file {
            source = range
        } else {
            source = fileSource(of: node, in: image)
        }
        guard let source else { return nil }

        let base = String((node.name.isEmpty ? "node" : node.name)
            .map { "/:".contains($0) ? "_" : $0 })
        // Bytes of a decoded buffer say so in the name, so that a node and the
        // node of the same name in the file do not arrive as one file.
        let suffix = (node.space != .file ? " decompressed" : "") + (body ? " body" : "")
        return NodeOpen(
            space: node.space,
            range: range,
            source: source,
            layout: body ? .ofBody(of: node, in: image) : .of(node, in: image),
            // A whole node of the file is a structure the image can be laid out
            // around again; a body, or a slice of a buffer, is bytes going back
            // where they were.
            rebuild: node.space == .file && !body
                ? UEFIRebuild.target(forFileRange: range, in: image)
                : UEFIRebuild.Target(space: node.space, range: range),
            // A picture or a sound saves as what it is, so the file opens in
            // a viewer or a player.
            suggestedName: base + suffix + "." + fileExtension(of: node),
            menuTitle: title
        )
    }

    /// What a saved node's file is called after: its format, for a picture
    /// or a sound, and `bin` for bytes that are only bytes.
    private static func fileExtension(of node: UEFINode) -> String {
        switch node.kind {
        case .picture: return node.subtype.flatMap(Picture.Format.init(rawValue:))?.fileExtension ?? "bin"
        case .sound: return "wav"
        default: return "bin"
        }
    }

    /// A compressed section offers everything it decompresses to — one that
    /// opened, and one still closed that would: the row already says it is
    /// compressed, and the buffer is decoded when it is read. A node inside a
    /// decoded buffer needs no second item: opening or saving it is reading
    /// those bytes (`nodeOpenTitle`). Nothing else has anything decompressed
    /// to offer — its bytes are the file's, and the dump already has those.
    public static func decompressedBody(for node: UEFINode) -> DecompressedBody? {
        let opened = node.children.contains { $0.space != node.space }
        let closed = node.compression?.decodes == true && node.isExpandable && node.children.isEmpty
        guard node.kind == .section || node.kind == .biosGuardUpdate
                || (node.kind == .amdFirmwareEntry && node.compression != nil),
              opened || closed
        else { return nil }
        // A BIOS Guard update holds a BIOS region, assembled from its blocks
        // rather than decompressed, and the items say which.
        if node.kind == .biosGuardUpdate {
            return DecompressedBody(
                space: node.space.inside(sectionAt: node.header.lowerBound),
                layout: .image,
                suggestedName: "BIOS region.bin",
                saveTitle: L("Save Assembled BIOS Region as…"),
                openTitle: L("Open Assembled BIOS Region")
            )
        }
        // What came *out* of a section says so in its name. Without it the
        // section opened as a node and the same section's decompressed body
        // arrive under one name — `bios_LZMA Section.bin` twice — and the two
        // hold entirely different bytes. A node with no name is already called
        // `decompressed`, so it says it once.
        let base = String((node.name.isEmpty ? "decompressed" : node.name)
            .map { "/:".contains($0) ? "_" : $0 })
        let marked = node.name.isEmpty ? base : base + " decompressed"
        return DecompressedBody(
            space: node.space.inside(sectionAt: node.header.lowerBound),
            layout: node.kind == .section ? .decompressedBody : .image,
            suggestedName: marked + ".bin",
            saveTitle: L("Save Decompressed Body as…"),
            openTitle: L("Open Decompressed Body")
        )
    }

    /// The variable in an Apple system-flags store whose data is a bzip2 stream
    /// (`AppleOverrides`): it has no section to open, but its data unpacks to
    /// text the reader wants as a file.
    public static func isBZip2Variable(_ node: UEFINode) -> Bool {
        node.kind == .sysFEntry && node.name == AppleOverrides.variableName
    }

    /// The descriptor's BIOS region — what a vendor's update file carries, and
    /// so the row it is compared from (`UEFIUpdateComparison`).
    public static func isBIOSRegion(_ node: UEFINode) -> Bool {
        node.kind == .region && node.subtype == 0x01 && node.space == .file
    }

    /// The name of the tab the unpacked text opens in, as a decompressed
    /// body's is: the dump it came out of, then what it is.
    public static func unpackedTabName(of node: UEFINode, fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let what = "\(node.name) decompressed.txt"
        return stem.isEmpty ? what : "\(stem)_\(what)"
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

    /// The zones of the node in focus with a range added and put in focus —
    /// a region an Insyde map names, picked in the detail: the reader sees
    /// where it lies without the tree moving off the map. The range's id is
    /// no node's path, so picking it in the dump leads nowhere.
    public static func zones(outlining range: Range<UInt64>, named name: String, over focused: ZoneMap) -> ZoneMap {
        let outline = Zone(id: "range:\(range.lowerBound)-\(range.upperBound)", name: name, range: range)
        return ZoneMap(zones: focused.zones.filter { $0.id != outline.id } + [outline], focus: outline.id)
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
