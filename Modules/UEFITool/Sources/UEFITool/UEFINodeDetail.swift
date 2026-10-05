import Foundation
import Localization
import ToolModuleKit
import UEFIImage

/// One label/value row in the detail list.
public struct UEFIDetailField: Equatable, Sendable {
    public var label: String
    public var value: String
    /// What the value says, when it is a verdict: the view draws it bold and in
    /// the colour the tone names (`ToolValueTone`). `.standard` is ordinary
    /// text, which is what most fields are.
    public var tone: ToolValueTone

    /// A value that reads as a problem — a checksum that does not check out.
    /// A `.bad` tone is what that is, so this asks the tone rather than keeping
    /// a second flag that could disagree with it.
    public var isProblem: Bool { tone == .bad }

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
        self.tone = .standard
    }

    public init(_ label: String, _ value: String, tone: ToolValueTone) {
        self.label = label
        self.value = value
        self.tone = tone
    }

    public init(_ label: String, _ value: String, isProblem: Bool) {
        self.init(label, value, tone: isProblem ? .bad : .standard)
    }
}

/// A block of the detail that is a table rather than a row: a heading with an
/// icon, a header line, and cells under it.
///
/// Some of what a node says is a grid and reads as nonsense in a column of
/// label/value rows — which of five regions the BIOS master may read and write,
/// the flash chips a descriptor's VSCC table lists. The reference parser prints
/// those as fixed-width text inside one field; a panel can draw the table.
public struct UEFIDetailTable: Equatable, Sendable {
    /// A cell, and whether it is an answer worth colouring. A permission is the
    /// one thing here a bench reads by colour rather than by word.
    public struct Cell: Equatable, Sendable {
        public enum Tone: Equatable, Sendable { case plain, yes, no }
        public var text: String
        public var tone: Tone

        public init(_ text: String, tone: Tone = .plain) {
            self.text = text
            self.tone = tone
        }

        /// A permission, as the word and the colour that go with it.
        public static func permission(_ allowed: Bool) -> Cell {
            Cell(allowed ? L("Yes") : L("No"), tone: allowed ? .yes : .no)
        }
    }

    public var title: String
    /// The system symbol drawn before the heading.
    public var symbol: String
    public var columns: [String]
    public var rows: [[Cell]]

    /// Where a click on a row goes.
    public enum Target: Equatable, Sendable {
        /// A node: the click puts it in focus, its detail and its bytes.
        case node(NodeID)
        /// Bytes that are not one node — a region an Insyde map names, which
        /// can span several or lie inside one. The click outlines them in the
        /// dump under `name` and leaves the focus where it is.
        case range(Range<UInt64>, name: String)
    }

    /// What each row stands for, where a row stands for something: a click on
    /// the row goes there. Empty, or nil for a row, when it is text only.
    public var rowTargets: [Target?]
    /// The column a row with a target draws as a link: the one that says
    /// where the target is.
    public var linkColumn: Int

    public init(title: String, symbol: String, columns: [String], rows: [[Cell]],
                rowTargets: [Target?] = [], linkColumn: Int = 1) {
        self.title = title
        self.symbol = symbol
        self.columns = columns
        self.rows = rows
        self.rowTargets = rowTargets
        self.linkColumn = linkColumn
    }
}

/// What the panel says about the selected node, by its type
/// (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// Built in the pure target and tested by `swift test`, so the view controller
/// lays out what this says rather than deciding anything.
public struct UEFINodeDetail: Equatable, Sendable {
    /// The node's name, or its kind when the name is empty.
    public var title: String
    public var fields: [UEFIDetailField]
    /// The blocks that follow the rows. Empty for every node but a descriptor.
    public var tables: [UEFIDetailTable]
    /// The bytes of the picture the node is, for the panel to draw under the
    /// rows — nil for every node that is not one. Decoding them is the
    /// panel's: this target has no AppKit.
    public var picture: [UInt8]?

    public init(title: String, fields: [UEFIDetailField],
                tables: [UEFIDetailTable] = [], picture: [UInt8]? = nil) {
        self.title = title
        self.fields = fields
        self.tables = tables
        self.picture = picture
    }

    public static let empty = UEFINodeDetail(title: "", fields: [])
}

/// Reads the selected node's header and says what it is
/// (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// The fields come from the bytes, through the same `ImageReader` the parser
/// used: a field the header does not hold is absent, not guessed, and the name
/// tables are `UEFIImage`'s, not re-derived here.
public enum UEFIDetail {
    /// A raw section (type `0x19`): the only kind whose bytes are a text block
    /// rather than code that happens to contain the words.
    private static func isRawSection(_ node: UEFINode) -> Bool {
        node.kind == .section && node.subtype == 0x19
    }

    /// - Parameter repairs: the writes that would put this node's checksums
    ///   right (from the parse-time `UEFIChecksumCheck.repairs`), or [] when
    ///   they all check out. Each repair is the row's word on a wrong field: its
    ///   offset picks the checksum row it stands for, and its bytes are the
    ///   "should be" value the row quotes.
    public static func build(
        for node: UEFINode,
        image: UEFIImage,
        reader: ImageReader,
        repairs: [ChecksumRepair] = []
    ) -> UEFINodeDetail {
        var fields = commonFields(for: node, image: image)
        fields += headerFields(
            for: node, reader: reader, repairs: repairs,
            volumeErasePolarity: node.kind == .file
                ? UEFIChecksumCheck.volumeErasePolarity(of: node, in: image, reader: reader) : nil)
        if node.kind == .ecImage {
            fields += ecImageFields(node, image: image, reader: reader)
        }
        var tables: [UEFIDetailTable] = []
        if node.kind == .vssEntry, let variable = VSSVariable.read(node, in: image, reader: reader) {
            fields += vssFields(variable, reader: reader)
            // The value, read as its type — by the name the entry carries,
            // so a superseded copy reads as the variable it was.
            if let bytes = reader.bytes(variable.data) {
                let value = NvramValue.read(name: variable.decodedName(reader: reader) ?? "",
                                            guid: variable.vendorGuid, attributes: variable.attributes, value: bytes)
                fields += NvramValueText.fields(value, bytes: bytes)
                if let signatures = NvramValueText.signaturesTable(value) { tables.append(signatures) }
            }
        }
        // An NVAR entry's body is its value; a link's is one a later entry
        // replaced, and it reads as what it was.
        if node.kind == .nvarEntry, !node.name.isEmpty, let bytes = reader.bytes(node.body) {
            let value = NvramValue.read(name: node.name, guid: node.guid,
                                        attributes: UEFITreeDisplay.nvarAttributes(node, reader: reader), value: bytes)
            fields += NvramValueText.fields(value, bytes: bytes)
            if let signatures = NvramValueText.signaturesTable(value) { tables.append(signatures) }
        }
        if let topSwap = UEFITopSwap.detail(for: node, in: image) {
            fields.append(.init(L("Top Swap"), topSwap))
        }
        if let fill = NvramStoreFill.of(node, reader: reader) {
            fields += fillFields(fill)
        }
        let title = node.name.isEmpty ? kindLabel(node.kind) : node.name

        // What the BVDT's `$BME$` record lists, placed in the file.
        if node.kind == .flashDeviceMapRegion, node.guid == FlashDeviceMap.biosVersionDataTable,
           let table = InsydeBVDT.read(node.body, in: reader), !table.listedRanges.isEmpty {
            tables.append(listedRangesTable(table.listedRanges, near: node, in: image))
        }

        // Where the regions an Insyde map names lie in the file — the whole
        // map on its own row, one region on an entry's.
        if node.kind == .flashDeviceMapStore || node.kind == .flashDeviceMapEntry {
            let store = node.kind == .flashDeviceMapStore ? node
                : node.id.path.isEmpty ? nil : image.node(NodeID(Array(node.id.path.dropLast())))
            if let store {
                let entries = FlashDeviceMap.entries(of: store, reader: reader).filter {
                    node.kind == .flashDeviceMapStore || $0.offset == node.header.lowerBound
                }
                // The image's mapping, or — on an AMD board, whose flash
                // ends in no Volume Top File — the one the map states about
                // itself.
                let addressDiff = image.addressDiff
                    ?? (store.space == .file ? FlashDeviceMap.addressDiff(of: store, reader: reader) : nil)
                if !entries.isEmpty {
                    tables.append(mapRegionsTable(entries, addressDiff: addressDiff, in: image))
                }
            }
        }

        // A variable's entry: whose copy it is where the tree calls it
        // Invalid, and every copy the store keeps of it.
        if node.kind == .vssEntry || node.kind == .nvarEntry || node.kind == .dvarEntry,
           !node.id.path.isEmpty, let store = image.node(NodeID(Array(node.id.path.dropLast()))) {
            let history = NvramVariableHistory.of(node, in: store, reader: reader)
            let variable = history.map { ($0.name, $0.guid) }
                ?? NvramVariableHistory.variable(of: node, in: store, reader: reader)
            if let variable, variable.0 != node.name {
                // A Dell variable is a number, and only its namespace says whose.
                let text = node.kind == .dvarEntry
                    ? variable.1.map { "\($0) · \(variable.0)" } ?? variable.0
                    : variable.0
                fields.append(.init(L("Variable"), text))
            }
            if node.kind == .dvarEntry, let namespace = variable?.1, let nameId = variable?.0,
               let setting = image.dvarSettings?.setting(namespace: namespace, nameId: nameId) {
                fields += settingFields(setting, value: reader.bytes(node.body) ?? [])
            }
            if let history {
                tables.append(historyTable(history, focus: node.id, reader: reader))
            }
        }

        // Apple's device overrides are a bzip2 stream of text: the panel reads
        // it, so that a bench sees what the board is told it has.
        if node.kind == .sysFEntry, node.name == AppleOverrides.variableName,
           let overrides = AppleOverrides.read(reader.bytes(node.body) ?? []) {
            fields.append(.init(L("Rules"), "\(overrides.rules.count)"))
            tables.append(UEFIDetailTable(
                title: L("Device overrides"),
                symbol: "list.bullet.rectangle",
                columns: [L("Action"), L("Applies to"), L("Device or properties")],
                rows: overrides.rules.map {
                    [.init($0.action), .init($0.appliesTo.isEmpty ? L("Every device") : $0.appliesTo), .init($0.detail)]
                }
            ))
        }

        // The BIOS ID string, taken apart where it follows Intel's layout.
        if isRawSection(node), node.body.count <= AppleROMInformation.searchLimit,
           let id = BIOSIdentifier.read(reader.bytes(node.body) ?? []) {
            var rows: [[UEFIDetailTable.Cell]] = [[.init(L("BIOS ID")), .init(id.text)]]
            for (label, value) in [(L("Board"), id.board), (L("OEM"), id.oem), (L("Major version"), id.majorVersion),
                                   (L("Minor version"), id.minorVersion), (L("Build date"), id.buildDate)] {
                if let value { rows.append([.init(label), .init(value)]) }
            }
            tables.append(UEFIDetailTable(
                title: L("BIOS ID"), symbol: "number", columns: [L("Field"), L("Value")], rows: rows))
        }

        // The text block Apple's firmware carries about its own build, whether
        // it is a file of its own or left in the padding the BIOS region opens
        // with.
        if isRawSection(node) || node.kind == .padding, node.body.count <= AppleROMInformation.searchLimit,
           let info = AppleROMInformation.read(reader.bytes(node.body) ?? []) {
            tables.append(UEFIDetailTable(
                title: L("Apple ROM information"),
                symbol: "info.circle",
                columns: [L("Field"), L("Value")],
                rows: info.entries.map { [.init($0.key), .init($0.value)] }
            ))
        }

        // A descriptor says more about itself than a header's worth of fields,
        // and two of the things it says are grids.
        if node.kind == .flashDescriptor,
           let descriptor = DescriptorInfo.read(at: node.header.lowerBound, in: reader) {
            fields += descriptorFields(descriptor, imageSize: image.size)
            tables += descriptorTables(descriptor, imageSize: image.size)
        }

        // An update for more than one processor lists the others in a table
        // of its own, which reads as the grid it is.
        if node.kind == .microcode,
           let extended = MicrocodeHeader.read(at: node.header.lowerBound, in: reader)?.extendedTable,
           !extended.signatures.isEmpty {
            tables.append(UEFIDetailTable(
                title: L("Extended signatures"),
                symbol: "cpu",
                columns: [L("CPUID"), L("Processor"), L("Platforms"), L("Checksum")],
                rows: extended.signatures.map { signature in
                    [
                        .init(MicrocodeHeader.cpuid(signature.processorSignature)),
                        .init(MicrocodeHeader.processorText(signature.processorSignature)),
                        .init(MicrocodeHeader.platformsText(signature.platformIDs)),
                        .init(hex(signature.checksum))
                    ]
                }
            ))
        }

        if let ranges = image.protectedRanges {
            let touching = ranges.ranges(touching: node, in: image)
            if !touching.isEmpty {
                fields.append(.init(L("Protection"), protectionCaveat))
                tables.append(protectedByTable(touching))
            }
        }
        // A picture is shown as well as described. Only one the parser
        // recognised and measured: its bytes are exactly the picture's.
        let picture = node.kind == .picture ? reader.bytes(node.body) : nil
        return UEFINodeDetail(title: title, fields: fields, tables: tables, picture: picture)
    }

