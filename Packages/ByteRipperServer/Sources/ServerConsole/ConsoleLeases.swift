import Foundation

/// What the console's Activity page needs of the Ghidra role, as JSON: the
/// modules in work, and an administrator's close of one. Closures, so the
/// console does not link the Ghidra host.
public struct ConsoleLeases: Sendable {
    /// The rows `GET /ghidra/v1/leases` answers.
    public let list: @Sendable () async -> Data
    /// The module's lease closed by `by`: the holder's unpublished changes go,
    /// and it is told at its next call. Answers the closed lease.
    public let close: @Sendable (_ module: String, _ by: String) async throws -> Data
    /// The holder every agent on the local MCP socket holds a lease as: a
    /// lease of that holder is shown with the connection that works on it.
    public let localHolder: String
    /// What the module in work would replace at its publish: the shared types,
    /// each with who wrote the shared one and both definitions, and the
    /// library registry's entries, each with who wrote the entry and what it
    /// says now beside what the module would make it say. What the console
    /// shows before an administrator decides.
    public let conflicts: (@Sendable (_ module: String) async throws -> Data)?
    /// The module's publish as its holder, an administrator's decision made by
    /// `by`: each conflicting shared type replaced by the module's, and the
    /// registry entries the decision names (`ConsoleTakeDecision`) taken with
    /// its reason.
    public let publishTaking: (@Sendable (_ module: String, _ by: String, _ decision: ConsoleTakeDecision) async throws -> Data)?

    public init(list: @escaping @Sendable () async -> Data,
                close: @escaping @Sendable (_ module: String, _ by: String) async throws -> Data,
                localHolder: String,
                conflicts: (@Sendable (_ module: String) async throws -> Data)? = nil,
                publishTaking: (@Sendable (_ module: String, _ by: String, _ decision: ConsoleTakeDecision) async throws -> Data)? = nil) {
        self.list = list
        self.close = close
        self.localHolder = localHolder
        self.conflicts = conflicts
        self.publishTaking = publishTaking
    }
}

/// An administrator's decision at a console publish: the registry entries to
/// take, by id, and the reason each entry's history keeps. Types need no
/// list: every conflicting one is taken.
public struct ConsoleTakeDecision: Codable, Equatable, Sendable {
    public var entries: [String]
    public var reason: String?

    public init(entries: [String] = [], reason: String? = nil) {
        self.entries = entries
        self.reason = reason
    }
}
