import Foundation

/// The Tickets page: the review board — one ticket per module, the remarks
/// verifying agents made on its review and the replies — and an
/// administrator's say over any status. Closures over the Ghidra host's
/// `TicketBook`, so the console needs no Ghidra of its own.
public struct ConsoleTickets: Sendable {
    /// Every ticket with a remark or a closing, newest activity first.
    public let list: @Sendable () async -> Data
    /// A remark's status set, or the ticket closed or opened, by `by`.
    public let force: @Sendable (_ module: String, _ remark: String?, _ status: String?, _ close: Bool?,
                                 _ note: String?, _ by: String) async throws -> Data

    public init(list: @escaping @Sendable () async -> Data,
                force: @escaping @Sendable (_ module: String, _ remark: String?, _ status: String?, _ close: Bool?,
                                            _ note: String?, _ by: String) async throws -> Data) {
        self.list = list
        self.force = force
    }
}
