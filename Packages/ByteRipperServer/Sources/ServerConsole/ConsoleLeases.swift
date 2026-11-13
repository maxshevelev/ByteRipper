import Foundation

/// What the console's Activity page needs of the Ghidra role, as JSON: the
/// modules in work, and an administrator's close of one. Closures, so the
/// console does not link the Ghidra host.
///
/// A shared type or a registry entry a module would replace is not decided
/// here: that is a proposal, on the Proposals page, voted by agents or decided
/// there by an administrator.
public struct ConsoleLeases: Sendable {
    /// The rows `GET /ghidra/v1/leases` answers.
    public let list: @Sendable () async -> Data
    /// The module's lease closed by `by`: the holder's unpublished changes go,
    /// and it is told at its next call. Answers the closed lease.
    public let close: @Sendable (_ module: String, _ by: String) async throws -> Data
    /// The holder every agent on the local MCP socket holds a lease as: a
    /// lease of that holder is shown with the connection that works on it.
    public let localHolder: String

    public init(list: @escaping @Sendable () async -> Data,
                close: @escaping @Sendable (_ module: String, _ by: String) async throws -> Data,
                localHolder: String) {
        self.list = list
        self.close = close
        self.localHolder = localHolder
    }
}
