import Foundation

/// What a server offers besides its tools: *prompts*, texts a person starts a
/// session with, which a client shows as commands (Claude Code:
/// `/mcp__<server>__<name>`); and *resources*, documents a model reads by
/// their URI. ByteRipper's app serves the review kit this way — the roles as
/// prompts, the review rules as resources — so an agent on a Mac with no
/// checkout reads the rules of the server it works on.
///
/// Unlike the tools, what is offered may change while the app runs: the kit
/// comes from the analysis server, and is there only once the app has
/// fetched it. So the lists are asked for at each request, and a server with
/// no content declares neither capability.
public protocol AgentContent: Sendable {
    func prompts() async -> [AgentPrompt]
    /// The prompt's text, with its arguments put in. Throws `AgentToolError`
    /// for a prompt that is not offered, which goes to the client as a
    /// protocol error.
    func prompt(named name: String, arguments: [String: String]) async throws -> AgentPromptText
    func resources() async -> [AgentResource]
    /// Throws `AgentToolError` for a URI that is not offered.
    func resource(uri: String) async throws -> AgentResourceText
}

/// A prompt as `prompts/list` gives it.
public struct AgentPrompt: Equatable, Sendable {
    /// Letters, digits, `_` and `-`: a client makes a command of it.
    public var name: String
    public var title: String?
    public var description: String
    public var arguments: [Argument]

    public struct Argument: Equatable, Sendable {
        public var name: String
        public var description: String
        public var required: Bool

        public init(name: String, description: String, required: Bool = false) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    public init(name: String, title: String? = nil, description: String, arguments: [Argument] = []) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }

    var listing: JSONValue {
        var members: [String: JSONValue] = ["name": .string(name), "description": .string(description)]
        if let title { members["title"] = .string(title) }
        if !arguments.isEmpty {
            members["arguments"] = .array(arguments.map {
                ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)]
            })
        }
        return .object(members)
    }
}

/// A prompt's text: one user message, which the client puts into the session
/// as if the person had typed it.
public struct AgentPromptText: Equatable, Sendable {
    public var description: String?
    public var text: String

    public init(description: String? = nil, text: String) {
        self.description = description
        self.text = text
    }

    var json: JSONValue {
        var members: [String: JSONValue] = [
            "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]]
        ]
        if let description { members["description"] = .string(description) }
        return .object(members)
    }
}

/// A resource as `resources/list` gives it.
public struct AgentResource: Equatable, Sendable {
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String
    public var size: Int?

    public init(uri: String, name: String, title: String? = nil, description: String? = nil,
                mimeType: String = "text/markdown", size: Int? = nil) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.size = size
    }

    var listing: JSONValue {
        var members: [String: JSONValue] = ["uri": .string(uri), "name": .string(name), "mimeType": .string(mimeType)]
        if let title { members["title"] = .string(title) }
        if let description { members["description"] = .string(description) }
        if let size { members["size"] = .int(Int64(size)) }
        return .object(members)
    }
}

/// A resource's text, as `resources/read` gives it.
public struct AgentResourceText: Equatable, Sendable {
    public var uri: String
    public var mimeType: String
    public var text: String

    public init(uri: String, mimeType: String = "text/markdown", text: String) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
    }

    var json: JSONValue {
        ["contents": [["uri": .string(uri), "mimeType": .string(mimeType), "text": .string(text)]]]
    }
}
