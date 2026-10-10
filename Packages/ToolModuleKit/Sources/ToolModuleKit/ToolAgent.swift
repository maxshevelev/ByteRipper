import AgentKit
import Localization

/// A question a tool-module answers an agent from the bytes alone — the
/// children of a node, a node's fields, what holds an address
/// (`Design/AGENT_PLAN.md`, "What a tool-module contributes").
///
/// Declared on the module's **type** (`ToolModule.agentQueries`), because it
/// needs no panel: it runs against a read host for the document the agent
/// names, whatever the left panel of that tab is showing, and is answered from
/// the same shared parse the panel would use. The app adds the `document`
/// argument itself; a query's own schema names only its own arguments.
///
/// The name, the description and every word of the answer are read by a
/// model and stay in English without `L()` (`Design/LOCALIZATION.md`). Words
/// the answer borrows from the panel — field labels the panel builds with
/// `L()` — come out in English too: the app runs every query under
/// `Localization.override`.
public struct ToolAgentQuery: Sendable {
    public let name: String
    public let title: String
    public let description: String
    /// The properties of the argument object, not counting `document`.
    public let properties: [String: JSONValue]
    public let required: [String]
    public let run: @MainActor @Sendable (any ToolReadHost, AgentArguments) async throws -> AgentAnswer

    public init(
        name: String, title: String, description: String,
        properties: [String: JSONValue] = [:], required: [String] = [],
        run: @escaping @MainActor @Sendable (any ToolReadHost, AgentArguments) async throws -> AgentAnswer
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.properties = properties
        self.required = required
        self.run = run
    }
}

/// A question about two documents at once — the variables two dumps keep,
/// set side by side by name and GUID — answered from the bytes alone, like a
/// query (`Design/AGENT_PLAN.md`, stage 6).
///
/// Keyed comparison is the module's to do: only it knows what makes an entry
/// in one dump the same entry in another, since two images do not lay out
/// their stores alike. The app adds both document arguments — `document` and
/// `against` — and hands the query a read host for each.
public struct ToolAgentComparison: Sendable {
    public let name: String
    public let title: String
    public let description: String
    /// The properties of the argument object, not counting `document` and
    /// `against`.
    public let properties: [String: JSONValue]
    public let required: [String]
    public let run: @MainActor @Sendable (any ToolReadHost, any ToolReadHost, AgentArguments) async throws -> AgentAnswer

    public init(
        name: String, title: String, description: String,
        properties: [String: JSONValue] = [:], required: [String] = [],
        run: @escaping @MainActor @Sendable (any ToolReadHost, any ToolReadHost, AgentArguments) async throws -> AgentAnswer
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.properties = properties
        self.required = required
        self.run = run
    }
}

/// A change to the file a tool-module works out for an agent — a checksum put
/// right — with its panel open or not (`Design/AGENT_PLAN.md`, "Edits").
///
/// The module only *computes* the edit: `run` reads through a read host and
/// returns the transaction, and the app decides whether it is applied. It
/// applies it only with the person's edit switch on, only to a document in a
/// tab and not opened read-only, as one undo step — so a module cannot write
/// on an agent's behalf by any other door. Throw to refuse, with a sentence
/// the model can act on ("already correct", "inside a compressed section").
public struct ToolAgentEdit: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let properties: [String: JSONValue]
    public let required: [String]
    /// What the Edit menu calls the step — `Undo <name>`. Put into words in
    /// the app's own language where the step is made, not in the English the
    /// agent is answered in.
    public let undoName: LocalizedText
    public let run: @MainActor @Sendable (any ToolReadHost, AgentArguments) async throws -> Change

    /// What an edit comes to: the writes, and what the module has to say
    /// about them beyond the bytes — where a component went, what it
    /// replaced, what moved.
    public struct Change: Sendable {
        public var transaction: ToolTransaction
        /// Put after the undo step's name, language-neutral: a CPUID, a
        /// revision. Empty for none.
        public var undoDetail: String
        /// Members added to the answer, beside `written` and `undo`.
        public var report: [String: JSONValue]

        public init(_ transaction: ToolTransaction, undoDetail: String = "", report: [String: JSONValue] = [:]) {
            self.transaction = transaction
            self.undoDetail = undoDetail
            self.report = report
        }
    }

    public init(
        name: String, title: String, description: String,
        properties: [String: JSONValue] = [:], required: [String] = [],
        undoName: LocalizedText,
        change: @escaping @MainActor @Sendable (any ToolReadHost, AgentArguments) async throws -> Change
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.properties = properties
        self.required = required
        self.undoName = undoName
        self.run = change
    }

    /// An edit that is its writes and nothing more to say.
    public init(
        name: String, title: String, description: String,
        properties: [String: JSONValue] = [:], required: [String] = [],
        undoName: LocalizedText,
        run: @escaping @MainActor @Sendable (any ToolReadHost, AgentArguments) async throws -> ToolTransaction
    ) {
        self.init(name: name, title: title, description: description, properties: properties,
                  required: required, undoName: undoName) { host, arguments in
            Change(try await run(host, arguments))
        }
    }
}

