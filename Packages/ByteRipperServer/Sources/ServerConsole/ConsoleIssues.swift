import Foundation

/// The Issues page: what agents reported about the tools, where each stands,
/// and an administrator's step that moves one on. Closures over the Ghidra
/// host's `IssueBook`, so the console needs no Ghidra of its own.
public struct ConsoleIssues: Sendable {
    /// The reports, newest first; closed ones too when `all`.
    public let list: @Sendable (_ all: Bool) async -> Data
    /// The report answered by `by`: it waits on its reporter's confirmation.
    public let resolve: @Sendable (_ id: String, _ by: String, _ note: String?) async throws -> Data
    /// The report moved to `status` by `by`, with a note and, for an
    /// install, the build.
    public let setStatus: @Sendable (_ id: String, _ status: String, _ by: String, _ note: String?,
                                     _ build: String?) async throws -> Data

    public init(list: @escaping @Sendable (_ all: Bool) async -> Data,
                resolve: @escaping @Sendable (_ id: String, _ by: String, _ note: String?) async throws -> Data,
                setStatus: @escaping @Sendable (_ id: String, _ status: String, _ by: String, _ note: String?,
                                                _ build: String?) async throws -> Data) {
        self.list = list
        self.resolve = resolve
        self.setStatus = setStatus
    }
}
