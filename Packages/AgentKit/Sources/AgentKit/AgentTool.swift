import Foundation

/// One thing an agent can ask the app to do: its name, what it says about
/// itself, the arguments it takes, and the code that answers.
///
/// The name, the description and the schema are read by a model, not by the
/// person at the bench. They stay in English and do not go through `L()`
/// (`Design/LOCALIZATION.md`): what a tool is called is an interface, and an
/// interface that changed with the language of the Mac it ran on would be two
/// interfaces.
public struct AgentTool: Sendable {
    /// Letters, digits, `_`, `-` and `.`, unique within the server.
    public let name: String
    /// What a client may show a person in place of the name.
    public let title: String?
    /// What the tool does and when to use it — the only thing a model knows
    /// about it besides the schema, so it says what comes back as well as what
    /// goes in.
    public let description: String
    /// A JSON Schema object for the arguments.
    public let inputSchema: JSONValue
    public let annotations: Annotations
    public let run: @Sendable (AgentCall) async throws -> AgentAnswer

    public init(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: JSONValue = AgentSchema.object([:]),
        annotations: Annotations = .readOnly,
        run: @escaping @Sendable (AgentCall) async throws -> AgentAnswer
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.run = run
    }

    /// What a tool does to the world, as hints a client may use to decide
    /// whether to ask the person first. Hints, not guarantees — the protocol
    /// says a client must not trust them from a server it does not trust.
    public struct Annotations: Equatable, Sendable {
        /// Changes nothing: a read, a query.
        public var readOnly: Bool
        /// May change something it cannot take back. An edit here goes onto
        /// the undo stack and nothing is saved, so this stays false even for
        /// the tools that write.
        public var destructive: Bool
        /// Calling it twice with the same arguments does what calling it once
        /// did.
        public var idempotent: Bool

        public init(readOnly: Bool, destructive: Bool = false, idempotent: Bool) {
            self.readOnly = readOnly
            self.destructive = destructive
            self.idempotent = idempotent
        }

        /// A query: reads, changes nothing, the same answer twice.
        public static let readOnly = Annotations(readOnly: true, idempotent: true)
        /// Moves the view, selects, marks: changes what is on screen, not the
        /// file.
        public static let view = Annotations(readOnly: false, idempotent: true)
        /// Writes into an open file, through its undo.
        public static let edit = Annotations(readOnly: false, idempotent: false)
    }

    /// The tool as `tools/list` describes it.
    var listing: JSONValue {
        var members: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": .bool(annotations.readOnly),
                "destructiveHint": .bool(annotations.destructive),
                "idempotentHint": .bool(annotations.idempotent),
                // Every tool here works on the app and the files on this Mac.
                "openWorldHint": false
            ]
        ]
        if let title { members["title"] = .string(title) }
        return .object(members)
    }
}

/// What a tool's code is handed: the arguments, and the way to say how far it
/// has got.
public struct AgentCall: Sendable {
    public let tool: String
    public let arguments: AgentArguments
    /// Reports progress on a long call, when the client asked for it; does
    /// nothing otherwise. `progress` must grow from one report to the next and
    /// a report that does not is dropped, as the protocol requires.
    public let progress: @Sendable (_ progress: Double, _ total: Double?, _ message: String?) async -> Void

    public init(
        tool: String,
        arguments: AgentArguments,
        progress: @escaping @Sendable (Double, Double?, String?) async -> Void = { _, _, _ in }
    ) {
        self.tool = tool
        self.arguments = arguments
        self.progress = progress
    }
}

/// What a tool answers with.
public enum AgentAnswer: Equatable, Sendable {
    /// Data, sent as compact JSON text. What almost every tool returns.
    case json(JSONValue)
    /// A sentence, for a tool whose answer is one.
    case text(String)

    var text: String {
        switch self {
        case .json(let value): return value.jsonText
        case .text(let text): return text
        }
    }
}

/// A call that could not be answered for a reason the agent can act on: a
/// missing argument, an offset past the end, a panel that is not open.
///
/// Sent as a tool result marked as an error, not as a protocol failure, so the
/// model reads the message and tries again differently — which is the whole
/// difference the protocol draws between the two.
public struct AgentToolError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}