/// A place in the file a tool-module can name: a node of its tree, by the id
/// its own tools take.
public struct ToolAgentPlace: Equatable, Sendable {
    /// Whose id it is — `"uefi"`, `"me"`: what tells an agent which tool
    /// takes it.
    public var kind: String
    public var id: String
    public var name: String
    /// Its bytes in the file; nil for one with no file address.
    public var range: Range<UInt64>?

    public init(kind: String, id: String, name: String, range: Range<UInt64>?) {
        self.kind = kind
        self.id = id
        self.name = name
        self.range = range
    }
}

/// How a tool-module says where ranges of the file are in its structure, for
/// an answer that is not its own — the runs a byte comparison found
/// (`Design/AGENT_PLAN.md`, stage 8).
///
/// Two questions. `areas`: the parts the file divides into at the top — the
/// descriptor's regions, the BIOS region's volumes — in address order. And
/// `locate`: for each range, the area it is in and the deepest node that
/// covers it whole, or nothing when the module cannot say. Where two modules
/// both answer, the one with the higher `precedence` is the finer one and
/// wins: an ME partition inside the ME region.
public struct ToolAgentLocator: Sendable {
    public let precedence: Int
    public let areas: @MainActor @Sendable (any ToolReadHost) async -> [ToolAgentPlace]
    public let locate: @MainActor @Sendable (any ToolReadHost, [Range<UInt64>]) async -> [[ToolAgentPlace]]

    public init(
        precedence: Int,
        areas: @escaping @MainActor @Sendable (any ToolReadHost) async -> [ToolAgentPlace],
        locate: @escaping @MainActor @Sendable (any ToolReadHost, [Range<UInt64>]) async -> [[ToolAgentPlace]]
    ) {
        self.precedence = precedence
        self.areas = areas
        self.locate = locate
    }
}

/// Something a tool-module does in its open panel at an agent's asking —
/// choose a node in the tree, say which node the reader chose.
///
/// Declared on the type like a query, so the list an agent sees does not
/// change with what is open; it runs on the **live session** of that module
/// in the tab holding the document. With no session there, the app answers
/// that the panel is not open, and the agent can open it (`open_panel`) or
/// point at the bytes instead.
public struct ToolAgentAction: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let properties: [String: JSONValue]
    public let required: [String]
    /// Whether the action changes what is on screen, as opposed to reading
    /// what the panel has chosen.
    public let changesView: Bool
    public let run: @MainActor @Sendable (any ToolSession, AgentArguments) async throws -> AgentAnswer

    public init(
        name: String, title: String, description: String,
        properties: [String: JSONValue] = [:], required: [String] = [],
        changesView: Bool,
        run: @escaping @MainActor @Sendable (any ToolSession, AgentArguments) async throws -> AgentAnswer
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.properties = properties
        self.required = required
        self.changesView = changesView
        self.run = run
    }
}

extension ToolModule {
    /// A tool-module that answers no questions is one an agent cannot ask.
    public static var agentQueries: [ToolAgentQuery] { [] }
    /// Nor compare two documents.
    public static var agentComparisons: [ToolAgentComparison] { [] }
    /// Nor change the file.
    public static var agentEdits: [ToolAgentEdit] { [] }
    /// Nor say where a range of the file is.
    public static var agentLocator: ToolAgentLocator? { nil }
    /// Nor act in its panel.
    public static var agentActions: [ToolAgentAction] { [] }
}
