import Foundation

/// What the console's Leases page needs of the Ghidra role, as JSON: the
/// modules in work, and an administrator's close of one. Closures, so the
/// console does not link the Ghidra host.
public struct ConsoleLeases: Sendable {
    /// The rows `GET /ghidra/v1/leases` answers.
    public let list: @Sendable () async -> Data
    /// The module's lease closed by `by`: the holder's unpublished changes go,
    /// and it is told at its next call. Answers the closed lease.
    public let close: @Sendable (_ module: String, _ by: String) async throws -> Data

    public init(list: @escaping @Sendable () async -> Data,
                close: @escaping @Sendable (_ module: String, _ by: String) async throws -> Data) {
        self.list = list
        self.close = close
    }
}
