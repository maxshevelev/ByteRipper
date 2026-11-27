import Foundation

/// How modules of one kind are reviewed: which skill, which shared-type group
/// and library kinds, which records a review fills and which gates it must
/// pass, and which tools do not apply. A declaration both the server (its
/// `ghidra_profile` answer, later its gates) and the app (the code navigation
/// panel's sections) read. Its home is a package of its own so the panel
/// reads it without the store; CodeAnalysis adds `derive(for: ModuleIdentity)`.
///
/// A module's profile is derived from facts the store already keeps
/// (`derive`), never stored per module: it changes for a module only when the
/// catalogue itself is refactored. A revision records the profile it was made
/// under as `stamp` (`"<id>@<version>"`, `ReviewRevision.profile`), so a later
/// version can change the rules without silently re-judging a closed review.
///
/// This step declares records and gates; nothing enforces them yet.
public struct AnalysisProfile: Codable, Equatable, Hashable, Sendable {
    /// A record a review fills beside the code: the app shows each as a
    /// section of its code navigation panel, in this order.
    public struct Record: Codable, Equatable, Hashable, Sendable {
        public var id: String
        /// The panel's title for the section (English; the app localises it).
        public var title: String
        public var summary: String
        /// Whether the review is incomplete while the record is unanswered —
        /// an empty answer counts, a missing one does not.
        public var unansweredGate: Bool
        /// How the Code panel shows the record; nil for one it does not show.
        public var panel: PanelSection?

        /// The columns that make a row's key, unique within the record; rows
        /// are kept in key order. Empty for a record with no table.
        public var key: [String]
        /// The table's columns. Empty for a record the review does not write
        /// as rows (`interfaces`, `post_codes`): `ghidra_set_record` refuses it.
        /// Every row also carries `confidence` (`established`|`inference`,
        /// required) and an optional `note`, and the record a `status`
        /// (`unanswered`|`partial`|`complete`|`none`) and a `note` — common to
        /// every record and not declared here.
        public var columns: [Column]
        /// Values a `computed` column reads, as hex or decimal strings
        /// (`ec_ram_base: "0x80400"`).
        public var parameters: [String: String]

        public init(id: String, title: String, summary: String, unansweredGate: Bool,
                    panel: PanelSection? = nil, key: [String] = [], columns: [Column] = [],
                    parameters: [String: String] = [:]) {
            self.id = id
            self.title = title
            self.summary = summary
            self.unansweredGate = unansweredGate
            self.panel = panel
            self.key = key
            self.columns = columns
            self.parameters = parameters
        }

        /// The column `id`, when the record has one.
        public func column(_ id: String) -> Column? { columns.first { $0.id == id } }

        private enum CodingKeys: String, CodingKey {
            case id, title, summary, panel, key, columns, parameters
            case unansweredGate = "unanswered_gate"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            summary = try c.decode(String.self, forKey: .summary)
            unansweredGate = try c.decode(Bool.self, forKey: .unansweredGate)
            panel = try c.decodeIfPresent(PanelSection.self, forKey: .panel)
            // A profile written before records had tables reads as one without.
            key = try c.decodeIfPresent([String].self, forKey: .key) ?? []
            columns = try c.decodeIfPresent([Column].self, forKey: .columns) ?? []
            parameters = try c.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(summary, forKey: .summary)
            try c.encode(unansweredGate, forKey: .unansweredGate)
            if !AnalysisProfile.omitsPanel(encoder), let panel { try c.encode(panel, forKey: .panel) }
            // Only a record with a table: one without encodes as before.
            if !key.isEmpty { try c.encode(key, forKey: .key) }
            if !columns.isEmpty { try c.encode(columns, forKey: .columns) }
            if !parameters.isEmpty { try c.encode(parameters, forKey: .parameters) }
        }
    }

    // MARK: - A record's table

