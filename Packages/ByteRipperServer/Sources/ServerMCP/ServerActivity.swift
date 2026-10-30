import AgentKit
import Foundation

/// Who is connected to the local MCP, in memory only
/// (`Design/SERVER_HEADLESS_PLAN.md` §7, decision 6): a row per open
/// connection — when it came, what is behind it, how many calls and which was
/// last, with the recent calls themselves so the console shows what a
/// connection is doing while it does it. A connection that closes takes its
/// row with it: the console shows what is happening, not a history.
@MainActor
public final class ServerActivity {
    /// One call of a connection's log: the record a call is given when it
    /// starts, replaced by its finished one under the same id.
    public struct Call: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let tool: String
        public let started: Date
        /// The call's arguments as compact JSON, cut at `argumentsLimit`
        /// characters: what the console's log shows of the question.
        public fileprivate(set) var arguments = ""
        /// How long the answer was, once there is one.
        public fileprivate(set) var answerBytes: Int?
        public fileprivate(set) var finished: Date?
        public fileprivate(set) var duration: TimeInterval = 0
        /// "running", "answered", "error", "cancelled" or "over bound".
        public fileprivate(set) var outcome = "running"
        /// The tool's own words when it could not answer.
        public fileprivate(set) var detail: String?

        public var isRunning: Bool { finished == nil }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let number: Int
        /// The process behind the connection, when the system says.
        public let about: String?
        public let started: Date
        /// Whether the client has sent anything: a relay started and
        /// abandoned holds a connection and never speaks.
        public fileprivate(set) var spoke = false
        public fileprivate(set) var calls = 0
        /// Calls that ended in a tool error or an over-long answer.
        public fileprivate(set) var errors = 0
        public fileprivate(set) var lastTool: String?
        public fileprivate(set) var lastCall: Date?
        /// The recent calls, oldest first, at most `keptCalls`.
        public fileprivate(set) var log: [Call] = []

        /// Whether a tool is working on a call right now.
        public var isWorking: Bool { log.contains(where: \.isRunning) }

        /// Whether the agent is at work, as the app's toolbar dot says it
        /// (`AgentService.isActive`): a call running, or one that ended less
        /// than `activityHold` ago. A call often takes a few milliseconds; held
        /// a moment after each, a run of calls reads as one stretch of work.
        public func isActive(at now: Date = Date()) -> Bool {
            if isWorking { return true }
            guard let last = lastCall else { return false }
            return now.timeIntervalSince(last) < ServerActivity.activityHold
        }

        public var id: Int { number }
    }

    /// How long a connection counts as at work after its last call: the app's
    /// `AgentService.activityHold`.
    public nonisolated static let activityHold: TimeInterval = 2
    /// How much of a call's arguments its log line keeps.
    public nonisolated static let argumentsLimit = 2048

    /// How many calls a connection's log keeps. Older ones go: the console
    /// shows what is happening, not a history.
    public var keptCalls = 50

    public private(set) var rows: [Row] = []

    public init() {}

    @discardableResult
    public func opened(number: Int, about: String?) -> Row {
        let row = Row(number: number, about: about, started: Date())
        rows.append(row)
        return row
    }

    public func spoke(_ number: Int) {
        guard let index = rows.firstIndex(where: { $0.number == number }) else { return }
        rows[index].spoke = true
    }

    /// A call has started: what the console's live line says, and a line in
    /// the connection's log that a spinner sits beside until it ends.
    public func started(_ record: AgentCallRecord, connection number: Int) {
        guard let index = rows.firstIndex(where: { $0.number == number }) else { return }
        rows[index].lastTool = record.tool
        rows[index].lastCall = record.started
        rows[index].log.append(Call(id: record.id, tool: record.tool, started: record.started,
                                    arguments: Self.arguments(record.arguments)))
        trim(&rows[index])
    }

    /// A call is over: its log line takes the answer in place of the spinner,
    /// and the counters move.
    public func finished(_ record: AgentCallRecord, connection number: Int) {
        guard let index = rows.firstIndex(where: { $0.number == number }) else { return }
        var row = rows[index]
        let call = Self.call(record)
        if let position = row.log.firstIndex(where: { $0.id == record.id }) {
            row.log[position] = call
        } else {
            row.log.append(call)
        }
        trim(&row)
        row.calls += 1
        row.lastTool = record.tool
        row.lastCall = record.finished
        switch record.outcome {
        case .toolError, .overBound:
            row.errors += 1
        case .answered, .cancelled, .running:
            break
        }
        rows[index] = row
    }

    /// A connection is gone: its row goes with it. What it did is read while
    /// it was open; a card that stays after the client left would be a
    /// history, and this is not one.
    public func closed(_ number: Int) {
        rows.removeAll { $0.number == number }
    }

    /// The rows the console shows: the open connections.
    public var listed: [Row] { rows }

    /// `value` as compact JSON, cut with an ellipsis past `argumentsLimit`.
    nonisolated static func arguments(_ value: JSONValue) -> String {
        let text = value.jsonText
        guard text.count > argumentsLimit else { return text }
        return String(text.prefix(argumentsLimit)) + "…"
    }

    private func trim(_ row: inout Row) {
        if row.log.count > keptCalls { row.log.removeFirst(row.log.count - keptCalls) }
    }

    private static func call(_ record: AgentCallRecord) -> Call {
        var call = Call(id: record.id, tool: record.tool, started: record.started,
                        arguments: arguments(record.arguments), answerBytes: record.answerBytes,
                        finished: record.finished, duration: seconds(record.duration))
        switch record.outcome {
        case .answered:
            call.outcome = "answered"
        case .toolError(let message):
            call.outcome = "error"
            call.detail = message
        case .overBound:
            call.outcome = "over bound"
        case .cancelled:
            call.outcome = "cancelled"
        case .running:
            call.outcome = "running"
            call.finished = nil
        }
        return call
    }

    /// `Duration` as the seconds a console counts in.
    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
