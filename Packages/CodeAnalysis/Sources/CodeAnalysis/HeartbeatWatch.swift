import Foundation

/// What the silence of a server's heartbeat means (`GET /cas/v1/heartbeat`).
///
/// A connection that dies without a word — a tunnel, a Mac gone to sleep — shows
/// in nothing a client is waiting for until that wait times out. A server that
/// pushes every few seconds shows it in the time since the last beat: one beat
/// late is a doubt, several are a lost connection. A server that has no
/// heartbeat at all stays a doubt: its connection cannot be seen, and it has not
/// been seen to fail.
public struct HeartbeatWatch: Equatable, Sendable {
    /// How often a server beats.
    public static let interval: TimeInterval = 5
    /// One beat missed, with room for a slow network.
    public static let doubtfulAfter: TimeInterval = 8
    /// Long enough that a late beat is not taken for a lost connection.
    public static let lostAfter: TimeInterval = 20

    public enum Verdict: Equatable, Sendable {
        case alive
        case doubtful
        case lost
    }

    /// The last beat, or the moment the connection was made; nil before it was.
    private var heard: Date?
    /// The server refused to send a heartbeat: one from before it.
    public private(set) var serverHasNone = false

    public init() {}

    public mutating func beat(at now: Date) {
        heard = now
        serverHasNone = false
    }

    /// The connection was just made: the silence is counted from here.
    public mutating func connected(at now: Date) {
        heard = now
    }

    public mutating func serverHasNoHeartbeat() {
        serverHasNone = true
    }

    public func verdict(at now: Date) -> Verdict {
        if serverHasNone { return .doubtful }
        guard let heard else { return .alive }
        let silence = now.timeIntervalSince(heard)
        if silence >= Self.lostAfter { return .lost }
        return silence >= Self.doubtfulAfter ? .doubtful : .alive
    }
}
