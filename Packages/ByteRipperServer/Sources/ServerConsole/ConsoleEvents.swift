import Foundation

/// The server's event log as the Activity page reads it: publishes, leases
/// and the server's own starts and stops (`ActivityLog`). A closure, so the
/// console does not link the store.
public struct ConsoleEvents: Sendable {
    /// `{"events": [...], "last": N}`: the events numbered after `seq`, at
    /// most `limit`, the newest when there are more, and the log's last
    /// number — lower than a reader's means the log began again.
    public let after: @Sendable (_ seq: Int, _ limit: Int) -> Data

    public init(after: @escaping @Sendable (_ seq: Int, _ limit: Int) -> Data) {
        self.after = after
    }
}
