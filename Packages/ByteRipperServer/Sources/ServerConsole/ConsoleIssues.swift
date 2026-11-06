import Foundation

/// The Issues page: what agents reported about the tools, and an
/// administrator's mark that one is dealt with. Closures over the Ghidra
/// host's `IssueBook`, so the console needs no Ghidra of its own.
public struct ConsoleIssues: Sendable {
    /// The reports, newest first; resolved ones too when `all`.
    public let list: @Sendable (_ all: Bool) async -> Data
    /// The report marked resolved by `by`, with an optional note.
    public let resolve: @Sendable (_ id: String, _ by: String, _ note: String?) async throws -> Data

    public init(list: @escaping @Sendable (_ all: Bool) async -> Data,
                resolve: @escaping @Sendable (_ id: String, _ by: String, _ note: String?) async throws -> Data) {
        self.list = list
        self.resolve = resolve
    }
}