    /// What a column holds. Raw values are the JSON's.
    public enum ColumnKind: String, Codable, CaseIterable, Sendable {
        /// Free text; with `pattern`, text that must match it.
        case text
        /// An integer, within `min`…`max`; `hex` writes it `0x…`. With
        /// `values`, one of those words is taken instead of a number.
        case int
        /// An integer 0…0xFF, written `0x..`.
        case byte
        /// One of `values`.
        case `enum`
        case bool
        /// An address inside a function of the module (the app opens the
        /// function or the instruction).
        case code
        /// An address in the module's memory (the app opens the datum and its
        /// references).
        case data
        /// Text that matches `pattern`.
        case pattern
        /// A list whose elements are of kind `of` (with the element's
        /// `values`, `pattern`, `min`, `max` and `ref` taken from the column).
        case list
        /// A table inside the row, with `columns`.
        case rows
        /// A row of record `ref`: its key value — a single value for a
        /// one-column key, an object of the key columns otherwise. A ref
        /// nothing answers is a warning, never a refusal.
        case ref
        /// Worked out from the row and the record's `parameters` by `compute`;
        /// never written by the review.
        case computed
    }

    /// One column of a record's table.
    public struct Column: Codable, Equatable, Hashable, Sendable {
        public var id: String
        /// The panel's header (English; the app localises it).
        public var title: String
        public var kind: ColumnKind
        public var required: Bool
        /// `enum`: the choices; `int`: words taken instead of a number.
        public var values: [String]?
        public var min: Int?
        public var max: Int?
        /// An `int` written `0x…`.
        public var hex: Bool?
        /// `pattern` (or `text`, or a list's elements): a regular expression
        /// the whole value matches.
        public var pattern: String?
        /// `list`: the elements' kind.
        public var of: ColumnKind?
        /// `rows`: the nested table's columns.
        public var columns: [Column]?
        /// `ref`, or a list of refs: the record whose rows it names.
        public var ref: String?
        /// `computed`: what works it out — `ec_ram_address` (the record's
        /// `ec_ram_base` + `offset`), `smbus_address_8bit` (`address` × 2).
        public var compute: String?
        /// Values of this column that need the row's `note` (`runtime`).
        public var noteFor: [String]?
        public var summary: String

        public init(_ id: String, _ title: String, _ kind: ColumnKind, required: Bool = false,
                    values: [String]? = nil, min: Int? = nil, max: Int? = nil, hex: Bool? = nil,
                    pattern: String? = nil, of: ColumnKind? = nil, columns: [Column]? = nil,
                    ref: String? = nil, compute: String? = nil, noteFor: [String]? = nil, summary: String) {
            self.id = id
            self.title = title
            self.kind = kind
            self.required = required
            self.values = values
            self.min = min
            self.max = max
            self.hex = hex
            self.pattern = pattern
            self.of = of
            self.columns = columns
            self.ref = ref
            self.compute = compute
            self.noteFor = noteFor
            self.summary = summary
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, kind, required, values, min, max, hex, pattern, of, columns, ref, compute, summary
            case noteFor = "note_for"
        }
    }

    /// A record's status, common to every record with a table. Raw values are
    /// the JSON's.
    public enum RecordStatus: String, Codable, CaseIterable, Sendable {
        case unanswered, partial, complete, none

        /// Whether the `records_answered` gate takes it.
        public var answers: Bool { self == .complete || self == .none }
    }

    /// A row's confidence, common to every row.
    public enum RowConfidence: String, Codable, CaseIterable, Sendable {
        case established, inference
    }

    // MARK: - The Code panel

    /// A section the Code panel's navigator has whatever the profile: the
    /// segments of its list control (`CodePaneView.listControl`) and the
    /// lists of `CodeReaderState.List`. Raw values are the JSON's.
    public enum BuiltInSection: String, Codable, CaseIterable, Sendable {
        /// The Functions list.
        case functions
        /// The Strings list.
        case strings
        /// The POST list: the POST codes the module writes.
        case postCodes = "post_codes"
        /// The Status list: the status-code calls.
        case statusCodes = "status_codes"
        /// Find in All Functions (the magnifier segment).
        case search
        /// The Interfaces segment: what the module installs, looks up and is
        /// notified of.
        case interfaces
    }

