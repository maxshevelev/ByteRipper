import AgentKit

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
    /// Nor act in its panel.
    public static var agentActions: [ToolAgentAction] { [] }
}
