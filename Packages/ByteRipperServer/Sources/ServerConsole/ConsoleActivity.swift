import Foundation
import HTTPService
import ServerAuth

/// The REST clients the console lists, one row per token, in memory only
/// (`Design/SERVER_HEADLESS_PLAN.md` §8, decision 6): how many requests,
/// when last, and what the last one was. The console's own requests are not
/// counted — it is the one looking — and a request no token was accepted for
/// counts on a row of its own, so a stranger knocking shows.
public final class RESTActivity: @unchecked Sendable {
    public struct Row: Equatable, Sendable {
        /// The token's id; empty for requests without an accepted token.
        public let token: String
        public let name: String
        public fileprivate(set) var requests = 0
        /// Answers of 400 and above.
        public fileprivate(set) var refused = 0
        public fileprivate(set) var lastSeen = Date()
        public fileprivate(set) var lastMethod = ""
        public fileprivate(set) var lastPath = ""
        public fileprivate(set) var lastStatus = 0
    }

    public static let anonymous = "without an accepted token"

    private let lock = NSLock()
    private var rows: [String: Row] = [:]

    public init() {}

    public func record(_ activity: HTTPActivity) {
        guard !ServerAuthorizer.isConsole(activity.path) else { return }
        let key = activity.principal?.id ?? ""
        lock.lock()
        defer { lock.unlock() }
        var row = rows[key] ?? Row(token: key, name: activity.principal?.name ?? Self.anonymous)
        row.requests += 1
        if activity.status.code >= 400 { row.refused += 1 }
        row.lastSeen = Date()
        row.lastMethod = activity.method
        row.lastPath = activity.path
        row.lastStatus = activity.status.code
        rows[key] = row
    }

    /// The rows, the latest first.
    public var listed: [Row] {
        lock.lock()
        defer { lock.unlock() }
        return rows.values.sorted { $0.lastSeen > $1.lastSeen }
    }
}

/// Sign-in attempts, one failure a `pause` at most
/// (`Design/SERVER_HEADLESS_PLAN.md` §5): a failed attempt is answered after
/// the pause, and every attempt that arrives meanwhile waits it out. A
/// secret of 32 random bytes is not guessed either way; what this stops is
/// a script hammering the form.
public actor SignInGate {
    private var nextAttempt = Date.distantPast
    public let pause: TimeInterval

    public init(pause: TimeInterval = 1) {
        self.pause = pause
    }

    public func attempt<T: Sendable>(_ body: @Sendable () throws -> T) async throws -> T {
        while Date() < nextAttempt {
            try? await Task.sleep(nanoseconds: UInt64(nextAttempt.timeIntervalSinceNow * 1e9) + 1)
        }
        do {
            return try body()
        } catch {
            nextAttempt = Date().addingTimeInterval(pause)
            try? await Task.sleep(nanoseconds: UInt64(pause * 1e9))
            throw error
        }
    }
}