    // MARK: - A Dell DVAR entry

    /// What Setup says the variable is (`DellSetup`): the option as its page
    /// words it, its keyword, the page, what this copy's value means there,
    /// and the page's help for it. All the firmware's own English.
    private static func settingFields(_ setting: DellSetup.Setting, value: [UInt8]) -> [UEFIDetailField] {
        var fields: [UEFIDetailField] = [.init(L("Setup option"), setting.prompt)]
        if let keyword = setting.keyword { fields.append(.init(L("Keyword"), keyword)) }
        if let form = setting.form, form != setting.prompt { fields.append(.init(L("Setup page"), form)) }
        if !value.isEmpty, value.count <= 8 {
            let number = value.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            if let meaning = UEFITreeDisplay.dvarMeaning(number, setting: setting) {
                fields.append(.init(L("Value in Setup"), "\(meaning) (\(hex(number)))"))
            }
        }
        if let help = setting.help { fields.append(.init(L("Setup help"), help)) }
        return fields
    }

    /// The header the reference prints for a DVAR entry: the state by its
    /// name, the flags and type, the namespace id it is filed under, the name
    /// id and the data size.
    private static func dvarFields(_ node: UEFINode, reader: ImageReader) -> [UEFIDetailField] {
        let h = node.header.lowerBound
        guard let raw = reader.bytes(at: h, count: 5) else { return [] }
        let state = 0xFF - raw[0], flags = 0xFF - raw[1], type = 0xFF - raw[2]
        let stateNames: [UInt8: String] = [0x01: "Storing", 0x05: "Stored", 0x15: "Deleting", 0x55: "Deleted"]
        var fields: [UEFIDetailField] = [
            .init("State", stateNames[state].map { "\(hex(state)) (\($0))" } ?? hex(state)),
            .init("Entry flags", bits(flags, [(0x02, "NameId"), (0x04, "NamespaceGuid")])),
            .init("Type", hex(type)),
            .init("Attributes", hex(0xFF - raw[3])),
            .init("Namespace ID", hex(0xFF - raw[4])),
        ]
        // Past the namespace's GUID, when the entry declares one, the name id
        // and the data size, one or two bytes each by the type.
        var cursor = h + 5 + (flags & 0x04 != 0 ? 16 : 0)
        let wideName = type != 0x00, wideSize = type == 0x05
        if let nameId = wideName ? reader.uint16(at: cursor).map({ 0xFFFF - $0 })
                                 : reader.uint8(at: cursor).map({ UInt16(0xFF - $0) }) {
            fields.append(.init("Name ID", hex(nameId)))
        }
        cursor += wideName ? 2 : 1
        if let size = wideSize ? reader.uint16(at: cursor).map({ 0xFFFF - $0 })
                               : reader.uint8(at: cursor).map({ UInt16(0xFF - $0) }) {
            fields.append(.init("Data size", sizeText(size)))
        }
        return fields
    }

    // MARK: - A VSS variable

    /// The header a VSS variable's form carries (`VSSVariable`): the state by
    /// its name, the attributes, the sizes, and what the form adds — the
    /// authenticated form's count, time stamp and key index, Apple's data
    /// CRC, Intel's total size. The vendor GUID is the common "GUID" field.
    private static func vssFields(_ variable: VSSVariable, reader: ImageReader) -> [UEFIDetailField] {
        let states: [UInt8: String] = variable.form == .intelLegacy
            ? [0xFC: "Valid", 0xF8: "Invalid"]
            : [0x7F: "Header valid", 0x3F: "Added", 0x3E: "Added, in deleted transition",
               0x3D: "Deleted", 0x3C: "Deleted"]
        var fields: [UEFIDetailField] = [
            .init("State", states[variable.state].map { "\(hex(variable.state)) (\($0))" } ?? hex(variable.state)),
            .init("Reserved", hex(variable.reserved)),
            .init("Attributes", bits(variable.attributes, nvramAttributeBits)),
        ]
        if let total = variable.totalSize { fields.append(.init("Total size", sizeText(total))) }
        if let count = variable.monotonicCount { fields.append(.init("Monotonic count", "\(count)")) }
        if let timestamp = variable.timestamp {
            fields.append(.init("Timestamp", timestamp.isZero ? L("Not set") : timestamp.text ?? L("Not a date")))
        }
        if let index = variable.publicKeyIndex { fields.append(.init("Public key index", "\(index)")) }
        if let size = variable.nameSize { fields.append(.init("Name size", sizeText(size))) }
        if let size = variable.dataSize { fields.append(.init("Data size", sizeText(size))) }
        if let stored = variable.dataCRC32, let data = reader.bytes(variable.data) {
            let computed = Checksums.crc32(data)
            fields.append(UEFIDetailField(
                "Data CRC32",
                Checksums.text(stored, valid: computed == stored, expected: UInt64(computed), digits: 8),
                isProblem: computed != stored))
        }
        return fields
    }

    // MARK: - What a BIOS Version Data Table lists