    /// How a record stands in the Code panel's navigator.
    public struct PanelSection: Codable, Equatable, Hashable, Sendable {
        /// The record's place among the profile's record sections, from 0.
        /// A section that replaces a built-in one takes that one's place;
        /// the others follow the built-in sections the profile shows.
        public var order: Int
        /// The SF Symbol the section's segment shows.
        public var symbol: String
        /// The built-in section that draws the record — the panel adds no
        /// section of its own for it, and the record's section is that one's
        /// place — nil for a section the panel adds for the profile.
        public var replaces: BuiltInSection?

        public init(order: Int, symbol: String, replaces: BuiltInSection? = nil) {
            self.order = order
            self.symbol = symbol
            self.replaces = replaces
        }
    }

    /// Whether the panel shows a built-in section for the profile's modules.
    public struct BuiltInVisibility: Codable, Equatable, Hashable, Sendable {
        public var section: BuiltInSection
        public var shown: Bool

        public init(_ section: BuiltInSection, shown: Bool) {
            self.section = section
            self.shown = shown
        }
    }

    /// The profile's part of the Code panel beside its records' sections.
    public struct Panel: Codable, Equatable, Hashable, Sendable {
        /// The built-in sections the profile shows or hides. One not listed
        /// is shown.
        public var builtIn: [BuiltInVisibility]

        public init(builtIn: [BuiltInVisibility]) {
            self.builtIn = builtIn
        }

        private enum CodingKeys: String, CodingKey {
            case builtIn = "built_in"
        }
    }

    /// Set to `true` in an encoder's `userInfo` to encode a profile without
    /// its panel fields: the form `ghidra_profile` answered before they were
    /// added, which the golden test holds the encoding to.
    public static let omitsPanelKey = CodingUserInfoKey(rawValue: "AnalysisProfile.omitsPanel")!

    static func omitsPanel(_ encoder: Encoder) -> Bool {
        encoder.userInfo[omitsPanelKey] as? Bool == true
    }

    /// A condition a review must meet before it is complete. Declared only.
    public struct Gate: Codable, Equatable, Hashable, Sendable {
        public var id: String
        public var summary: String

        public init(id: String, summary: String) {
            self.id = id
            self.summary = summary
        }
    }

    /// A tool of the connection that has nothing to do for this profile's
    /// modules, and what to use instead.
    public struct InapplicableTool: Codable, Equatable, Hashable, Sendable {
        public var tool: String
        public var hint: String

        public init(tool: String, hint: String) {
            self.tool = tool
            self.hint = hint
        }
    }

    public var id: String
    /// Raised when the profile's rules change; a revision keeps the version it
    /// was made under.
    public var version: Int
    public var title: String
    /// The skill that reviews the profile's modules (`Skills/<skill>`).
    public var skill: String
    /// The shared-type groups the profile's modules fall into. One group is
    /// every module's; two (`Ia32`, `X64`) are chosen per module by its
    /// bitness (`typeGroup(bits:)`).
    public var typeGroups: [String]
    /// Raw values of the store's `LibraryKind` (`edk2`, `amd`, `intel`,
    /// `ite`, `toolchain`).
    public var libraryKinds: [String]
    /// Reference files under `Skills/`, as `<skill>/reference/<file>`.
    public var references: [String]
    public var records: [Record]
    public var gates: [Gate]
    public var inapplicableTools: [InapplicableTool]
    /// The built-in sections of the Code panel the profile shows or hides.
    public var panel: Panel?

