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
        // Every way in — a client's call, `survey` asking on a model's behalf
        // — meets the same check, so an argument the tool does not take is a
        // refusal and never a call that silently did something else.
        self.run = { [name, inputSchema] call in
            try Self.refuseUnknownArguments(call.arguments, of: name, schema: inputSchema)
            try Self.refuseMalformedValues(call.arguments, of: name, schema: inputSchema)
            return try await run(call)
        }
    }

    /// Throws when `arguments` names one the schema does not.
    ///
    /// The schema says `additionalProperties: false`, but a client may not
    /// hold a model to it: one that drops what it does not know sends the call
    /// on without it, and the tool answers as if the argument had never been
    /// given — `open_part` with `decoded: true` opened the block still encoded,
    /// and the answer looked like success. The refusal names what the tool
    /// does take and, when it can tell, what was meant.
    static func refuseUnknownArguments(_ arguments: AgentArguments, of tool: String, schema: JSONValue) throws {
        let properties = schema["properties"]?.objectValue ?? [:]
        let unknown = arguments.values.keys.filter { properties[$0] == nil }.sorted()
        guard let first = unknown.first else { return }
        let names = unknown.map { "`\($0)`" }.joined(separator: ", ")
        var message = "`\(tool)` takes no argument \(names)."
        if let meant = meaning(of: first, in: properties) {
            message += " Perhaps \(meant)."
        }
        let taken = properties.keys.sorted()
        message += taken.isEmpty
            ? " It takes no arguments."
            : " It takes: \(taken.joined(separator: ", "))."
        throw AgentToolError(message)
    }

    /// Throws when a value inside an argument breaks what the schema says of
    /// it: a key an item does not take or lacks, or a word outside an `enum`.
    ///
    /// The top-level check above sees only the arguments' names. Below them a
    /// tool used to pass an item on as it came, and the reader took the keys
    /// it knew: `ghidra_comment` with `comment` in place of `text` erased the
    /// comment and answered ok, `ghidra_equate` with `op` for `operand` named
    /// another operand. A schema that lists an object's `properties` with
    /// `additionalProperties: false` is now held to it at every depth, and an
    /// `enum` to its words, before the tool runs.
    static func refuseMalformedValues(_ arguments: AgentArguments, of tool: String, schema: JSONValue) throws {
        let properties = schema["properties"]?.objectValue ?? [:]
        for name in arguments.values.keys.sorted() {
            guard let property = properties[name], let value = arguments.values[name] else { continue }
            try check(value, against: property, at: "`\(name)`", tool: tool, nested: false)
        }
    }

    private static func check(_ value: JSONValue, against schema: JSONValue, at place: String, tool: String,
                              nested: Bool = true) throws {
        // Inside an argument, where no reader looks at a value's kind, the
        // schema's type is the check: `assert_routine: "true"` read as no
        // boolean at all. An argument itself is its reader's to check.
        if nested, let kind = schema["type"]?.stringValue, !Self.value(value, isOf: kind) {
            throw AgentToolError("`\(tool)`: \(place) is not \(kind == "integer" ? "an" : "a") \(kind). Nothing was done.")
        }
        if let choices = schema["enum"]?.arrayValue?.compactMap(\.stringValue), let word = value.stringValue,
           !choices.contains(word) {
            throw AgentToolError("`\(tool)`: \(place) is \"\(word)\"; it takes "
                + choices.map { "\"\($0)\"" }.joined(separator: ", ") + ".")
        }
        if let items = schema["items"], let array = value.arrayValue {
            for (index, element) in array.enumerated() {
                try check(element, against: items, at: "Item \(index) of \(place)", tool: tool)
            }
        }
        guard let fields = schema["properties"]?.objectValue, let object = value.objectValue else { return }
        if schema["additionalProperties"] == .bool(false) {
            let unknown = object.keys.filter { fields[$0] == nil }.sorted()
            if let first = unknown.first {
                var message = "`\(tool)`: \(place) has " + unknown.map { "`\($0)`" }.joined(separator: ", ")
                    + ", which it does not take."
                if let meant = meaning(of: first, in: fields) { message += " Perhaps \(meant)." }
                message += " It takes: " + fields.keys.sorted().map { "`\($0)`" }.joined(separator: ", ") + ". Nothing was done."
                throw AgentToolError(message)
            }
        }
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let missing = required.first(where: { object[$0] == nil }) {
            throw AgentToolError("`\(tool)`: \(place) has no `\(missing)`, which it needs. Nothing was done.")
        }
        for key in object.keys.sorted() {
            guard let field = fields[key], let inner = object[key] else { continue }
            try check(inner, against: field, at: "`\(key)` of \(place)", tool: tool)
        }
    }

    private static func value(_ value: JSONValue, isOf kind: String) -> Bool {
        switch (kind, value) {
        case ("string", .string), ("boolean", .bool), ("array", .array), ("object", .object): return true
        case ("integer", .int), ("number", .int), ("number", .double): return true
        case ("integer", .double(let number)): return number.rounded() == number
        case ("string", _), ("boolean", _), ("array", _), ("object", _), ("integer", _), ("number", _): return false
        default: return true
        }
    }

    /// What a model most likely meant by an argument the tool does not take:
    /// a value of one it does (`decoded` for `part: "decoded"`), or one whose
    /// name is a slip away from it.
    static func meaning(of name: String, in properties: [String: JSONValue]) -> String? {
        let lower = name.lowercased()
        for key in properties.keys.sorted() {
            let choices = properties[key]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if let choice = choices.first(where: { $0.lowercased() == lower }) {
                return "`\(key): \"\(choice)\"`"
            }
        }
        let near = properties.keys
            .map { (key: $0, distance: editDistance(lower, $0.lowercased())) }
            .filter { $0.distance <= max(1, min(2, name.count / 3)) }
            .min { ($0.distance, $0.key) < ($1.distance, $1.key) }
        return near.map { "`\($0.key)`" }
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let kept = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : 1 + min(previous, row[j], row[j - 1])
                previous = kept
            }
        }
        return row[b.count]
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