    /// `$BME$`'s ranges, which are offsets into the BIOS region, as addresses
    /// in the file, and the node each one is exactly — the BVDT's own region,
    /// a volume — where one is. What the list is for is not known, so the
    /// table says where and not why. A click on a range in the file outlines
    /// it in the dump, named by what is there, as the map's table does.
    private static func listedRangesTable(_ ranges: [Range<UInt64>], near node: UEFINode, in image: UEFIImage) -> UEFIDetailTable {
        // A dump of the BIOS region alone starts with it.
        let bios = image.nodes(containing: node.range.lowerBound).first {
            $0.kind == .region && $0.subtype == UInt8(FlashRegionType.bios.rawValue)
        }?.range.lowerBound ?? 0
        var rows: [[UEFIDetailTable.Cell]] = []
        var targets: [UEFIDetailTable.Target?] = []
        for range in ranges {
            let placed = (bios + range.lowerBound)..<(bios + range.upperBound)
            let holder = image.allNodes.first { $0.space == .file && $0.range == placed && $0.kind != .region }
            rows.append([.init(hex(placed.lowerBound)), .init(sizeText(UInt64(range.count))),
                         .init(holder.map(holderText) ?? "—")])
            // An empty slot — `SPI_EF6018`'s second is a size of zero — and a
            // range past the end have nothing to outline.
            targets.append(!placed.isEmpty && placed.upperBound <= image.size
                ? .range(placed, name: holder.map(holderText) ?? "$BME$") : nil)
        }
        return UEFIDetailTable(
            title: L("Ranges listed in $BME$"),
            symbol: "list.bullet.rectangle",
            columns: [L("Start"), L("Size"), L("Holds")],
            rows: rows,
            rowTargets: targets,
            linkColumn: 0
        )
    }

    // MARK: - Where an Insyde map's regions are

    /// Each entry's region as the firmware addresses it and as the file holds
    /// it, with the node that is exactly that range where there is one. With
    /// no mapping known, only the address can be given.
    private static func mapRegionsTable(
        _ entries: [FlashDeviceMap.Entry], addressDiff: UInt64?, in image: UEFIImage
    ) -> UEFIDetailTable {
        var rows: [[UEFIDetailTable.Cell]] = []
        var targets: [UEFIDetailTable.Target?] = []
        for entry in entries {
            let type = FlashDeviceMap.regionTypeName(entry.type) ?? KnownGUIDs.name(of: entry.type) ?? entry.type.description
            let placed = addressDiff.flatMap { entry.range(addressDiff: $0) }
            let holder = placed.flatMap { range in
                image.allNodes.first { $0.space == .file && $0.range == range && $0.kind != .region }
            }
            rows.append([
                .init(type),
                .init(hex(entry.address)),
                .init(placed.map { hex($0.lowerBound) } ?? "—"),
                .init(sizeText(entry.size)),
                .init(holder.map(holderText) ?? "—"),
            ])
            // Only what lies in the file can be shown in it.
            targets.append(placed.flatMap {
                !$0.isEmpty && $0.upperBound <= image.size ? .range($0, name: type) : nil
            })
        }
        // A click on a region outlines its bytes in the dump: the way to see
        // where a region the tree does not cut out lies.
        return UEFIDetailTable(
            title: L("Regions of the flash device map"),
            symbol: "list.bullet.rectangle",
            columns: [L("Type"), L("Address"), L("Start"), L("Size"), L("Holds")],
            rows: rows,
            rowTargets: targets,
            linkColumn: 2
        )
    }

    /// A volume's name is its file system, which alone does not say it is
    /// one; anything else is named by what it is.
    private static func holderText(_ node: UEFINode) -> String {
        if node.kind == .volume { return kindLabel(.volume) + " " + node.name }
        return node.name.isEmpty ? kindLabel(node.kind) : node.name
    }

    /// Microsoft's compiler version, and the Visual Studio it shipped with.
    private static func compilerText(_ version: UInt16) -> String {
        let product: String?
        switch version {
        case 1400: product = "Visual Studio 2005"
        case 1500: product = "Visual Studio 2008"
        case 1600: product = "Visual Studio 2010"
        case 1700: product = "Visual Studio 2012"
        case 1800: product = "Visual Studio 2013"
        case 1900: product = "Visual Studio 2015"
        case 1910...1916: product = "Visual Studio 2017"
        case 1920...1929: product = "Visual Studio 2019"
        case 1930...1949: product = "Visual Studio 2022"
        default: product = nil
        }
        return product.map { "MSC \(version) (\($0))" } ?? "MSC \(version)"
    }

    // MARK: - A variable's copies

    /// The most copies the table lists. A variable written on every boot
    /// keeps hundreds; the latest are the ones worth reading.
    static let historyRows = 40

    /// Every copy the store keeps of the variable, oldest first: where it is,
    /// what it is now, how long its value is, and what it changed against the
    /// copy before. The entry in focus is marked. Past `historyRows` the
    /// earliest copies are left out, except the one in focus.
    static func historyTable(_ history: NvramVariableHistory, focus: NodeID, reader: ImageReader) -> UEFIDetailTable {
        let versions = history.versions
        let firstShown = max(0, versions.count - historyRows)
        var rows: [[UEFIDetailTable.Cell]] = []
        var targets: [UEFIDetailTable.Target?] = []
        if firstShown > 0 {
            if let focused = versions.firstIndex(where: { $0.entry == focus }), focused < firstShown {
                rows.append(historyRow(versions, focused, focus: focus, reader: reader))
                targets.append(.node(versions[focused].entry))
            }
            rows.append([.init("…"), .init(L("%1$@ earlier copies not shown", firstShown)),
                         .init(""), .init(""), .init("")])
            targets.append(nil)
        }
        for index in firstShown..<versions.count {
            rows.append(historyRow(versions, index, focus: focus, reader: reader))
            targets.append(.node(versions[index].entry))
        }
        // A click on a copy puts it in focus: its detail, and its bytes in the
        // dump — the way to a copy the tree leaves out.
        return UEFIDetailTable(
            title: L("Variable history"),
            symbol: "clock.arrow.circlepath",
            columns: [L("Copy", context: "variable"), L("Address", context: "variable"), L("State"),
                      L("Size"), L("Change")],
            rows: rows,
            rowTargets: targets
        )
    }

    private static func historyRow(
        _ versions: [NvramVariableHistory.Version], _ index: Int, focus: NodeID, reader: ImageReader
    ) -> [UEFIDetailTable.Cell] {
        let version = versions[index]
        let number = "\(index + 1)"
        let state: String
        switch version.state {
        case .current: state = L("Current")
        case .superseded: state = L("Superseded")
        case .deleted: state = L("Deleted", context: "variable")
        }
        let change = index == 0 ? "—"
            : NvramVariableHistory.change(from: versions[index - 1], to: version, reader: reader)
                .map(changeText) ?? "—"
        return [.init(version.entry == focus ? "▸ " + number : number),
                .init(hex(version.offset)), .init(state),
                .init("\(version.value.count)"), .init(change)]
    }

