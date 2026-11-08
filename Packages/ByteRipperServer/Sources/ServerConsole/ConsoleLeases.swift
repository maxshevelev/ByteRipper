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
    /// The shared types the module in work would replace at its publish: for
    /// each, who wrote the shared one and both definitions. What the console
    /// shows before an administrator decides.
    public let typeConflicts: (@Sendable (_ module: String) async throws -> Data)?
    /// The module's publish as its holder, each conflicting shared type
    /// replaced by the module's: an administrator's decision, made by `by`.
    public let publishTakingTypes: (@Sendable (_ module: String, _ by: String) async throws -> Data)?

    public init(list: @escaping @Sendable () async -> Data,
                close: @escaping @Sendable (_ module: String, _ by: String) async throws -> Data,
                localHolder: String,
                typeConflicts: (@Sendable (_ module: String) async throws -> Data)? = nil,
                publishTakingTypes: (@Sendable (_ module: String, _ by: String) async throws -> Data)? = nil) {
        self.list = list
        self.close = close
        self.localHolder = localHolder
        self.typeConflicts = typeConflicts
        self.publishTakingTypes = publishTakingTypes
    }
}
