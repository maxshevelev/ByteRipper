import Foundation
import LenovoDMI
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
        // Padding to UEFITool; what the column can say of a record is
        // whether it is the one in force.
        case .gpnvRecord: return node.subtype == 1 ? L("Current") : L("Superseded")
        case .lenvBlock: return node.subtype == 1 ? L("In use", context: "LENV block") : L("Not in use")
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

    /// A row that stands for room rather than for content: every row the
    /// Subtype column calls "Empty (FFh)", free space, and a pad file with an
    /// erased body. The tree draws it grey, the way the ME tree draws a
    /// section that holds nothing — a place in the layout, not something to
    /// go and look at. A row with rows read inside it is not one, nor is a
    /// pad file that holds data: what was read there is content.
    ///
    /// "Empty (FFh)" is asked of the column's own classification rather than
    /// of the node's kind: plain padding is not the only row it names — an
    /// Insyde map's region nobody has written (Unused, a password slot, an
    /// MSDM table) is one too, and a rule that listed kinds left those rows
    /// black under a column that said they were empty.
    public static func isEmptySpace(_ node: UEFINode) -> Bool {
        guard node.children.isEmpty else { return false }
        switch node.kind {
        case .freeSpace: return true
        case .file: return node.subtype == 0xF0
        default:
            return node.uefiItemType == UEFITypes.Item.padding.rawValue
                && node.uefiItemSubtype == UEFITypes.Sub.onePadding
        }
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
    /// DVAR, VSS or NVAR row says its value as well. A VSS value lies where
    /// its store's format puts it: `store` is the entry's store, looked up in
    /// `image` when not given.
    public static func name(for node: UEFINode, catalogue: GuidsCatalogue, in image: UEFIImage? = nil,
                            reader: ImageReader? = nil, store: UEFINode? = nil) -> String {
        let base = baseName(for: node, catalogue: catalogue, image: image, reader: reader, store: store)
        guard let image else { return base }
        return UEFITopSwap.name(base, for: node, in: image)
    }

    /// The name a file gives itself in its Name section (`EFI_SECTION_USER_INTERFACE`),
    /// looked for through the sections opened so far; nil for anything else,
    /// and for a file with none.
    public static func ownName(of node: UEFINode) -> String? {
        guard node.kind == .file else { return nil }
        func search(_ sections: [UEFINode]) -> String? {
            for section in sections where section.kind == .section {
                if isNameSection(section), !section.name.isEmpty { return section.name }
                if let nested = search(section.children) { return nested }
            }
            return nil
        }
        return search(node.children)
    }

    /// A Name section: its text is its file's name.
    public static func isNameSection(_ node: UEFINode) -> Bool {
        node.kind == .section && node.subtype == 0x15
    }

    /// Whether the row of `node` says a value, and so needs the bytes.
    public static func showsValue(_ node: UEFINode) -> Bool {
        node.kind == .dvarEntry || node.kind == .vssEntry || node.kind == .nvarEntry || node.kind == .gpnvRecord
            || node.kind == .lenvBlock || node.kind == .lenvEntry || node.kind == .ldbgEntry
    }

    private static func kibibytes(_ length: UInt64) -> UInt64 {
        (length + 0x3FF) / 0x400
    }

    private static func baseName(for node: UEFINode, catalogue: GuidsCatalogue,
                                 image: UEFIImage?, reader: ImageReader?, store: UEFINode?) -> String {
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
            let setting = image?.dvarSettings?.setting(for: node)
            let name = setting?.name ?? "0x" + node.name
            guard let value = reader?.bytes(node.body) else { return name }
            guard let text = dvarValue(value, setting: setting) else {
                return value.count > 8 ? L("%1$@ (%2$@ bytes)", name, "\(value.count)") : name
            }
            return "\(name) = \(text)"
        }
        // A GPNV record says what it holds: the Windows key, or the text in
        // its data — serial numbers, the model — as far as a row has room.
        if node.kind == .gpnvRecord, let reader {
            return gpnvRow(node, reader: reader)
        }
        // Lenovo's DMI store says what it holds, decoded: a block its
        // generation, an entry its value, a write of the log what it did.
        // `store` is the row's parent — the block, or the log.
        if let reader, let text = lenovoDMIRow(node, parent: store, reader: reader) {
            return text
        }
        // Acer's DMI area says what it holds: the serial, the rest in the
        // detail.
        if node.kind == .acerDMIStore, let reader {
            return acerDMIRow(node, reader: reader)
        }
        guard let guid = node.guid else {
            return node.name.isEmpty ? kindLabel(node.kind) : node.name
        }
        // A file that names itself is called what it says: the firmware's own
        // word for this image beats the catalogue's for the GUID, which a
        // vendor can have given to another module (the catalogue's name, when
        // it differs, is in the detail).
        if let own = ownName(of: node) {
            return own
        }
        // A live VSS variable's value follows its name, as its type reads:
        // `BootOrder = 0003, 2001`, `Lang = "eng"`. The store says where the
        // value is.
        if node.kind == .vssEntry, !node.name.isEmpty {
            guard node.subtype != UEFITypes.Sub.invalidVssEntry, let reader else { return node.name }
            let store = store ?? (node.id.path.isEmpty ? nil : image?.node(NodeID(Array(node.id.path.dropLast()))))
            guard let variable = VSSVariable.read(node, inVss2: store?.kind == .vss2Store, reader: reader)
            else { return node.name }
            return valueRow(node.name, guid: variable.vendorGuid, attributes: variable.attributes,
                            value: variable.data, reader: reader)
        }
        // So does an NVAR variable's, on the entry that holds it now: a link
        // of a chain holds a value a later entry replaced.
        if node.kind == .nvarEntry, !node.name.isEmpty {
            guard node.subtype == UEFITypes.Sub.fullNvarEntry || node.subtype == UEFITypes.Sub.dataNvarEntry,
                  let reader
            else { return node.name }
            return valueRow(node.name, guid: node.guid, attributes: nvarAttributes(node, reader: reader),
                            value: node.body, reader: reader)
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

    /// A store of the board's identity as the panel's DMI menu lists it:
    /// what it is and where — "Lenovo DMI store at 0x00630000".
    public static func dmiStoreTitle(_ store: DMIStore) -> String {
        L("%1$@ at %2$@", kindLabel(store.kind), String(format: "0x%08llX", store.range.lowerBound))
    }

    /// `Baseboard serial number = PF0TEST1`, `LENV block 2 · generation 84`,
    /// `2022-06-29 20:30:25 · Set · Baseboard serial number`; nil for a row
    /// of anything else, or one whose bytes do not read.
    static func lenovoDMIRow(_ node: UEFINode, parent: UEFINode?, reader: ImageReader) -> String? {
        switch node.kind {
        case .lenvBlock:
            guard let stored = reader.bytes(node.range),
                  let text = UEFILenovoDMIDetail.blockText(LENVBlock(offset: node.range.lowerBound, stored: stored))
            else { return nil }
            return L("%1$@ · %2$@", node.name, text)
        case .lenvEntry:
            guard let parent, parent.kind == .lenvBlock, let stored = reader.bytes(parent.range),
                  let entry = LENVBlock(offset: parent.range.lowerBound, stored: stored)
                    .entries.first(where: { $0.offset == node.header.lowerBound })
            else { return nil }
            return L("%1$@ = %2$@", node.name, LenovoDMIValue.text(of: entry))
        case .ldbgEntry:
            guard let parent, parent.kind == .ldbgLog,
                  let entry = UEFILenovoDMIDetail.area(startingAt: parent.range.lowerBound, reader: reader)?
                    .log.entries.first(where: { $0.offset == node.range.lowerBound })
            else { return nil }
            return L("%1$@ · %2$@", node.name, UEFILenovoDMIDetail.logEntryText(entry))
        default:
            return nil
        }
    }

    /// `Acer DMI · N51…`: the area's name and the system serial it holds;
    /// the tag, the UUID, the model and the product name are in the detail.
    static func acerDMIRow(_ node: UEFINode, reader: ImageReader) -> String {
        guard let stored = reader.bytes(node.range),
              let area = AcerDMIArea.found(stored: stored, offset: node.range.lowerBound)
        else { return node.name }
        return L("%1$@ · %2$@", node.name, area.systemSerial)
    }

    /// `MFG0 = M8NRKD00311031C, 90NR0551-M04320, …`: a record's name and the
    /// first texts of its data; an `OA30` record's product key.
    static func gpnvRow(_ node: UEFINode, reader: ImageReader) -> String {
        guard let body = reader.bytes(node.body) else { return node.name }
        if node.name == "OA30", let key = GPNVRecord.productKey(of: body) {
            return "\(node.name) = \(key)"
        }
        let texts = GPNVRecord.texts(in: body).map(\.text)
        guard !texts.isEmpty else { return node.name }
        let shown = texts.prefix(gpnvRowTexts).joined(separator: ", ")
        return "\(node.name) = " + (texts.count > gpnvRowTexts ? shown + ", …" : shown)
    }

    /// How many of a record's texts its row spells out.
    static let gpnvRowTexts = 3

    /// `name = value`, the value read as its type. A value too long to be
    /// one of the types a row spells out is not read: a row is drawn on every
    /// scroll.
    private static func valueRow(_ name: String, guid: EFIGUID?, attributes: UInt32,
                                 value range: Range<UInt64>, reader: ImageReader) -> String {
        guard range.count <= valueRowReadLimit, let value = reader.bytes(range) else {
            return L("%1$@ (%2$@ bytes)", name, "\(range.count)")
        }
        let read = NvramValue.read(name: name, guid: guid, attributes: attributes, value: value)
        return NvramValueText.row(name, read, bytes: value)
    }

    /// An NVAR entry's attributes in the VSS bits `NvramValue` reads: its
    /// own byte keeps the hardware error record flag at `0x20`.
    static func nvarAttributes(_ node: UEFINode, reader: ImageReader) -> UInt32 {
        guard let attributes = reader.uint8(at: node.header.lowerBound + 9) else { return 0 }
        return attributes & 0x20 != 0 ? 0x8 : 0
    }

    /// The longest value a variable's row reads: a signature database is the longest
    /// there is to read as a type, and a `dbx` grows to tens of KiB.
    static let valueRowReadLimit = 0x10000

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
        case .amdMicrocode: return "AMD microcode"
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
        case .hpSignatureBlock: return L("HP signature block")
        case .gpnvStore: return L("GPNV store")
        case .gpnvRecord: return L("GPNV record")
        case .lenovoDMIStore: return L("Lenovo DMI store")
        case .ldbgLog: return L("LDBG change log")
        case .ldbgEntry: return L("LDBG entry")
        case .lenvBlock: return L("LENV block")
        case .lenvEntry: return L("LENV entry")
        case .acerDMIStore: return L("Acer DMI")
        case .amdEFS: return L("Embedded Firmware Structure")
        case .amdDirectory: return L("AMD firmware directory")
        case .amdFirmwareEntry: return L("AMD firmware entry")
        case .biosGuardUpdate: return L("BIOS Guard update")
        case .biosGuardEntry: return L("BIOS Guard entry")
        case .picture: return L("Picture")
        case .sound: return L("Sound")
        }
    }
}