    public init(id: String, version: Int, title: String, skill: String, typeGroups: [String],
                libraryKinds: [String], references: [String], records: [Record], gates: [Gate],
                inapplicableTools: [InapplicableTool], panel: Panel? = nil) {
        self.id = id
        self.version = version
        self.title = title
        self.skill = skill
        self.typeGroups = typeGroups
        self.libraryKinds = libraryKinds
        self.references = references
        self.records = records
        self.gates = gates
        self.inapplicableTools = inapplicableTools
        self.panel = panel
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, title, skill, references, records, gates, panel
        case typeGroups = "type_groups"
        case libraryKinds = "library_kinds"
        case inapplicableTools = "inapplicable_tools"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(Int.self, forKey: .version)
        title = try c.decode(String.self, forKey: .title)
        skill = try c.decode(String.self, forKey: .skill)
        typeGroups = try c.decode([String].self, forKey: .typeGroups)
        libraryKinds = try c.decode([String].self, forKey: .libraryKinds)
        references = try c.decode([String].self, forKey: .references)
        records = try c.decode([Record].self, forKey: .records)
        gates = try c.decode([Gate].self, forKey: .gates)
        inapplicableTools = try c.decode([InapplicableTool].self, forKey: .inapplicableTools)
        panel = try c.decodeIfPresent(Panel.self, forKey: .panel)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(version, forKey: .version)
        try c.encode(title, forKey: .title)
        try c.encode(skill, forKey: .skill)
        try c.encode(typeGroups, forKey: .typeGroups)
        try c.encode(libraryKinds, forKey: .libraryKinds)
        try c.encode(references, forKey: .references)
        try c.encode(records, forKey: .records)
        try c.encode(gates, forKey: .gates)
        try c.encode(inapplicableTools, forKey: .inapplicableTools)
        if !Self.omitsPanel(encoder), let panel { try c.encode(panel, forKey: .panel) }
    }

    /// Whether the Code panel shows built-in `section` for this profile.
    public func shows(_ section: BuiltInSection) -> Bool {
        !(panel?.builtIn.contains { $0.section == section && !$0.shown } ?? false)
    }

    /// The records the panel adds sections for, in their order: those no
    /// built-in section already draws.
    public var addedPanelRecords: [Record] {
        records.filter { $0.panel != nil && $0.panel?.replaces == nil }.sorted { $0.panel!.order < $1.panel!.order }
    }

    /// `"<id>@<version>"`, as a revision records it.
    public var stamp: String { "\(id)@\(version)" }

    /// The type group of a module of `bits` (32 or 64): the profile's only
    /// group, or `Ia32`/`X64` by bitness; nil when the bitness is needed and
    /// not known — the host then decides from the project as it does today.
    public func typeGroup(bits: Int?) -> String? {
        if typeGroups.count == 1 { return typeGroups[0] }
        switch bits {
        case 32: return typeGroups.first { $0 == "Ia32" }
        case 64: return typeGroups.first { $0 == "X64" }
        default: return nil
        }
    }

    /// The inapplicable entry for `tool`, when the profile has one.
    public func inapplicable(_ tool: String) -> InapplicableTool? {
        inapplicableTools.first { $0.tool == tool }
    }

    // MARK: - Deriving

    /// The module kinds a UEFI review reads.
    public static let uefiKinds: Set<String> = ["PE32", "TE"]

    /// The profile of a module of `kind` (`PE32`, `TE`, `EC`) and, for an EC
    /// module, chip `ecFamily`. Nil for any other: an unknown kind is refused
    /// rather than given UEFI's rules, since a fallback would silently move
    /// the module to another profile the day one is added for its kind.
    public static func derive(kind: String?, ecFamily: String?) -> AnalysisProfile? {
        guard let kind else { return nil }
        if uefiKinds.contains(kind) { return uefi }
        if kind == "EC", ecFamily == "ite-nds32" { return ecIteNds32 }
        return nil
    }

    /// The profile `stamp` names, at its current version only.
    public static func named(_ stamp: String) -> AnalysisProfile? {
        catalogue.first { $0.stamp == stamp }
    }

    // MARK: - The catalogue

    public static let catalogue: [AnalysisProfile] = [uefi, ecIteNds32]

