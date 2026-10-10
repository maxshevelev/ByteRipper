import Foundation

/// What a connection serves: who the server is, what it tells a model about
/// itself, the tools, and the bounds on what goes over the wire.
///
/// A value, shared by every connection. The list of tools does not change
/// while the app runs — a panel that is closed does not take its tools away,
/// it makes them answer that the panel is closed (`Design/AGENT_PLAN.md`) —
/// so the server never has to tell a client that its list went stale, and
/// says so: `listChanged` is false.
public struct AgentServer: Sendable {
    public let info: AgentServerInfo
    /// Guidance for the model on how to use the tools together; sent in
    /// `initialize` and `server/discover`.
    public let instructions: String?
    public let tools: [AgentTool]
    public let limits: Limits

    private let toolsByName: [String: AgentTool]

    public init(info: AgentServerInfo, instructions: String? = nil, tools: [AgentTool], limits: Limits = Limits()) {
        self.info = info
        self.instructions = instructions
        self.tools = tools
        self.limits = limits
        // Two tools with one name is a mistake in the code that built the
        // list; the first one wins and the second is never reachable, which a
        // test of the list will show.
        self.toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func tool(named name: String) -> AgentTool? { toolsByName[name] }

    /// How much may cross in one message.
    public struct Limits: Equatable, Sendable {
        /// The longest line read from a client. A request is a few hundred
        /// bytes; this is room for a large write and no more.
        public var maxLineBytes: Int
        /// The longest answer a tool may give. Every byte of it lands in a
        /// model's context, and one answer that fills the context costs more
        /// than the server saves — so an answer over this is not sent, and the
        /// model is told to ask for less.
        public var maxAnswerBytes: Int

        public init(maxLineBytes: Int = 4 << 20, maxAnswerBytes: Int = 24 << 10) {
            self.maxLineBytes = maxLineBytes
            self.maxAnswerBytes = maxAnswerBytes
        }
    }
}

/// One call, as the Agent window's log shows it.
public struct AgentCallRecord: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case answered
        /// The tool said why it could not answer; the message went to the
        /// model.
        case toolError(String)
        /// The answer was over `Limits.maxAnswerBytes` and was not sent.
        case overBound
        /// The client withdrew the request; nothing was sent.
        case cancelled
        /// The tool is still working on it: the record a call is given when
        /// it starts, which its finished record replaces (same `id`).
        case running
    }

    /// Which call this is, so a list that drops its oldest rows can still
    /// find the one a reader selected — and so a call's finished record can
    /// take the place of the one it was given when it started.
    public let id: UUID
    /// When the call came in, by this Mac's clock.
    public let started: Date
    /// The client's own name for itself, when it gave one.
    public let client: String?
    public let tool: String
    public let arguments: JSONValue
    public let duration: Duration
    /// When the call ended, by this Mac's clock.
    public let finished: Date
    /// The size of the answer as the tool produced it, sent or not.
    public let answerBytes: Int
    public let outcome: Outcome

    public init(id: UUID = UUID(), client: String?, tool: String, arguments: JSONValue,
                started: Date? = nil, duration: Duration, finished: Date,
                answerBytes: Int, outcome: Outcome) {
        self.id = id
        self.client = client
        self.tool = tool
        self.arguments = arguments
        self.started = started ?? finished
        self.duration = duration
        self.finished = finished
        self.answerBytes = answerBytes
        self.outcome = outcome
    }

    /// Whether the tool is still working on the call.
    public var isRunning: Bool { outcome == .running }
}
