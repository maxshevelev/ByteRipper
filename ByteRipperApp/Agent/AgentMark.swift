import Foundation

/// A place an agent marked in a dump and what it said about it
/// (`Design/AGENT_PLAN.md`, "Marks").
///
/// A layer of its own on the pane, not a zone: zones belong to the tool-module
/// session that published them and go when it stops, and an agent's mark has
/// to outlive the panel — it is what the agent is talking about. It goes when
/// the agent removes it, when the person clears it in the Agent window, or
/// when the document it is in closes.
struct AgentMark: Equatable {
    /// `m1`, `m2`… — what the agent removes it and relates others to it by.
    let id: String
    /// Half-open, in the document's own addresses.
    let range: Range<UInt64>
    /// A few words: what the bytes are.
    let label: String
    /// A sentence or two: why they matter. Shown when the pointer rests on
    /// the bytes, and in the Agent window.
    let note: String
    /// The marks this one is about — a pointer and what it points at, a
    /// checksum and what it covers. Each pair is shown with both ends
    /// clickable.
    let relatedTo: [String]

    /// What the pointer resting on the bytes shows.
    var tooltip: String {
        note.isEmpty ? label : label + "\n" + note
    }
}
