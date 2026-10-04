import Foundation
import Localization
import UEFIImage

/// What the structure tree says about each node, decided here so the view
/// controller lays out text rather than choosing any of it
/// (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// The Type and Subtype columns read the node in UEFITool's classification —
/// the same `Types::ItemTypes` / `Subtypes` the `UEFITypes` tables mirror — and
/// the name comes from the GUID catalogue when the node has a GUID. All of it
/// is a function of the node and the catalogue, so it is testable without a
/// window.
public enum UEFITreeDisplay {
    /// The Type column: the node's item type, in UEFITool's words.
    public static func typeText(for node: UEFINode) -> String {
        UEFITypes.typeName(node.uefiItemType)
    }

    /// The Subtype column: the node's subtype, when it has one.
    ///
    /// `File` and `Section` are named from the FFS and section type tables the
    /// parser already uses — the C++ `itemSubtypeToUString` delegates them to
    /// `fileTypeToUString` / `sectionTypeToUString`, which are not in
    /// `types.cpp` — so a known type is a word and an unknown one keeps its
    /// number. Every other type reads from the generated `UEFITypes` tables.
    public static func subtypeText(for node: UEFINode) -> String {
        guard let subtype = node.uefiItemSubtype else { return "" }
        switch node.kind {
        case .file: return UEFITypeNames.file(subtype)
        case .section: return UEFITypeNames.section(subtype)
        default: return UEFITypes.subtypeName(type: node.uefiItemType, subtype) ?? ""
        }
    }

    /// What the title leads with before the node count: the type of the top of
    /// the tree. A capsule file leads with its capsule, a dump with its first
    /// root — the same classification the columns show, so the title and the
    /// tree below it agree on what the image is.
    public static func imageType(of image: UEFIImage) -> String {
        guard let root = image.roots.first else { return "" }
        let type = typeText(for: root)
        let subtype = subtypeText(for: root)
        return subtype.isEmpty ? type : "\(type) · \(subtype)"
    }

    /// The tree as it is shown: the outline's top level, and the node the
    /// summary stands for when the tree's root has been taken out of the tree.
    ///
    /// The parser hands over a single-rooted tree — that root is either a
    /// wrapper (an Intel image, the "UEFI image" the parser groups several
    /// tops under, a capsule's envelope) or a real node the file already had,
    /// a lone volume off a chip. A wrapper does no work as a row: its one job
    /// is to say what the whole image is, so it moves up into the panel title
    /// and its children become the top of the outline.
    ///
    /// A real root stays a row. It is a container the tree opens on demand,
    /// and folding it would mean deciding again — differently — the moment
    /// somebody opened it: the row a reader had just clicked would vanish and
    /// its children would jump a level. A row that stays where it is is worth
    /// more than a title that names it.
    public struct PresentedImage {
        /// The hidden root the summary leads with, or nil when nothing was
        /// folded away.
        public let title: UEFINode?
        /// The outline's top level: the root's children when there was a root
        /// to fold, the image's roots otherwise.
        public let rows: [UEFINode]

        public init(title: UEFINode?, rows: [UEFINode]) {
            self.title = title
            self.rows = rows
        }
    }

    /// Padding nobody wrote to: erased bytes between structures. The tree
    /// leaves these out unless the reader asks for them — a dump is full of
    /// them, and a row that stands for nothing is a row to scroll past.
    /// Padding that holds data stays, and so does free space inside a volume,
    /// which says how much room the volume has. So does erased padding with
    /// rows read inside it — an Insyde map's region nobody has written yet —
    /// since hiding it would hide them.
    public static func isEmptyPadding(_ node: UEFINode) -> Bool {
        node.kind == .padding && node.isErased && node.children.isEmpty
    }

    /// `nodes` as the tree lists them: every one, or all but the empty
    /// padding — and all but the copies of variables `hiding` names, which a
    /// store's later entries replaced (`NvramVariableHistory.supersededCopies`).
    public static func listed(_ nodes: [UEFINode], showsEmptyPadding: Bool, hiding: Set<NodeID> = []) -> [UEFINode] {
        guard !showsEmptyPadding || !hiding.isEmpty else { return nodes }
        return nodes.filter { (showsEmptyPadding || !isEmptyPadding($0)) && !hiding.contains($0.id) }
    }