    /// What a copy changed: its size, if that moved, and where its bytes
    /// differ — offsets into the value, the first few runs of them.
    private static func changeText(_ change: NvramVariableHistory.Change) -> String {
        guard !change.isNone else { return L("No change") }
        var parts: [String] = []
        if change.oldSize != change.newSize {
            parts.append(L("size %1$@ → %2$@", change.oldSize, change.newSize))
        }
        if !change.changed.isEmpty {
            var runs = change.changed.prefix(4).map { run in
                run.count == 1 ? "+" + hex(run.lowerBound) : "+" + hex(run.lowerBound) + "–" + hex(run.upperBound - 1)
            }
            if change.changed.count > 4 { runs.append("…") }
            parts.append(L("changed bytes: %1$@, at %2$@", change.changedBytes, runs.joined(separator: ", ")))
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - How full a variable store is

    /// The panel's own reading of a store, so it translates: how much of it
    /// is written, how much is left, and what its entries still count for.
    static func fillFields(_ fill: NvramStoreFill) -> [UEFIDetailField] {
        [
            .init(L("In use"), "\(sizeText(fill.used)) · \(fill.percentUsed)\u{00A0}%"),
            .init(L("Free space"), sizeText(fill.free)),
            .init(L("Current entries"), "\(fill.current)"),
            .init(L("Superseded entries"), "\(fill.superseded)"),
            .init(L("Deleted entries"), "\(fill.deleted)"),
        ]
    }

    // MARK: - Protected ranges

    /// What the image cannot say (`BOOT_GUARD_PROTECTED_RANGES.md` §8): the
    /// Boot Guard profile is in the PCH's fuses, not in the BIOS region.
    public static let protectionCaveat =
        L("Whether Boot Guard is enforced is set in the chipset's fuses, not in this image: the marks say what an edit would break if it is. Vendor hashes are checked by the firmware itself.")

    /// Every range that shares a byte with the node: what it is, where it is,
    /// where the list naming it is, and what hashing it found (§9.3).
    static func protectedByTable(_ ranges: [ProtectedRange]) -> UEFIDetailTable {
        UEFIDetailTable(
            title: L("Protected by"),
            symbol: "lock.shield",
            columns: [L("Range"), L("Kind"), L("Listed at"), L("Hash")],
            rows: ranges.map { range in
                [
                    .init(range.range.map { "\(hex($0.lowerBound))–\(hex($0.upperBound))" } ?? L("Not placed")),
                    .init(range.kind.name),
                    .init(hex(range.source.lowerBound)),
                    verdictCell(range)
                ]
            }
        )
    }

    private static func verdictCell(_ range: ProtectedRange) -> UEFIDetailTable.Cell {
        let algorithms = range.digests.map(\.algorithmName).joined(separator: ", ")
        switch range.verdict {
        case .matches:
            return .init(L("%1$@ matches", algorithms), tone: .yes)
        case .mismatch:
            // An IBB mismatch is not a verdict yet (§6.1).
            return .init(range.kind.isIBB ? L("%1$@ differs (unconfirmed)", algorithms)
                                          : L("%1$@ differs", algorithms),
                         tone: .no)
        case .unsupported(let algorithm):
            return .init(L("%1$@ not computed", TCGHash.name(algorithm)))
        case .unchecked:
            return .init(L("Not checked"))
        }
    }

    // MARK: - The fields every node has

    private static func commonFields(for node: UEFINode, image: UEFIImage) -> [UEFIDetailField] {
        var fields: [UEFIDetailField] = []
        // These are this panel's own words for a node — how it is laid out and
        // what it is — and not fields of anything on disk, so they translate.
        // Everything `headerFields` adds below is read out of a structure and
        // keeps the spec's own name: a bench reads those beside the PI spec or
        // beside UEFITool, and a translated `Signature` cannot be looked up.
        fields.append(.init(L("Kind"), kindLabel(node.kind)))
        if node.subtype != nil {
            fields.append(.init(L("Type"), typeText(node)))
        }
        if let guid = node.guid {
            fields.append(.init("GUID", guidText(guid)))
        }
        // Inside a compressed section the ranges below are offsets into what it
        // decompresses to, and this says which section that is.
        if case .decompressed(let chain) = node.space, let outermost = chain.first {
            let section = image.innermostNode(containing: outermost)
                .flatMap { $0.header.lowerBound == outermost ? $0.name : nil }
                ?? L("Compressed section")
            var text = L("%1$@ at %2$@", section, hex(outermost))
            if chain.count > 1 { text = L("%1$@, %2$@ compressed sections deep", text, chain.count) }
            fields.append(.init(L("Decompressed from"), text))
        }
        fields.append(.init(L("Header"), rangeText(node.header)))
        fields.append(.init(L("Body"), rangeText(node.body)))
        if !node.tail.isEmpty {
            fields.append(.init(L("Tail"), rangeText(node.tail)))
        }
        fields.append(.init(L("Total"), rangeText(node.range)))

        var flags: [String] = []
        if node.isFixed { flags.append(L("fixed")) }
        if node.isCompressed { flags.append(L("compressed")) }
        if node.isErased { flags.append(L("erased")) }
        if !flags.isEmpty {
            fields.append(.init(L("Flags"), flags.joined(separator: ", ")))
        }

        // A compressed node's address means nothing — the decompressor puts it
        // wherever it likes — so the one thing worth showing is skipped there.
        if !node.isCompressed,
           let address = image.address(forOffset: node.range.lowerBound) {
            fields.append(.init(L("Address"), hex(address)))
        }
        return fields
    }

    // MARK: - What the node's header adds

    private static func headerFields(
        for node: UEFINode,
        reader: ImageReader,
        repairs: [ChecksumRepair],
        volumeErasePolarity: Bool?
    ) -> [UEFIDetailField] {
        let h = node.header.lowerBound
        var fields: [UEFIDetailField] = []
        switch node.kind {
        case .volume:
            if let length = reader.uint64(at: h + 0x20) { fields.append(.init("Length", sizeText(length))) }
            if let signature = reader.uint32(at: h + 0x28) { fields.append(.init("Signature", hex(signature))) }
            if let attributes = reader.uint32(at: h + 0x2C) {
                fields.append(.init("Attributes", bits(attributes, [(0x0000_0800, "Erase polarity")])))
            }
            if let headerLength = reader.uint16(at: h + 0x30) { fields.append(.init("Header length", sizeText(headerLength))) }
            let checksumOffset = h + 0x32
            if let checksum = reader.uint16(at: checksumOffset) {
                fields.append(checksumRow("Checksum", checksum, digits: 4, repairs: repairs, checksumOffset: checksumOffset))
            }
            if let extOffset = reader.uint16(at: h + 0x34) { fields.append(.init("Ext. header", hex(extOffset))) }
            if let revision = reader.uint8(at: h + 0x37) { fields.append(.init("Revision", "\(revision)")) }

        case .file:
            // The name GUID is the common "GUID" field and the type is the
            // common "Type" field; what the header adds is the rest.
            if let attributes = reader.uint8(at: h + 0x13) {
                fields.append(.init(
                    "Attributes",
                    bits(attributes, [(0x01, "Tail / large"), (0x04, "Fixed"), (0x40, "Checksum")])
                ))
            }
            // A large file keeps its size in a 64-bit field after the base
            // header and leaves the three-byte one at zero (§5.2).
            if let size = reader.uint24(at: h + 0x14), size != 0 {
                fields.append(.init("Size", sizeText(size)))
            } else if let largeSize = reader.uint64(at: h + 0x18) {
                fields.append(.init("Size", sizeText(largeSize)))
            }
            // A state that marks the header invalid says so, and the sums are
            // shown unchecked rather than valid: the file owes none (§5.5).
            let state = reader.uint8(at: h + 0x17)
            let markedInvalid = state.map {
                FileState.marksHeaderInvalid($0, volumeErasePolarity: volumeErasePolarity)
            } ?? false
            if let state {
                let text = bits(state, [(0x80, "Erase polarity")])
                fields.append(markedInvalid
                    ? .init("State", L("%1$@ — header marked invalid", text), tone: .caution)
                    : .init("State", text))
            }
            if let headerChecksum = reader.uint8(at: h + 0x10) {
                fields.append(markedInvalid
                    ? .init("Header checksum", L("%1$@ (not checked)", hex(headerChecksum)))
                    : checksumRow("Header checksum", headerChecksum, digits: 2, repairs: repairs, checksumOffset: h + 0x10))
            }
            if let bodyChecksum = reader.uint8(at: h + 0x11) {
                fields.append(markedInvalid
                    ? .init("Body checksum", L("%1$@ (not checked)", hex(bodyChecksum)))
                    : checksumRow("Body checksum", bodyChecksum, digits: 2, repairs: repairs, checksumOffset: h + 0x11))
            }

        case .section:
            // The type is the common "Type" field; the header adds the size.
            // An extended-size section leaves the three-byte field at the
            // marker and keeps the real one in 32 bits (§6).
            if let size = reader.uint24(at: h) {
                if size == 0xFF_FFFF, let extended = reader.uint32(at: h + 0x04) {
                    fields.append(.init("Size", sizeText(extended)))
                } else {
                    fields.append(.init("Size", sizeText(size)))
                }
            }

        case .microcode:
            // The header type and the loader revision are constants of a valid
            // Intel microcode, read straight off the bytes. The rest is the
            // reading the FIT panel gives the microcode an entry points at
            // (`MicrocodeHeader.fields`), so the two say it in the same words —
            // with the checksum's verdict this panel's own: the repairs.
            if let headerType = reader.uint32(at: h) { fields.append(.init("Header type", hex(headerType))) }
            if let header = MicrocodeHeader.read(at: h, in: reader) {
                if let loaderRevision = reader.uint32(at: h + 0x14) {
                    fields.append(.init("Loader revision", hex(loaderRevision)))
                }
                let repair = repairs.first { $0.offset == h + 0x10 }
                fields += header.fields(
                    checksumIsCorrect: repair == nil,
                    expectedChecksum: repair.map { UInt32(truncatingIfNeeded: littleEndian($0.bytes)) }
                ).map { UEFIDetailField($0.label, $0.value, isProblem: $0.isProblem) }
            }

        case .capsule:
            // The capsule GUID is the common "GUID" field.
            if let headerSize = reader.uint32(at: h + 0x10) { fields.append(.init("Header size", sizeText(headerSize))) }
            if let flags = reader.uint32(at: h + 0x14) { fields.append(.init("Flags", hex(flags))) }
            if let imageSize = reader.uint32(at: h + 0x18) { fields.append(.init("Image size", sizeText(imageSize))) }

        case .uefiImage:
            // An empty header and nothing of its own to read: the wrapper's
            // only contribution is its common geometry fields.
            break

        case .intelImage:
            // The image node is the whole file, and its bytes are the flash
            // descriptor that maps it. The header of the descriptor carries the
            // map (FLMAP0-2, at `0x14`) whose counters say how many chips,
            // regions, masters and strap dwords the board has — the block the
            // reference parser prints on its "Intel image" root. The first
            // three are stored minus one; the two strap counts are not (§2.1).
            if let map0 = reader.uint32(at: h + 0x14) {
                fields.append(.init("Flash chips", "\(((map0 >> 8) & 0x3) + 1)"))
                fields.append(.init("Regions", "\(((map0 >> 24) & 0x7) + 1)"))
            }
            if let map1 = reader.uint32(at: h + 0x18) {
                fields.append(.init("Masters", "\(((map1 >> 8) & 0x3) + 1)"))
                fields.append(.init("PCH straps", "\((map1 >> 24) & 0xFF)"))
            }
            if let map2 = reader.uint32(at: h + 0x1C) {
                fields.append(.init("PROC straps", "\((map2 >> 8) & 0xFF)"))
            }

        case .flashDescriptor:
            if let signature = reader.uint32(at: h + 0x10) { fields.append(.init("Signature", hex(signature))) }
            if let map = reader.uint32(at: h + 0x14) { fields.append(.init("FLMAP", hex(map))) }
            if let version = reader.uint32(at: h + 0x20) { fields.append(.init("Version", hex(version))) }

        case .region:
            // The descriptor's table keeps base and limit in 4 KiB units; the
            // type is the common "Type" field.
            fields.append(.init("Base (4 KiB)", hex(node.range.lowerBound >> 12)))
            if node.range.upperBound > 0 {
                fields.append(.init("Limit (4 KiB)", hex((node.range.upperBound - 1) >> 12)))
            }

        case .vssStore:
            // A VSS store's header is a signature and size, then the format,
            // state and two reserved words that describe the store (§9).
            if let format = reader.uint8(at: h + 8) { fields.append(.init("Format", hex(format))) }
            if let state = reader.uint8(at: h + 9) { fields.append(.init("State", hex(state))) }
            if let reserved = reader.uint16(at: h + 10) { fields.append(.init("Reserved", hex(reserved))) }
            if let reserved1 = reader.uint32(at: h + 12) { fields.append(.init("Reserved1", hex(reserved1))) }

        case .vss2Store:
            // A VSS2 store is the same four fields, after its 16-byte store
            // GUID and size (§9).
            if let format = reader.uint8(at: h + 20) { fields.append(.init("Format", hex(format))) }
            if let state = reader.uint8(at: h + 21) { fields.append(.init("State", hex(state))) }
            if let reserved = reader.uint16(at: h + 22) { fields.append(.init("Reserved", hex(reserved))) }
            if let reserved1 = reader.uint32(at: h + 24) { fields.append(.init("Reserved1", hex(reserved1))) }

        case .ftwStore:
            // An FTW working block checks its own header CRC32, which lives
            // next to the state byte (§9).
            if let state = reader.uint8(at: h + 20) { fields.append(.init("State", hex(state))) }
            if let crc = reader.uint32(at: h + 16) { fields.append(.init("Header CRC32", hex(crc))) }

        case .sysFStore:
            // A SysF store's header holds two unknown fields after the
            // signature; the CRC32 over the whole store is its last four bytes.
            if let unknown = reader.uint8(at: h + 4) { fields.append(.init("Unknown", hex(unknown))) }
            if let unknown1 = reader.uint32(at: h + 5) { fields.append(.init("Unknown1", hex(unknown1))) }
            // The store's CRC32 is its final four bytes, over everything before
            // them — which is where the reference parser reads it.
            if node.range.upperBound >= h + 4,
               let stored = reader.uint32(at: node.range.upperBound - 4),
               let bytes = reader.bytes(at: h, count: node.range.upperBound - 4 - h) {
                let computed = Checksums.crc32(bytes)
                fields.append(.init(
                    "CRC32",
                    Checksums.text(stored, valid: computed == stored, expected: UInt64(computed), digits: 8)
                ))
            }

        case .flashDeviceMapStore:
            // `INSYDE_FLASH_DEVICE_MAP_HEADER` (BOOT_GUARD_PROTECTED_RANGES.md §5.3).
            if let size = reader.uint32(at: h + 4) { fields.append(.init("Size", sizeText(size))) }
            if let dataOffset = reader.uint32(at: h + 8) { fields.append(.init("Data offset", hex(dataOffset))) }
            if let entrySize = reader.uint32(at: h + 12) { fields.append(.init("Entry size", sizeText(entrySize))) }
            if let format = reader.uint8(at: h + 16) { fields.append(.init("Entry format", hex(format))) }
            if let revision = reader.uint8(at: h + 17) { fields.append(.init("Revision", hex(revision))) }
            if let extensions = reader.uint8(at: h + 18) { fields.append(.init("Extensions", "\(extensions)")) }
            if let checksum = reader.uint8(at: h + 19), let header = reader.bytes(at: h, count: 0x1C) {
                let expected = 0 &- (Checksums.sum8(header) &- checksum)
                fields.append(.init("Checksum", expected == checksum ? "\(hex(checksum)), valid" : "\(hex(checksum)), should be \(hex(expected))"))
            }
            if let base = reader.uint64(at: h + 20) { fields.append(.init("Flash device base address", hex(base))) }

        case .flashDeviceMapEntry:
            // The region type GUID is the common "GUID" field.
            if let regionID = reader.bytes(at: h + 16, count: 16) {
                fields.append(.init("Region ID", regionID.map { String(format: "%02X", $0) }.joined()))
            }
            if let offset = reader.uint64(at: h + 32) { fields.append(.init("Region offset", hex(offset))) }
            if let size = reader.uint64(at: h + 40) { fields.append(.init("Region size", hex(size))) }
            if let attributes = reader.uint32(at: h + 48) {
                var words: [String] = []
                if attributes & 0x1 != 0 { words.append("modifiable") }
                if attributes & 0x2 != 0 { words.append("ignored") }
                fields.append(.init("Attributes", words.isEmpty ? hex(attributes) : "\(hex(attributes)) (\(words.joined(separator: ", ")))"))
            }
            if let hash = reader.bytes(at: h + 52, count: 32) {
                fields.append(.init("Hash", hash.map { String(format: "%02X", $0) }.joined()))
            }

        case .flashMapStore:
            // A Phoenix flash map names its regions in an entry count and a
            // reserved dword before the entries themselves (§9).
            if let entries = reader.uint16(at: h + 10) { fields.append(.init("Entries", "\(entries)")) }
            if let reserved = reader.uint32(at: h + 12) { fields.append(.init("Reserved", hex(reserved))) }

        case .flashMapEntry:
            // The region GUID is the common "GUID" field; the header adds the
            // data and entry types and the region's physical layout.
            if let dataType = reader.uint16(at: h + 16) { fields.append(.init("Data type", hex(dataType))) }
            if let entryType = reader.uint16(at: h + 18) { fields.append(.init("Entry type", hex(entryType))) }
            if let size = reader.uint32(at: h + 28) { fields.append(.init("Size", sizeText(size))) }
            if let offset = reader.uint32(at: h + 32) { fields.append(.init("Offset", hex(offset))) }
            if let address = reader.uint64(at: h + 20) { fields.append(.init("Physical address", hex(address))) }

        case .evsaStore:
            // An EVSA store is itself an entry, type 0xEC: attributes, a
            // reserved word, and a checksum that covers its 20-byte header.
            if let attributes = reader.uint32(at: h + 8) { fields.append(.init("Attributes", hex(attributes))) }
            if let reserved = reader.uint32(at: h + 16) { fields.append(.init("Reserved", hex(reserved))) }
            if let checksum = evsaChecksum(storedAt: h + 1, covering: node.header.upperBound, reader: reader) {
                fields.append(.init(
                    "Checksum",
                    Checksums.text(checksum.value, valid: checksum.valid, expected: checksum.expected.map(UInt64.init))
                ))
            }

        // Read in `build`, which knows the store and so the header's form.
        case .vssEntry:
            break

        case .evsaEntry:
            // What the header adds depends on the entry's kind: a GUID entry
            // and a name entry carry one id word each, a data entry carries
            // both plus an attributes word. The GUID a guid entry names is the
            // common "GUID" field; the name a name entry carries is its own.
            switch node.subtype {
            case UEFITypes.Sub.guidEvsaEntry:
                if let guidId = reader.uint16(at: h + 4) { fields.append(.init("GuidId", hex(guidId))) }
            case UEFITypes.Sub.nameEvsaEntry:
                if let varId = reader.uint16(at: h + 4) { fields.append(.init("VarId", hex(varId))) }
            default:
                // A data variable, valid or not.
                if let varId = reader.uint16(at: h + 6) { fields.append(.init("VarId", hex(varId))) }
                if let guidId = reader.uint16(at: h + 4) { fields.append(.init("GuidId", hex(guidId))) }
                if let attributes = reader.uint32(at: h + 8) {
                    fields.append(.init("Attributes", bits(attributes, evsaAttributeBits)))
                }
            }
            if let checksum = evsaChecksum(storedAt: h + 1, covering: node.range.upperBound, reader: reader) {
                fields.append(.init(
                    "Checksum",
                    Checksums.text(checksum.value, valid: checksum.valid, expected: checksum.expected.map(UInt64.init))
                ))
            }

        case .slicData:
            // A pubkey and a marker share their first eight bytes; what the
            // header adds after that differs (§9).
            switch node.subtype {
            case UEFITypes.Sub.pubkeySlicData:
                if let keyType = reader.uint8(at: h + 8) { fields.append(.init("Key type", hex(keyType))) }
                if let version = reader.uint8(at: h + 9) { fields.append(.init("Version", hex(version))) }
                if let algorithm = reader.uint32(at: h + 12) { fields.append(.init("Algorithm", hex(algorithm))) }
                if let bitLength = reader.uint32(at: h + 20) { fields.append(.init("Bit length", hex(bitLength))) }
                if let exponent = reader.uint32(at: h + 24) { fields.append(.init("Exponent", hex(exponent))) }
            case UEFITypes.Sub.markerSlicData:
                if let version = reader.uint32(at: h + 8) { fields.append(.init("Version", hex(version))) }
                if let oemID = reader.bytes(at: h + 12, count: 6) { fields.append(.init("OEM ID", asciiText(oemID))) }
                if let oemTableID = reader.bytes(at: h + 18, count: 8) { fields.append(.init("OEM table ID", asciiText(oemTableID))) }
                // The parser only accepts a marker whose windows flag is the
                // known value, so the reference's word for it is the value, and
                // anything else is shown as the raw number.
                if let windowsFlag = reader.uint64(at: h + 26) {
                    let value = windowsFlag == 0x2053_574F_444E_4957 ? "WINDOWS" : hex(windowsFlag)
                    fields.append(.init("Windows flag", value))
                }
                if let slicVersion = reader.uint32(at: h + 34) { fields.append(.init("SLIC version", hex(slicVersion))) }
            default: break
            }

        case .nvarEntry:
            fields += nvarFields(node, reader: reader)

        case .nvarGuidStore:
            fields.append(.init("GUIDs", "\(node.body.count / 16)"))

        // Every DVAR field is stored as its complement; these are the values.
        case .dvarStore:
            if let flags = reader.uint8(at: h + 8) { fields.append(.init("Store flags", hex(0xFF - flags))) }

        case .dvarEntry:
            fields += dvarFields(node, reader: reader)

        // FDC and CMDB stores, and a SysF variable, are read as leaves in the
        // reference: the panel has nothing to add to their common fields.
        case .fdcStore, .cmdbStore, .sysFEntry:
            break

        // A map region has no header: the map says where it is and what type
        // it is, and the type is the common "GUID" field. What the region
        // holds is read where its type is understood.
        case .flashDeviceMapRegion:
            if node.guid == FlashDeviceMap.biosVersionDataTable,
               let table = InsydeBVDT.read(node.body, in: reader) {
                if let version = table.biosVersion { fields.append(.init("BIOS version", version)) }
                if let product = table.productName { fields.append(.init("Product name", product)) }
                if let kernel = table.kernelVersion { fields.append(.init("Kernel version", kernel)) }
                if let date = table.releaseDate { fields.append(.init("Release date", date)) }
                if let compiler = table.compilerVersion { fields.append(.init("Compiler", compilerText(compiler))) }
                // The board's identity to a capsule update, and the version
                // it would be compared with.
                if let esrtClass = table.esrtClass { fields.append(.init("ESRT firmware class", esrtClass.description)) }
                if let esrtVersion = table.esrtVersion { fields.append(.init("ESRT version", hex(esrtVersion))) }
            }
            if node.guid == FlashDeviceMap.ecFirmware, !node.children.contains(where: { $0.kind == .ecImage }) {
                fields += iteFields(node, reader: reader)
            }

        case .padding where ECImage.isECFirmwarePadding(node):
            // With a row per image, the rows say it.
            if !node.children.contains(where: { $0.kind == .ecImage }) {
                fields += iteFields(node, reader: reader)
            }

        // Read in `build`, which has the block the image sits in.
        case .ecImage:
            break

        // What UEFITool's FIT tab says of the structure, in the header's own
        // words: the fields are Intel's names, and stay in them.
        case .fitComponent:
            guard let kind = node.subtype.flatMap(FITComponent.Kind.init(rawValue:)),
                  let header = FITComponentHeader.read(kind, at: node.body.lowerBound, in: reader)
            else { break }
            switch header {
            case .table(let rows):
                fields.append(.init("Entries", "\(rows)"))
            case .acm(let subtype, let headerVersion, let chipsetID, let date, let svn):
                fields.append(.init("Module subtype", FITComponentHeader.acmSubtypeName(subtype) ?? hex(subtype)))
                fields.append(.init("Header version", hex(headerVersion)))
                fields.append(.init("Chipset ID", hex(chipsetID)))
                fields.append(.init(L("Date"), date))
                fields.append(.init("ACM SVN", "\(svn)"))
            case .keyManifest(let version, let kmVersion, let svn, let id):
                fields.append(.init("Version", hex(version)))
                fields.append(.init("KM version", hex(kmVersion)))
                fields.append(.init("KM SVN", "\(svn)"))
                fields.append(.init("KM ID", hex(id)))
            case .bootPolicy(let version, let revision, let svn, let acmSVN):
                fields.append(.init("Version", hex(version)))
                fields.append(.init("BPM revision", "\(revision)"))
                fields.append(.init("BP SVN", "\(svn)"))
                fields.append(.init("ACM SVN", "\(acmSVN)"))
            }

        // Read again: the node keeps only its name.
        case .picture:
            if let picture = Picture.read(at: node.body.lowerBound, limit: node.body.upperBound, in: reader,
                                          allowingTruncation: true) {
                fields.append(.init(L("Format"), picture.variant.map { "\(picture.format.name) (\($0))" }
                                    ?? picture.format.name))
                fields.append(.init(L("Picture size"), "\(picture.width) × \(picture.height)"))
                // A BMP whose header asks for more than its section holds:
                // the rows past the end are missing from the image.
                if let declared = picture.declaredLength {
                    fields.append(.init(L("Declared size"), L("%1$@ — the section ends earlier", sizeText(declared)),
                                        isProblem: true))
                }
            }

        case .padding, .freeSpace, .nonUEFIData, .startupApData:
            // No header of their own: the size the common "Total" carries is
            // the whole of what there is to say.
            break
        }
        return fields
    }

    /// What an EC image row adds: who made it, what it says it is, how long
    /// it is, and which earlier image in the block it copies. Read again from
    /// the block the image sits in, since a copy is told by the images before
    /// it.
    private static func ecImageFields(_ node: UEFINode, image: UEFIImage, reader: ImageReader) -> [UEFIDetailField] {
        let block = node.id.path.isEmpty ? nil : image.node(NodeID(Array(node.id.path.dropLast())))
        guard let block,
              let found = ECImage.all(in: block.body, reader: reader).first(where: { $0.start == node.range.lowerBound })
        else { return [] }
        var fields: [UEFIDetailField] = []
        switch found.vendor {
        case .ite(let identification):
            fields.append(.init(L("Vendor"), "ITE"))
            fields.append(.init("ITE identification", identification))
        case .phcm:
            // Microchip's format, which says nothing of whose chip it is:
            // the format is named, the vendor is not.
            fields.append(.init(L("Format"), "PHCM (Microchip MEC)"))
        }
        fields.append(.init(L("Written"), sizeText(found.written)))
        if let original = found.copyOf {
            fields.append(.init(L("Copy of"), hex(original)))
        }
        return fields
    }

    /// One row per ITE image in the node: what it says it is, and where it
    /// starts. The firmware's own words, so they read as written.
    private static func iteFields(_ node: UEFINode, reader: ImageReader) -> [UEFIDetailField] {
        ITEFirmware.all(in: node.range, reader: reader).map {
            .init("ITE identification", "\($0.identification) · \(hex($0.start))")
        }
    }

    // MARK: - What a flash descriptor adds

    /// The rows a descriptor has beyond its header: the vector it opens with,
    /// the chipset its layout is, what the straps say where they are read —
    /// the bit that soft-disables the ME, the GPR0 range, the eSPI clock — and
    /// what its component section says about
    /// the chips — how large, how fast, and which opcodes the chipset will not
    /// send them. Where the regions lie, and what the masters may touch, are
    /// grids, and are in `descriptorTables`.
    private static func descriptorFields(_ descriptor: DescriptorInfo, imageSize: UInt64) -> [UEFIDetailField] {
        var fields: [UEFIDetailField] = []
        if !descriptor.reservedVector.isEmpty {
            fields.append(.init("Reserved vector", hexBytes(descriptor.reservedVector)))
        }
        // Told from the layout, not stated; a layout the rules do not know is
        // read as the nearest one, and says so.
        let generation = descriptor.generation
        var chipset = generation.series.map { L("%1$@ (%2$@ series)", generation.codeName, $0) }
            ?? generation.codeName
        if !descriptor.isGenerationCertain { chipset = L("%1$@, assumed", chipset) }
        fields.append(.init(L("Chipset"), chipset))
        // The one strap bit with a settled meaning. Set, it is the reason an
        // ME that is otherwise whole does not run, so it reads as a state.
        if let meDisable = descriptor.straps?.meDisable {
            fields.append(.init(L("%1$@ bit", meDisable.name),
                                meDisable.isSet ? L("Set — the ME is soft-disabled") : L("Not set", context: "bit"),
                                tone: meDisable.isSet ? .caution : .standard))
        }
        // A range the chipset keeps the host from writing — coreboot puts
        // the ME region under it — is the other reason a region the masks
        // open cannot be written from the OS.
        if let range = descriptor.straps?.gpr0 {
            fields.append(.init("GPR0", gpr0Text(range), tone: range.isOn ? .caution : .standard))
        }

        if let component = descriptor.component {
            fields += componentFields(component, imageSize: imageSize)
        }
        if let espi = descriptor.straps?.espiClock {
            fields.append(.init(L("eSPI clock"), espi.clock.megahertz.map {
                L("%1$@ MHz", $0.map(String.init).joined(separator: "/"))
            } ?? L("Unknown (code %1$@)", espi.clock.code)))
        }
        return fields
    }

    /// What the component section says about the chips.
    private static func componentFields(
        _ component: DescriptorInfo.Component, imageSize: UInt64
    ) -> [UEFIDetailField] {
        var fields: [UEFIDetailField] = []
        // The chips the image was laid out across, end to end. A dump of
        // another length is one chip of two, or a read of the wrong size.
        let sizes = component.chipSizes.map { $0.map(capacityText) ?? L("Reserved") }
            .joined(separator: " + ")
        let total = component.chipSizes.reduce(UInt64(0)) { $0 + ($1 ?? 0) }
        let mismatch = !component.chipSizes.contains(nil) && total != imageSize
        fields.append(.init(L("Flash chip sizes"),
                            mismatch ? L("%1$@ — the dump is %2$@", sizes, capacityText(imageSize)) : sizes,
                            isProblem: mismatch))
        if component.chipSizes.count == 2, let first = component.chipSizes[0] {
            fields.append(.init(L("Second chip starts at"), hex(first)))
        }
        fields.append(.init(L("Read ID and status clock"), clockText(component.readIDClock)))
        fields.append(.init(L("Write and erase clock"), clockText(component.writeEraseClock)))
        fields.append(.init(L("Fast read clock"), component.fastReadClock.map(clockText) ?? L("Off")))
        fields.append(.init(L("Forbidden opcodes"), component.invalidInstructions.isEmpty
                            ? L("None") : hexBytes(component.invalidInstructions)))
        return fields
    }

    /// A protected range as where it runs and what it refuses.
    private static func gpr0Text(_ range: DescriptorInfo.ProtectedRange) -> String {
        let span = "\(hex(range.start)) – \(hex(range.end))"
        switch (range.readProtected, range.writeProtected) {
        case (true, true): return L("%1$@: reads and writes refused", span)
        case (false, true): return L("%1$@: writes refused", span)
        case (true, false): return L("%1$@: reads refused", span)
        case (false, false): return L("Off")
        }
    }

    /// A clock as the bench says it, or the code when the generation reserves
    /// it.
    private static func clockText(_ clock: DescriptorInfo.Clock) -> String {
        guard let megahertz = clock.megahertz else { return L("Reserved (code %1$@)", clock.code) }
        return L("%1$@ MHz", megahertz.map(String.init).joined(separator: "/"))
    }

    /// A chip's size in the unit it is sold by.
    private static func capacityText(_ bytes: UInt64) -> String {
        if bytes > 0, bytes % 0x10_0000 == 0 { return L("%1$@ MB", bytes >> 20) }
        if bytes > 0, bytes % 0x400 == 0 { return L("%1$@ KB", bytes >> 10) }
        return sizeText(bytes)
    }

    /// The five grids: where each region lies, the masks each master carries,
    /// what the BIOS master may do to each region, the flash chips this
    /// firmware was built to drive, and the PCH strap words.
    ///
    /// The regions are in the tree as well, as this node's siblings — but the
    /// tree shows where a region *is*, and this shows what the descriptor
    /// *says*, which is the thing being checked when the two disagree.
    private static func descriptorTables(_ descriptor: DescriptorInfo, imageSize: UInt64) -> [UEFIDetailTable] {
        var tables: [UEFIDetailTable] = []
        // Its own region is this node.
        let regions = descriptor.regions.filter { $0.type != .descriptor }
        if !regions.isEmpty {
            tables.append(UEFIDetailTable(
                title: L("Region table"),
                symbol: "square.split.2x2",
                columns: [L("Region"), L("Base"), L("Limit")],
                rows: regions.map { [.init($0.type.label), .init(hex($0.base)), .init(hex($0.limit))] }
            ))
        }
        if !descriptor.masters.isEmpty {
            tables.append(UEFIDetailTable(
                title: L("Region access settings"),
                symbol: "key",
                columns: [L("Master"), L("Read"), L("Write")],
                rows: descriptor.masters.map { master in
                    [.init(master.name),
                     .init(mask(master.read, digits: descriptor.maskDigits)),
                     .init(mask(master.write, digits: descriptor.maskDigits))]
                }
            ))
        }
        if !descriptor.biosAccess.isEmpty {
            tables.append(UEFIDetailTable(
                title: L("BIOS access table"),
                symbol: "lock.shield",
                columns: [L("Region"), L("Read"), L("Write")],
                rows: descriptor.biosAccess.map { access in
                    [.init(access.region),
                     .permission(access.read),
                     .permission(access.write)]
                }
            ))
        }
        if !descriptor.chips.isEmpty {
            tables.append(UEFIDetailTable(
                title: L("Flash chips in VSCC table"),
                // The square chip the ME panel waits under, so the two panels
                // draw the same thing for the same idea.
                symbol: "cpu",
                columns: [L("JEDEC ID"), L("Chip"), L("Size"), L("Source")],
                rows: descriptor.chips.map { chip in
                    // With one chip the dump is that chip's, so a smaller chip
                    // cannot be the one it came from. With several the split is
                    // the descriptor's, and a chip smaller than the smallest of
                    // them cannot stand in for any of them.
                    let bytes = chip.sizeKB.map { UInt64($0) << 10 }
                    let declared = descriptor.component?.chipSizes ?? []
                    let smallest: UInt64? = declared.count == 1
                        ? imageSize : declared.compactMap { $0 }.min()
                    var invalid = false
                    if let bytes, let smallest { invalid = bytes < smallest }
                    return [.init(String(format: "%06X", chip.jedecID)),
                     .init(chip.name ?? chip.vendor.map { L("Unknown (%1$@)", $0) } ?? L("Unknown")),
                     .init(bytes.map(capacityText) ?? "", tone: invalid ? .no : .plain),
                     // Names of the projects the table was read from, as they
                     // call themselves, in every language.
                     .init(chip.source.map { source in
                         switch source {
                         case .uefiTool: return "UEFITool"
                         case .linux: return "Linux"
                         case .flashrom: return "flashrom"
                         }
                     } ?? "")]
                }
            ))
        }
        if let straps = descriptor.straps {
            // Numbers, not fields: the layout is the chipset's and next to
            // none of it is published (`UEFI_IMAGE_FORMAT.md` §2.6). Each row
            // outlines its four bytes in the dump, which is where two boards'
            // straps are compared.
            let rows = straps.words.indices.map { index -> (cells: [UEFIDetailTable.Cell], target: UEFIDetailTable.Target) in
                let name = "PCHSTRP\(index)"
                let address = straps.base + UInt64(index) * 4
                var meaning = L("Unknown")
                if let bit = straps.meDisable, bit.word == index {
                    meaning = L("%1$@ in bit %2$@; the other bits unknown", bit.name, bit.bit)
                } else if straps.espiClock?.word == index {
                    meaning = L("eSPI clock in bits 3–5; the other bits unknown")
                } else if straps.gpr0?.word == index {
                    meaning = L("GPR0, the whole word")
                }
                return ([.init(name), .init(hex(address)),
                         .init(String(format: "0x%08X", straps.words[index])), .init(meaning)],
                        .range(address..<address + 4, name: name))
            }
            tables.append(UEFIDetailTable(
                title: L("PCH straps"),
                symbol: "slider.horizontal.3",
                columns: [L("Strap"), L("Offset"), L("Value"), L("Meaning")],
                rows: rows.map(\.cells),
                rowTargets: rows.map(\.target),
                linkColumn: 1
            ))
        }
        return tables
    }

    /// A mask as the descriptor writes it: a byte on an old one, twelve bits on
    /// a new one, and the width is the difference a reader can see.
    private static func mask(_ value: UInt32, digits: Int) -> String {
        "0x" + String(format: "%0\(digits)X", value)
    }

    /// Bytes as a dump prints them, so a vector can be read against the hex.
    private static func hexBytes(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - NVRAM header helpers

    /// The VSS variable attribute bits an entry can set, in the reference
    /// parser's order and wording. The word is the bit's meaning, not a guess:
    /// bit 31 is the Apple data-checksum flag.
    private static let nvramAttributeBits: [(UInt32, String)] = [
        (0x0000_0001, "NonVolatile"),
        (0x0000_0002, "BootService"),
        (0x0000_0004, "Runtime"),
        (0x0000_0008, "HwErrorRecord"),
        (0x0000_0010, "AuthWrite"),
        (0x0000_0020, "TimeBasedAuthWrite"),
        (0x0000_0040, "AppendWrite"),
        (0x8000_0000, "AppleChecksum"),
    ]

    /// What an NVAR entry's header and extended header say (§9). The GUID is
    /// the common "GUID" field — the parser found it, in the entry or in the
    /// store's table, or took it from the chain for a later link.
    private static func nvarFields(_ node: UEFINode, reader: ImageReader) -> [UEFIDetailField] {
        let h = node.header.lowerBound
        var fields: [UEFIDetailField] = []
        guard let attributes = reader.uint8(at: h + 9) else { return fields }
        fields.append(.init("Attributes", bits(attributes, nvarAttributeBits)))
        // `next` is relative to the entry; the row says where it lands.
        if let next = reader.uint24(at: h + 6), next != 0xFF_FFFF {
            fields.append(.init("Next entry", hex(h + UInt64(next))))
        }
        // An entry that names its GUID by index carries the index right
        // after the header — on a valid entry that is not a later link.
        if attributes & 0x80 != 0, attributes & 0x08 == 0, attributes & 0x04 == 0,
           let index = reader.uint8(at: h + 10) {
            fields.append(.init("GUID index", "\(index)"))
        }

        // The extended header is the entry's tail: its attributes first, then
        // a timestamp and a hash when the variable is time-authenticated, and
        // the checksum and the header's own size last.
        let tail = node.tail
        guard tail.count >= 3, let extended = reader.uint8(at: tail.lowerBound) else { return fields }
        fields.append(.init("Extended attributes", bits(extended, nvarExtendedAttributeBits)))
        if extended & 0x20 != 0, tail.count >= 1 + 8 + 2,
           let timestamp = reader.uint64(at: tail.lowerBound + 1) {
            fields.append(.init("Timestamp", hex(timestamp)))
            if attributes & 0x08 == 0, tail.count >= 1 + 8 + 32 + 2,
               let hash = reader.bytes(at: tail.lowerBound + 9, count: 32) {
                fields.append(.init("Hash", hash.map { String(format: "%02X", $0) }.joined()))
            }
        }
        if let checksum = NvarChecksum.read(node, in: reader) {
            fields.append(.init(
                "Checksum",
                Checksums.text(checksum.stored, valid: checksum.valid, expected: UInt64(checksum.expected))
            ))
        }
        return fields
    }

    /// The NVAR attribute bits, in the reference parser's words.
    private static let nvarAttributeBits: [(UInt8, String)] = [
        (0x01, "Runtime"),
        (0x02, "AsciiName"),
        (0x04, "Guid"),
        (0x08, "DataOnly"),
        (0x10, "ExtHeader"),
        (0x20, "HwErrorRecord"),
        (0x40, "AuthWrite"),
        (0x80, "Valid"),
    ]

    /// The NVAR extended attribute bits; the others are unknown.
    private static let nvarExtendedAttributeBits: [(UInt8, String)] = [
        (0x01, "Checksum"),
        (0x10, "AuthWrite"),
        (0x20, "TimeBasedAuthWrite"),
    ]

    /// The EVSA data-entry attribute bits. A data entry shares the VSS words
    /// and adds the extended-header bit in place of the Apple one.
    private static let evsaAttributeBits: [(UInt32, String)] = [
        (0x0000_0001, "NonVolatile"),
        (0x0000_0002, "BootService"),
        (0x0000_0004, "Runtime"),
        (0x0000_0008, "HwErrorRecord"),
        (0x0000_0010, "AuthWrite"),
        (0x0000_0020, "TimeBasedAuthWrite"),
        (0x0000_0040, "AppendWrite"),
        (0x1000_0000, "ExtendedHeader"),
    ]

    /// The stored checksum of an EVSA record, whether it counts, and what it
    /// would have to be. An EVSA record checks itself the sum-to-zero way:
    /// everything from the stored checksum byte to the record's end adds up to
    /// zero (§9). The reference parser reads that region from two bytes in, and
    /// summing from the checksum byte is the same arithmetic. When the sum is
    /// not zero, the byte that would make it zero is `stored &- sum` — what a
    /// wrong checksum should read, and what the detail quotes. Nil only when the
    /// record cannot be read whole.
    private static func evsaChecksum(
        storedAt checksumOffset: UInt64,
        covering end: UInt64,
        reader: ImageReader
    ) -> (value: UInt8, valid: Bool, expected: UInt8?)? {
        guard let stored = reader.uint8(at: checksumOffset),
              end > checksumOffset,
              let sum = Checksums.sum8(of: checksumOffset..<end, in: reader)
        else { return nil }
        return (stored, sum == 0, stored &- sum)
    }

    /// Fixed-size bytes that hold an ASCII word: everything up to the first
    /// zero, as text. The parser's SLIC records store the OEM id and table id
    /// without a terminator, so a trailing zero is only cut when one is there.
    private static func asciiText(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: - Text

    /// A checksum row read at `checksumOffset` whose validity the caller has
    /// decided by the parse-time repairs: the repair sitting at the field's own
    /// offset says the field is wrong, and its bytes are the "should be" value
    /// the row quotes — `0x… (Invalid), should be 0x…`. A field with no repair
    /// reads `0x… (Valid)`, and a wrong one is marked as the problem it is so
    /// the controller can colour just that value red.
    private static func checksumRow(
        _ label: String,
        _ stored: some BinaryInteger,
        digits: Int,
        repairs: [ChecksumRepair],
        checksumOffset: UInt64
    ) -> UEFIDetailField {
        let repair = repairs.first { $0.offset == checksumOffset }
        let isProblem = repair != nil
        return UEFIDetailField(
            label,
            Checksums.text(
                stored,
                valid: !isProblem,
                expected: repair.map { littleEndian($0.bytes) },
                digits: digits
            ),
            isProblem: isProblem
        )
    }

    /// The bytes of a repair as the number they write, little-endian the way
    /// every multi-byte value in this format is stored — the value a Fix writes
    /// and the detail quotes as "should be".
    private static func littleEndian(_ bytes: [UInt8]) -> UInt64 {
        bytes.enumerated().reduce(into: UInt64(0)) { result, pair in
            result |= UInt64(pair.element) << (8 * pair.offset)
        }
    }

    /// A byte-length field, which a reader wants in decimal as well as hex —
    /// `0x800 (2048)`, the spelling the FIT panel uses for the same fields, so
    /// neither has to be worked out from the other. Zero is not worth two
    /// spellings: the area holds nothing, and the row says so. Offsets,
    /// addresses and codes stay bare hex. Named `sizeText` so it can coexist
    /// with the local `size` variables the header cases bind.
    private static func sizeText<T: BinaryInteger>(_ bytes: T) -> String {
        let value = UInt64(truncatingIfNeeded: bytes)
        return value == 0 ? "Empty" : "\(hex(bytes)) (\(value))"
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
        // The NVRAM stores and entries read as their item-type word, matching
        // the tree's Type column.
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
        case .padding: return L("Padding")
        case .freeSpace: return L("Free space")
        case .nonUEFIData: return L("Non-UEFI data")
        case .flashDeviceMapRegion: return L("Flash device map region")
        case .ecImage: return L("EC firmware image")
        case .fitComponent: return L("FIT component")
        case .picture: return L("Picture")
        }
    }

    /// The type byte, named by the kind that gives it a meaning. The name
    /// carries the code when there is no name — `FFS.typeName` and
    /// `Section.typeName` fall back to `File type 0xNN` / `Section type 0xNN` —
    /// so a known type is a word and an unknown one is its number.
    private static func typeText(_ node: UEFINode) -> String {
        guard let subtype = node.subtype else { return "" }
        switch node.kind {
        case .file: return UEFITypeNames.file(subtype)
        case .section: return UEFITypeNames.section(subtype)
        case .volume: return "Revision \(subtype)"
        case .region:
            // The region label has no number in it, so the code goes with it.
            return FlashRegionType(rawValue: Int(subtype)).map { "\($0.label) · \(hex(subtype))" } ?? hex(subtype)
        case .intelImage, .uefiImage:
            // Image and Intel / Image and UEFI are the type/subtype pairs
            // UEFITool names these roots; the word comes from the same table as
            // the columns.
            return UEFITypes.subtypeName(type: node.uefiItemType, subtype) ?? hex(subtype)
        // An NVRAM entry and a SLIC blob carry a derived subtype; name it from
        // the table, keeping the number where the table has no word.
        case .vssEntry, .sysFEntry, .evsaEntry, .flashMapEntry, .slicData, .nvarEntry, .dvarEntry, .startupApData:
            return UEFITypes.subtypeName(type: node.uefiItemType, subtype) ?? hex(subtype)
        default: return hex(subtype)
        }
    }

    private static func guidText(_ guid: EFIGUID) -> String {
        if let known = KnownGUIDs.name(of: guid) {
            return "\(guid) (\(known))"
        }
        return guid.description
    }

    /// Where the part starts and how long it is. The length is a size, so it is
    /// said the way every size in a detail is said — `sizeText` — and a part
    /// with no bytes is the word that stands for that everywhere, not a dash:
    /// `0x0 · 0x2000 (8192) bytes`, or `Empty`.
    private static func rangeText(_ range: Range<UInt64>) -> String {
        guard !range.isEmpty else { return sizeText(0) }
        return "\(hex(range.lowerBound)) · \(sizeText(range.count)) bytes"
    }

    /// The hex value, with the well-known bits named when they are set.
    private static func bits<T: FixedWidthInteger>(_ value: T, _ names: [(T, String)]) -> String {
        let set = names.filter { value & $0.0 != 0 }.map(\.1)
        var text = hex(value)
        if !set.isEmpty { text += " (" + set.joined(separator: ", ") + ")" }
        return text
    }

    private static func hex<T: BinaryInteger>(_ value: T) -> String {
        "0x" + String(UInt64(truncatingIfNeeded: value), radix: 16, uppercase: true)
    }
}
