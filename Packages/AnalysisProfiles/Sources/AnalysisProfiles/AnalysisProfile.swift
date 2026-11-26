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

        public init(id: String, title: String, summary: String, unansweredGate: Bool,
                    panel: PanelSection? = nil) {
            self.id = id
            self.title = title
            self.summary = summary
            self.unansweredGate = unansweredGate
            self.panel = panel
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, summary, panel
            case unansweredGate = "unanswered_gate"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            summary = try c.decode(String.self, forKey: .summary)
            unansweredGate = try c.decode(Bool.self, forKey: .unansweredGate)
            panel = try c.decodeIfPresent(PanelSection.self, forKey: .panel)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(summary, forKey: .summary)
            try c.encode(unansweredGate, forKey: .unansweredGate)
            if !AnalysisProfile.omitsPanel(encoder), let panel { try c.encode(panel, forKey: .panel) }
        }
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
        inapplicableTools: [],
        panel: Panel(builtIn: [BuiltInVisibility(.interfaces, shown: true),
                               BuiltInVisibility(.postCodes, shown: true)]))

    /// An ITE EC firmware on an Andes NDS32 core.
    public static let ecIteNds32 = AnalysisProfile(
        id: "ec-ite-nds32", version: 1, title: "ITE EC firmware (NDS32)", skill: "ghidra-ec",
        typeGroups: ["Nds32"], libraryKinds: ["toolchain", "ite"],
        references: ["ghidra-uefi/SKILL.md", "ghidra-ec/reference/it83xx-registers.tsv", "ghidra-ec/reference/it83xx-irqs.tsv",
                     "ghidra-uefi/reference/description.md"],
        records: [
            Record(id: "irq_map", title: "Interrupts",
                   summary: "IRQ, its handler, its source and what it does.", unansweredGate: true,
                   panel: PanelSection(order: 0, symbol: "bolt")),
            Record(id: "host_commands", title: "Host commands",
                   summary: "Port pair and command byte, the handler, its effect, data in and out.",
                   unansweredGate: true, panel: PanelSection(order: 1, symbol: "arrow.left.arrow.right")),
            Record(id: "ec_ram", title: "EC RAM",
                   summary: "Offset, width, name, writer (EC or host) and meaning.", unansweredGate: true,
                   panel: PanelSection(order: 2, symbol: "memorychip")),
            Record(id: "smbus_peers", title: "SMBus and I2C",
                   summary: "Channel and address, the device, the commands and registers used.",
                   unansweredGate: true, panel: PanelSection(order: 3, symbol: "point.3.connected.trianglepath.dotted")),
            Record(id: "gpio", title: "GPIO",
                   summary: "Pin, direction and its function in this firmware.", unansweredGate: true,
                   panel: PanelSection(order: 4, symbol: "cable.connector")),
            Record(id: "eflash_area", title: "Flash data area",
                   summary: "The EC's flash data area past the image extent: every range or address the code "
                      + "reads, writes or erases there; the function that does it; the record format; and what "
                      + "it holds (state bytes, logs, settings). Write the meaning only from the code. A dump's "
                      + "contents are never the meaning, because they differ between reads and a host update "
                      + "rewrites them up to host_update_size.",
                   unansweredGate: true, panel: PanelSection(order: 5, symbol: "internaldrive"))
        ],
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
                                + "ec_ram, smbus_peers, gpio and eflash_area, kept for now as ### subsections of "
                                + "Interactions in the description."),
            InapplicableTool(tool: "ghidra_interfaces",
                             hint: "An EC module records no interfaces; read its description's Interactions."),
            InapplicableTool(tool: "ghidra_guid_add",
                             hint: "EC firmware has no GUIDs to name.")
        ],
        panel: Panel(builtIn: [BuiltInVisibility(.interfaces, shown: false),
                               BuiltInVisibility(.postCodes, shown: false)]))
}
