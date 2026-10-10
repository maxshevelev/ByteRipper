import AgentKit
import Foundation
import Localization
import ToolModuleKit

/// One tool an agent is offered, as the Agent window's Tools page lists it:
/// the tool as the agent sees it, where it comes from and what it does to
/// the world.
struct AgentToolEntry {
    let tool: AgentTool
    let group: AgentToolGroup
    let kind: AgentToolKind
}

/// Where a tool comes from: a part of the host, or a tool-module.
enum AgentToolGroup {
    case files, marks, dumps, comparison, search, edits, panels
    case module(any ToolModule.Type)

    var title: String {
        switch self {
        case .files: return L("Files and View")
        case .marks: return L("Marks")
        case .dumps: return L("Dumps and Findings")
        case .comparison: return L("Comparison")
        case .search: return L("Search")
        case .edits: return L("Edits")
        case .panels: return L("Tool Panels")
        case .module(let module): return module.title
        }
    }

    var isEdits: Bool {
        if case .edits = self { return true }
        return false
    }
}

/// What a tool does: reads, changes what is on screen (the view, a mark, a
/// finding, a tab), or changes a file.
enum AgentToolKind {
    case read, screen, edit

    var title: String {
        switch self {
        case .read: return L("Read")
        case .screen: return L("On Screen")
        case .edit: return L("Edits a File")
        }
    }
}

/// How a tool has been used since the app started.
struct AgentToolStats: Equatable {
    var calls = 0
    /// Calls that did not answer: refused, too long to send, withdrawn.
    var failures = 0
    var total: Duration = .zero
    var longest: Duration = .zero
    var answerBytes = 0
    var last: Date?

    var average: Duration? { calls == 0 ? nil : total / calls }

    mutating func add(_ record: AgentCallRecord) {
        calls += 1
        if case .answered = record.outcome {} else { failures += 1 }
        total += record.duration
        longest = max(longest, record.duration)
        answerBytes += record.answerBytes
        last = record.finished
    }
}