    /// Every PE32 or TE module: today's review, unchanged.
    public static let uefi = AnalysisProfile(
        id: "uefi", version: 1, title: "UEFI module (PEI, DXE, SMM)", skill: "ghidra-uefi",
        typeGroups: ["Ia32", "X64"], libraryKinds: ["edk2", "amd", "intel"],
        references: ["cas.md", "code-artifact.md", "description.md", "ghidra.md", "library.md",
                     "uefi-images.md", "uefi-pass.md"].map { "ghidra-uefi/reference/\($0)" },
        records: [
            Record(id: "interfaces", title: "Interfaces",
                   summary: "What the module installs, locates and is notified of (ghidra_set_interfaces).",
                   unansweredGate: true,
                   panel: PanelSection(order: 1, symbol: "arrow.up.arrow.down", replaces: .interfaces)),
            Record(id: "post_codes", title: "POST codes",
                   summary: "The POST codes the module writes, as the exporter finds them in the code.",
                   unansweredGate: false,
                   panel: PanelSection(order: 0, symbol: "number", replaces: .postCodes))
        ],
        gates: [
            Gate(id: "levels", summary: "Every function full, linked to the registry or bodiless."),
            Gate(id: "description", summary: "The module described."),
            Gate(id: "interfaces_answered", summary: "Installs, locates and notifies each answered.")
        ],
        inapplicableTools: [
            InapplicableTool(tool: "register_registry",
                             hint: "The register registry names an EC chip's registers and interrupts; "
                                + "a UEFI module's are not kept there.")
        ],
        panel: Panel(builtIn: [BuiltInVisibility(.interfaces, shown: true),
                               BuiltInVisibility(.postCodes, shown: true)]))