    public static func present(_ image: UEFIImage) -> PresentedImage {
        guard image.roots.count == 1, let root = image.roots.first,
              isWrapper(root), !root.children.isEmpty
        else { return PresentedImage(title: nil, rows: image.roots) }
        return PresentedImage(title: root, rows: root.children)
    }

    /// Whether this root is an envelope around the image rather than a part of
    /// it. These three are the only kinds the parser ever puts at the top with
    /// something else inside them, and none is a container the tree opens
    /// lazily — so whether one folds is decided once, at the first paint, and
    /// never changes under the reader.
    private static func isWrapper(_ node: UEFINode) -> Bool {
        switch node.kind {
        case .intelImage, .uefiImage, .capsule: return true
        default: return false
        }
    }

    /// What the tree is, in one line: what the image is.
    ///
    /// The title leads with what the hidden root *is*. An invented image root —
    /// "UEFI image", "Intel image" — reads by the name the parser gave it, the
    /// phrase UEFITool uses; a real root the file already had (a lone volume, a
    /// lone capsule) reads by its type and subtype, the same words its row would
    /// have shown. Either way it is the same decision the outline shows, so the
    /// title and the tree agree. Without a root to fold — an empty image, one
    /// with several roots — it leads with the first root's image type.
    ///
    /// It counts nothing. The tree the panel reads is materialized branch by
    /// branch as the user opens it, so a node count would be the count of what
    /// happens to have been opened — a number that starts at four on a 16 MiB
    /// dump and climbs as the reader clicks. What the line has to say is what
    /// the image is, which is known from the top level alone.
    public static func summary(of image: UEFIImage?) -> String {
        guard let image else { return "" }
        guard !image.roots.isEmpty else { return L("Nothing here looks like a firmware image.") }
        // The image names protected ranges at all: the one thing about it
        // that says some edits are not free (`BOOT_GUARD_PROTECTED_RANGES.md` §9.3).
        if let ranges = image.protectedRanges, !ranges.ranges.isEmpty {
            let count = ranges.ranges.count
            return titleLead(of: image) + " · " + (count == 1
                ? L("1 protected range") : L("%1$@ protected ranges", count))
        }
        return titleLead(of: image)
    }

    /// The word the title leads with: the hidden root, named the way it reads
    /// as a row. An invented image root is named — "UEFI image" — because that
    /// is the phrase UEFITool uses and the one worth reading in a title; a real
    /// root the file already had is a format the columns name better than its
    /// parser name does, so it reads by type · subtype.
    private static func titleLead(of image: UEFIImage) -> String {
        if let title = present(image).title {
            switch title.kind {
            case .intelImage, .uefiImage:
                return title.name.isEmpty ? imageType(of: image) : title.name
            default:
                return imageType(of: image)
            }
        }
        return imageType(of: image)
    }

    /// The name the tree shows for a node.
    ///
    /// A node with a GUID is named by the catalogue — the community's name for
    /// that GUID — and by the GUID itself while the catalogue has no name for
    /// it, which is the whole of the first paint before a download lands. A
    /// node without a GUID keeps the name the parser gave it, falling back to
    /// its kind when the parser had nothing to say.
    ///
    /// A VSS or NVAR variable is the one node whose GUID is not its identity: the name
    /// the parser decoded — "BootOrder", "PK" — is what a reader looks for, and
    /// many variables share the single vendor GUID that owns them. So its row
    /// keeps the parser's name; the GUID still shows in the details panel.
    ///
    /// With `image`, the outermost nodes of a Top Swap copy say they are one
    /// (`UEFITopSwap`). With `reader` — the bytes of the node's space — a
    /// DVAR row says its value as well.
    public static func name(for node: UEFINode, catalogue: GuidsCatalogue, in image: UEFIImage? = nil,
                            reader: ImageReader? = nil) -> String {
        let base = baseName(for: node, catalogue: catalogue, settings: image?.dvarSettings, reader: reader)
        guard let image else { return base }
        return UEFITopSwap.name(base, for: node, in: image)
    }

