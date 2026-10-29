import AgentKit
import Foundation

/// Who is connected to the local MCP, in memory only
/// (`Design/SERVER_HEADLESS_PLAN.md` §7, decision 6): a row per connection —
/// when it came, what is behind it, how many calls and which was last, and
/// when it went, with the recent calls themselves so the console shows what a
/// connection is doing while it does it. Nothing is written down, and nothing
/// older than the last few finished connections is kept: the console shows
/// what is happening, not a history.
@MainActor
public final class ServerActivity {
    /// One call of a connection's log: the record a call is given when it
    /// starts, replaced by its finished one under the same id.
    public struct Call: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let tool: String
        public let started: Date
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
        public fileprivate(set) var finished: Date?
        /// The recent calls, oldest first, at most `keptCalls`.
        public fileprivate(set) var log: [Call] = []

        public var isOpen: Bool { finished == nil }

        /// Whether a tool is working on a call right now.
        public var isWorking: Bool { log.contains(where: \.isRunning) }

        public var id: Int { number }
    }

    /// The most finished connections the list keeps beside the live ones.
    public var keptFinished = 10
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
        rows[index].log.append(Call(id: record.id, tool: record.tool, started: record.started))
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

    public func closed(_ number: Int) {
        guard let index = rows.firstIndex(where: { $0.number == number }) else { return }
        rows[index].finished = Date()
        let finished = rows.indices.filter { rows[$0].finished != nil }
        for index in finished.dropLast(keptFinished).reversed() { rows.remove(at: index) }
    }

    /// The rows the console shows: live ones first, the last finished after.
    public var listed: [Row] {
        rows.filter(\.isOpen) + rows.filter { !$0.isOpen }
    }

    private func trim(_ row: inout Row) {
        if row.log.count > keptCalls { row.log.removeFirst(row.log.count - keptCalls) }
    }

    private static func call(_ record: AgentCallRecord) -> Call {
        var call = Call(id: record.id, tool: record.tool, started: record.started,
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