    /// An ITE EC firmware on an Andes NDS32 core.
    public static let ecIteNds32 = AnalysisProfile(
        id: "ec-ite-nds32", version: 2, title: "ITE EC firmware (NDS32)", skill: "ghidra-ec",
        typeGroups: ["Nds32"], libraryKinds: ["toolchain", "ite"],
        references: ["ghidra-uefi/SKILL.md", "ghidra-ec/reference/it83xx-registers.tsv", "ghidra-ec/reference/it83xx-irqs.tsv",
                     "ghidra-uefi/reference/description.md"],
        records: ecRecords,
        gates: [
            Gate(id: "levels", summary: "Every function full, linked to the registry or bodiless."),
            Gate(id: "x1_sweep", summary: "The X1 sweep clean in the module's own functions."),
            Gate(id: "records_answered", summary: "Every record answered: filled in, or none with the reason."),
            Gate(id: "description", summary: "The eight description sections; Interactions describes the records in prose."),
            Gate(id: "origin", summary: "The module's origin set."),
            Gate(id: "isr_numbers", summary: "Every function in IsrIrqTable keeps its Isr_Irq<NNN> or "
                    + "Isr_IrqShared_<NNN> prefix with the number the import gave it.")
        ],
        inapplicableTools: [
            InapplicableTool(tool: "ghidra_code_mode",
                             hint: "NDS32 has a single code mode; the language is fixed by the profile."),
            InapplicableTool(tool: "code_query:post_codes",
                             hint: "An EC has no port-0x80 POST codes; what it sends the host is in host_commands."),
            InapplicableTool(tool: "ghidra_set_interfaces",
                             hint: "An EC module has no PPIs or protocols: its records are irq_map, host_commands, "
                                + "ec_ram, smbus_peers, gpio and eflash_area, written with ghidra_set_record."),
            InapplicableTool(tool: "ghidra_interfaces",
                             hint: "An EC module records no interfaces; read its records with ghidra_records."),
            InapplicableTool(tool: "ghidra_guid_add",
                             hint: "EC firmware has no GUIDs to name.")
        ],
        // An EC image has no strings worth a list and no UEFI status-code
        // reports: Functions, its own sections and Search.
        panel: Panel(builtIn: [BuiltInVisibility(.interfaces, shown: false),
                               BuiltInVisibility(.postCodes, shown: false),
                               BuiltInVisibility(.strings, shown: false),
                               BuiltInVisibility(.statusCodes, shown: false)]))
    /// The six records of an EC review, each a table (the EC reviewer's
    /// schema, 2026-11-27). A field marked required in the schema is
    /// `required` here; `->code` is `code`, `->data` is `data`.
    static let ecRecords: [Record] = [
        Record(id: "irq_map", title: "Interrupts",
               summary: "One row per IRQ whose handler is not empty: the handler, its source and what it does. "
                  + "Say what the other IRQs are in the record's note (\"all other IRQs: empty stub\").",
               unansweredGate: true, panel: PanelSection(order: 0, symbol: "bolt"),
               key: ["irq"],
               columns: [
                Column("irq", "IRQ", .int, required: true, min: 0, max: 239, summary: "The interrupt number, 0…239."),
                Column("handler", "Handler", .code, required: true, summary: "The ISR the table calls (Isr_IrqNNN)."),
                Column("body", "Body", .code, summary: "The function doing the work (IntcIrqNNN_…), when not the handler."),
                Column("source", "Source", .text, required: true, summary: "What raises the interrupt."),
                Column("source_status", "Source known from", .enum, required: true, values: ["firmware", "unverified"],
                       summary: "firmware: the code shows the source; unverified: from a datasheet or another chip."),
                Column("enabled_by_firmware", "Enabled", .bool, required: true,
                       summary: "Whether the firmware enables the interrupt."),
                Column("task_slot", "Task slot", .int, min: 0, summary: "The task slot the handler sets, if any."),
                Column("purpose", "Purpose", .text, required: true, summary: "What the handler does.")
               ]),
        Record(id: "host_commands", title: "Host commands",
               summary: "Port pair and command byte, the handler, its effect, data in and out. A command on two "
                  + "port pairs is two rows.",
               unansweredGate: true, panel: PanelSection(order: 1, symbol: "arrow.left.arrow.right"),
               key: ["ports", "cmd", "sub", "mode"],
               columns: [
                Column("ports", "Ports", .enum, required: true, values: ["60/64", "62/66", "68/6C"],
                       summary: "The port pair the command is written to."),
                Column("mode", "Mode", .enum, required: true, values: ["normal", "flash"],
                       summary: "normal, or the flash (update) mode the command is taken in."),
                Column("cmd", "Command", .byte, required: true, summary: "The command byte."),
                Column("sub", "Subcommand", .byte, summary: "The subcommand byte, when the command takes one."),
                Column("handler", "Handler", .code, required: true, summary: "The code that carries it out."),
                Column("effect", "Effect", .text, required: true, summary: "What the command does."),
                Column("data_in", "Data in", .text, summary: "Bytes the host writes after it: count and meaning."),
                Column("data_out", "Data out", .text, summary: "Bytes the EC answers: count and meaning."),
                Column("raises", "Raises", .list, pattern: "SCI|SMI|query (0x[0-9A-Fa-f]{1,2}|[0-9]{1,3})", of: .pattern,
                       summary: "Events it raises: SCI, SMI, query N."),
                Column("ec_ram", "EC RAM", .list, of: .ref, ref: "ec_ram",
                       summary: "The EC RAM offsets it touches (rows of ec_ram).")
               ]),
        Record(id: "ec_ram", title: "EC RAM",
               summary: "Offset, width, name, writer (EC or host) and meaning.",
               unansweredGate: true, panel: PanelSection(order: 2, symbol: "memorychip"),
               key: ["offset"],
               columns: [
                Column("offset", "Offset", .int, required: true, min: 0, max: 0xFF, hex: true,
                       summary: "The offset in the host's EC RAM window, 0x00…0xFF."),
                Column("width", "Width", .int, required: true, min: 1, summary: "The width in bytes."),
                Column("name", "Name", .text, required: true, summary: "The field's name."),
                Column("address", "Address", .computed, compute: "ec_ram_address",
                       summary: "Where the EC holds it: ec_ram_base + offset."),
                Column("writer", "Writer", .enum, required: true, values: ["EC", "host", "both"],
                       summary: "Who writes it."),
                Column("meaning", "Meaning", .text, required: true, summary: "What it holds."),
                Column("values", "Values", .text, summary: "Its values and what each means."),
                Column("accessed_by", "Accessed by", .list, of: .code, summary: "The code that reads or writes it.")
               ],
               parameters: ["ec_ram_base": "0x80400"]),
        Record(id: "smbus_peers", title: "SMBus and I2C",
               summary: "Channel and address, the device, the commands and registers used.",
               unansweredGate: true, panel: PanelSection(order: 3, symbol: "point.3.connected.trianglepath.dotted"),
               key: ["channel", "address"],
               columns: [
                Column("channel", "Channel", .enum, required: true, values: ["A", "B", "C", "D", "E"],
                       summary: "The SMBus channel."),
                Column("address", "Address", .int, required: true, values: ["runtime", "mailbox"], min: 0, max: 0x7F, hex: true,
                       noteFor: ["runtime", "mailbox"],
                       summary: "The 7-bit address; runtime when the code works it out, mailbox when the channel has no address of its own and works only through the host mailbox (say how in the row's note)."),
                Column("address_8bit", "Bus address", .computed, compute: "smbus_address_8bit",
                       summary: "The 8-bit bus address: the 7-bit address × 2."),
                Column("device", "Device", .text, required: true, summary: "The device, or \"not identified\"."),
                Column("pec", "PEC", .bool, summary: "Whether the transfers carry a PEC byte."),
                Column("commands", "Commands", .rows, required: true, columns: [
                    Column("cmd", "Command", .byte, required: true, summary: "The command or register byte."),
                    Column("access", "Access", .enum, required: true, values: ["R", "W"], summary: "Read or write."),
                    Column("size", "Size", .enum, required: true, values: ["byte", "word", "block"],
                           summary: "The transfer's size."),
                    Column("meaning", "Meaning", .text, required: true, summary: "What it reads or sets.")
                ], summary: "The commands the firmware sends the device."),
                Column("callers", "Callers", .list, of: .code, summary: "The code that talks to the device.")
               ]),
        Record(id: "gpio", title: "GPIO",
               summary: "Pin, direction and its function in this firmware. The board's net is not written here.",
               unansweredGate: true, panel: PanelSection(order: 4, symbol: "cable.connector"),
               key: ["pin"],
               columns: [
                Column("pin", "Pin", .pattern, required: true, pattern: "GP[A-M][0-7]",
                       summary: "The GPIO pin as the chip names it: GP, port letter and bit, GPA0…GPM7 (not a package ball)."),
                Column("direction", "Direction", .enum, required: true, values: ["in", "out", "alt", "bidir"],
                       summary: "How the firmware sets it."),
                Column("function", "Function", .text, required: true, summary: "What the pin does in this firmware."),
                Column("active_level", "Active level", .enum, values: ["high", "low"], summary: "The level that asserts it."),
                Column("init", "Initial state", .text, summary: "How the firmware sets it up."),
                Column("accessed_by", "Accessed by", .list, of: .code, summary: "The code that reads or drives it.")
               ]),
        Record(id: "eflash_area", title: "Flash data area",
               summary: "The EC's flash data area past the image extent: every range or address the code "
                  + "reads, writes or erases there; the function that does it; the record format; and what "
                  + "it holds (state bytes, logs, settings). Write the meaning only from the code. A dump's "
                  + "contents are never the meaning, because they differ between reads and a host update "
                  + "rewrites them up to host_update_size. A byte inside the image the code keeps state in "
                  + "is a row too, with in_image.",
               unansweredGate: true, panel: PanelSection(order: 5, symbol: "internaldrive"),
               key: ["address"],
               columns: [
                Column("address", "Address", .data, required: true,
                       summary: "Where the area starts (its label in eflash_data)."),
                Column("size", "Size", .int, required: true, min: 1, hex: true, summary: "Its size in bytes."),
                Column("format", "Format", .text, required: true, summary: "A type's name, or the layout in words."),
                Column("writers", "Writers", .list, required: true, of: .code, summary: "The code that writes or erases it."),
                Column("readers", "Readers", .list, of: .code, summary: "The code that reads it."),
                Column("host_commands", "Host commands", .list, of: .ref, ref: "host_commands",
                       summary: "Host commands that reach it (rows of host_commands)."),
                Column("meaning", "Meaning", .text, required: true, summary: "What it holds, from the code."),
                Column("in_image", "In the image", .bool, summary: "A byte inside the image rather than past its extent.")
               ])
    ]
}