    private static func kibibytes(_ length: UInt64) -> UInt64 {
        (length + 0x3FF) / 0x400
    }

    private static func baseName(for node: UEFINode, catalogue: GuidsCatalogue,
                                 settings: DellSetup.Catalogue?, reader: ImageReader?) -> String {
        // An EC image is named by what it carries and how large it is, in
        // KiB — the bench sizes EC firmware by it (128, 192, 256) — and a copy
        // of an earlier one in the same block says so.
        if node.kind == .ecImage {
            let sized = L("%1$@, %2$@ KB", node.name, kibibytes(UInt64(node.range.count)))
            return node.subtype == ECImage.copySubtype ? L("%1$@ (copy)", sized) : sized
        }
        // A block named after the one image it holds gives that image's size
        // inside the parentheses: "EC Firmware (ITE EC-V13.6, 128 KB)".
        if let length = node.namedImageLength, node.name.hasSuffix(")") {
            return L("%1$@, %2$@ KB", String(node.name.dropLast()), kibibytes(length)) + ")"
        }
        // A pad file (`EFI_FV_FILETYPE_FFS_PAD`) has a GUID only because every
        // file header does — all ones, as a rule — and it names nothing.
        if node.kind == .file, node.subtype == 0xF0 {
            // What its body turned out to hold, the way UEFITool renames it.
            if node.children.contains(where: { $0.kind == .startupApData }) {
                return L("Startup AP data padding file")
            }
            if node.children.contains(where: { $0.kind == .padding && !$0.isErased }) {
                return L("Non-empty padding file")
            }
            return L("Padding file")
        }
        // A Dell variable is a number in a namespace. The row says what Setup
        // calls it, where a Setup page asks about it, and its Name ID where
        // none does — the namespace is in the detail, and on a Dell dump it is
        // one GUID on almost every row. Then the value, as Setup words it
        // where it can: "SecureBoot = Not ticked (0x0)"; a value too long to
        // read as a number, by its size: "0x2 (16 bytes)".
        if node.kind == .dvarEntry, node.guid != nil {
            let setting = settings?.setting(for: node)
            let name = setting?.name ?? "0x" + node.name
            guard let value = reader?.bytes(node.body) else { return name }
            guard let text = dvarValue(value, setting: setting) else {
                return value.count > 8 ? L("%1$@ (%2$@ bytes)", name, "\(value.count)") : name
            }
            return "\(name) = \(text)"
        }
        guard let guid = node.guid else {
            return node.name.isEmpty ? kindLabel(node.kind) : node.name
        }
        if node.kind == .vssEntry || node.kind == .nvarEntry, !node.name.isEmpty {
            return node.name
        }
        // A flash device map entry's GUID is a region *type*, and UEFITool
        // names the row by what the type is: "Variable Defaults", "Password".
        if node.kind == .flashDeviceMapEntry, let type = FlashDeviceMap.regionTypeName(guid) {
            return type
        }
        // The region the entry names is called the same — by the parser, which
        // adds what it read inside, such as the EC firmware's identification.
        if node.kind == .flashDeviceMapRegion, FlashDeviceMap.regionTypeName(guid) != nil, !node.name.isEmpty {
            return node.name
        }
        // The community catalogue first; the NVRAM classifier names the GUIDs
        // it knows while the catalogue has no name for them; the GUID itself
        // is the last resort.
        return catalogue.name(of: guid) ?? NvramGuids.name(of: guid) ?? guid.description
    }

    /// A DVAR value up to eight bytes long, little-endian, as a number — with
    /// what Setup calls it in front, where it says.
    static func dvarValue(_ value: [UInt8], setting: DellSetup.Setting?) -> String? {
        guard !value.isEmpty, value.count <= 8 else { return nil }
        let number = value.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let hex = "0x" + String(number, radix: 16, uppercase: true)
        guard let setting, let meaning = dvarMeaning(number, setting: setting) else { return hex }
        return "\(meaning) (\(hex))"
    }

