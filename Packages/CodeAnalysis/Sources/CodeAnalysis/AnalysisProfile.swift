import Foundation

/// How modules of one kind are reviewed: which skill, which shared-type group
/// and library kinds, which records a review fills and which gates it must
/// pass, and which tools do not apply. A declaration both the server (its
/// `ghidra_profile` answer, later its gates) and the app (the code navigation
/// panel's sections) read.
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

        public init(id: String, title: String, summary: String, unansweredGate: Bool) {
            self.id = id
            self.title = title
            self.summary = summary
            self.unansweredGate = unansweredGate
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, summary
            case unansweredGate = "unanswered_gate"
        }
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
    public var libraryKinds: [LibraryKind]
    /// Reference files under `Skills/`, as `<skill>/reference/<file>`.
    public var references: [String]
    public var records: [Record]
    public var gates: [Gate]
    public var inapplicableTools: [InapplicableTool]

    public init(id: String, version: Int, title: String, skill: String, typeGroups: [String],
                libraryKinds: [LibraryKind], references: [String], records: [Record], gates: [Gate],
                inapplicableTools: [InapplicableTool]) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, title, skill, references, records, gates
        case typeGroups = "type_groups"
        case libraryKinds = "library_kinds"
        case inapplicableTools = "inapplicable_tools"
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

    /// The profile of the module `identity` names.
    public static func derive(for identity: ModuleIdentity) -> AnalysisProfile? {
        derive(kind: identity.kind, ecFamily: identity.ec?.family)
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
        typeGroups: ["Ia32", "X64"], libraryKinds: [.edk2, .amd, .intel],
        references: ["cas.md", "code-artifact.md", "description.md", "ghidra.md", "library.md",
                     "uefi-images.md", "uefi-pass.md"].map { "ghidra-uefi/reference/\($0)" },
        records: [
            Record(id: "interfaces", title: "Interfaces",
                   summary: "What the module installs, locates and is notified of (ghidra_set_interfaces).",
                   unansweredGate: true),
            Record(id: "post_codes", title: "POST codes",
                   summary: "The POST codes the module writes, as the exporter finds them in the code.",
                   unansweredGate: false)
        ],
        gates: [
            Gate(id: "levels", summary: "Every function full, linked to the registry or bodiless."),
            Gate(id: "description", summary: "The module described."),
            Gate(id: "interfaces_answered", summary: "Installs, locates and notifies each answered.")
        ],
        inapplicableTools: [])

    /// An ITE EC firmware on an Andes NDS32 core.
    public static let ecIteNds32 = AnalysisProfile(
        id: "ec-ite-nds32", version: 1, title: "ITE EC firmware (NDS32)", skill: "ghidra-ec",
        typeGroups: ["Nds32"], libraryKinds: [.toolchain, .ite],
        references: ["ghidra-ec/reference/it83xx-registers.tsv", "ghidra-ec/reference/it83xx-irqs.tsv",
                     "ghidra-uefi/reference/description.md"],
        records: [
            Record(id: "irq_map", title: "Interrupts",
                   summary: "IRQ, its handler, its source and what it does.", unansweredGate: true),
            Record(id: "host_commands", title: "Host commands",
                   summary: "Port pair and command byte, the handler, its effect, data in and out.",
                   unansweredGate: true),
            Record(id: "ec_ram", title: "EC RAM",
                   summary: "Offset, width, name, writer (EC or host) and meaning.", unansweredGate: true),
            Record(id: "smbus_peers", title: "SMBus and I2C",
                   summary: "Channel and address, the device, the commands and registers used.",
                   unansweredGate: true),
            Record(id: "gpio", title: "GPIO",
                   summary: "Pin, direction and its function in this firmware.", unansweredGate: true),
            Record(id: "eflash_area", title: "eFlash areas",
                   summary: "The flash ranges the firmware reads or writes past its code, and what they hold.",
                   unansweredGate: true)
        ],
        gates: [
            Gate(id: "levels", summary: "Every function full, linked to the registry or bodiless."),
            Gate(id: "x1_sweep", summary: "The X1 sweep clean in the module's own functions."),
            Gate(id: "records_answered", summary: "Every record answered: filled in, or none with the reason."),
            Gate(id: "description", summary: "The eight description sections, with the EC subsections of Interactions."),
            Gate(id: "origin", summary: "The module's origin set.")
        ],
        inapplicableTools: [
            InapplicableTool(tool: "ghidra_set_interfaces",
                             hint: "An EC module has no PPIs or protocols: its records are irq_map, host_commands, "
                                + "ec_ram, smbus_peers, gpio and eflash_area, kept for now as ### subsections of "
                                + "Interactions in the description."),
            InapplicableTool(tool: "ghidra_interfaces",
                             hint: "An EC module records no interfaces; read its description's Interactions."),
            InapplicableTool(tool: "ghidra_guid_add",
                             hint: "EC firmware has no GUIDs to name.")
        ])
}
