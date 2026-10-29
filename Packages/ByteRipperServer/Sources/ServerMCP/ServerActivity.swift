import AgentKit
import Foundation

/// Who is connected to the local MCP, in memory only
/// (`Design/SERVER_HEADLESS_PLAN.md` §7, decision 6): a row per connection —
/// when it came, what is behind it, how many calls and which was last, and
/// when it went. Nothing is written down, and nothing older than the last
/// few finished connections is kept: the console shows what is happening, not
/// a history.
@MainActor
public final class ServerActivity {
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

        public var isOpen: Bool { finished == nil }

        public var id: Int { number }
    }

    /// The most finished connections the list keeps beside the live ones.
    public var keptFinished = 10

    public private(set) var rows: [Row] = []

    public init() {}

    public func opened(number: Int, about: String?) -> Row {
        let row = Row(number: number, about: about, started: Date())
        rows.append(row)
        return row
    }

    public func spoke(_ number: Int) {
        guard let index = rows.firstIndex(where: { $0.number == number }) else { return }
        rows[index].spoke = true
    }

    /// A call has started: what the console's live line says.
    public func started(_ record: AgentCallRecord, connection number: Int) {
        guard let index = rows.firstIndex(where: { $0.number == number }) else { return }
        rows[index].lastTool = record.tool
        rows[index].lastCall = record.started
    }

    /// A call is over: counted, and an error counted again.
    public func finished(_ record: AgentCallRecord, connection number: Int) {
        guard let index = rows.firstIndex(where: { $0.number == number }) else { return }
        rows[index].calls += 1
        rows[index].lastTool = record.tool
        rows[index].lastCall = record.finished
        switch record.outcome {
        case .toolError, .overBound:
            rows[index].errors += 1
        case .answered, .cancelled, .running:
            break
        }
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
}