    /// What `number` means to the Setup question: ticked or not, the option
    /// of a list, a number as a number. Nil where Setup does not say.
    static func dvarMeaning(_ number: UInt64, setting: DellSetup.Setting) -> String? {
        switch setting.kind {
        case .checkbox:
            return number == 0 ? L("Not ticked") : number == 1 ? L("Ticked") : nil
        case .oneOf:
            return setting.option(for: number).flatMap { $0.isEmpty ? nil : $0 }
        case .numeric:
            return "\(number)"
        case .string, .other:
            return nil
        }
    }

    private static func kindLabel(_ kind: UEFINodeKind) -> String {
        switch kind {
        case .capsule: return "Capsule"
        case .intelImage: return "Intel image"
        case .uefiImage: return "UEFI image"
        case .flashDescriptor: return "Flash descriptor"
        case .region: return "Region"
        case .volume: return "Volume"
        case .file: return "FFS file"
        case .section: return "Section"
        case .microcode: return "Microcode"
        // The NVRAM stores and entries read as their item-type word, so the
        // fallback name and the Type column can never drift apart.
        case .vssStore: return UEFITypes.typeName(UEFITypes.Item.vssStore.rawValue)
        case .vss2Store: return UEFITypes.typeName(UEFITypes.Item.vss2Store.rawValue)
        case .ftwStore: return UEFITypes.typeName(UEFITypes.Item.ftwStore.rawValue)
        case .fdcStore: return UEFITypes.typeName(UEFITypes.Item.fdcStore.rawValue)
        case .sysFStore: return UEFITypes.typeName(UEFITypes.Item.sysFStore.rawValue)
        case .flashMapStore: return UEFITypes.typeName(UEFITypes.Item.phoenixFlashMapStore.rawValue)
        case .evsaStore: return UEFITypes.typeName(UEFITypes.Item.evsaStore.rawValue)
        case .cmdbStore: return UEFITypes.typeName(UEFITypes.Item.cmdbStore.rawValue)
        case .slicData: return UEFITypes.typeName(UEFITypes.Item.slicData.rawValue)
        case .vssEntry: return UEFITypes.typeName(UEFITypes.Item.vssEntry.rawValue)
        case .sysFEntry: return UEFITypes.typeName(UEFITypes.Item.sysFEntry.rawValue)
        case .evsaEntry: return UEFITypes.typeName(UEFITypes.Item.evsaEntry.rawValue)
        case .flashMapEntry: return UEFITypes.typeName(UEFITypes.Item.phoenixFlashMapEntry.rawValue)
        case .flashDeviceMapStore: return UEFITypes.typeName(UEFITypes.Item.insydeFlashDeviceMapStore.rawValue)
        case .flashDeviceMapEntry: return UEFITypes.typeName(UEFITypes.Item.insydeFlashDeviceMapEntry.rawValue)
        case .nvarEntry: return UEFITypes.typeName(UEFITypes.Item.nvarEntry.rawValue)
        case .nvarGuidStore: return UEFITypes.typeName(UEFITypes.Item.nvarGuidStore.rawValue)
        case .dvarStore: return UEFITypes.typeName(UEFITypes.Item.dellDvarStore.rawValue)
        case .dvarEntry: return UEFITypes.typeName(UEFITypes.Item.dellDvarEntry.rawValue)
        case .startupApData: return UEFITypes.typeName(UEFITypes.Item.startupApDataEntry.rawValue)
        // UEFITool's own words for the gaps between structures — not names
        // the PI spec gives anything, so they translate. The kinds above are
        // the spec's and stay in its English.
        case .padding: return L("Padding")
        case .freeSpace: return L("Free space")
        case .nonUEFIData: return L("Non-UEFI data")
        case .flashDeviceMapRegion: return L("Flash device map region")
        case .ecImage: return L("EC firmware image")
        case .fitComponent: return L("FIT component")
        case .picture: return L("Picture")
        }
    }
}
