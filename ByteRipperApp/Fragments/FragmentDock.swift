import Foundation

/// The dock of fragment panels a tab has taken out of its files: which panels
/// exist, in what order they sit along the bottom, and which one of them is up
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// Pure, and deliberately ignorant. It holds identity and order and nothing
/// else — no document, no view model, not even a title, because a title copied
/// in here is one that goes stale the moment a Save As renames the document it
/// was copied from. What a panel *is* lives in the surface the controller keeps
/// against its id; what the pill reads is asked of that surface when it is
/// drawn.
///
/// **At most one panel is up.** That is the one invariant, and every method
/// below preserves it rather than leaving it to the caller to maintain.
struct FragmentDock: Equatable {
    /// A panel's identity. The dock makes them and hands them out; nothing is
    /// read off one, and two panels opened on the same part of the same file
    /// are still two panels — the dock does not deduplicate, because opening a
    /// zone twice has always made two documents and this is not the place to
    /// change that.
    struct PanelID: Hashable {
        private let value = UUID()
        fileprivate init() {}
    }

    /// What a mutation did, in the terms the animation is written in: one panel
    /// leaves the stage, another takes it, and because at most one can be up
    /// those two are nearly always the same gesture rather than two that happen
    /// to overlap.
    ///
    /// Handed back rather than left for the caller to work out by diffing the
    /// dock before and after — the diff is where the "fold this, then raise
    /// that, unless they are the same one" mistakes live.
    struct Transition: Equatable {
        /// The panel folding down into its pill.
        var folding: PanelID?
        /// The panel rising from its pill.
        var raising: PanelID?
        /// The panel the dock no longer holds. Its surface is dropped once the
        /// fold has finished, which is why this can arrive together with
        /// `folding` naming the same panel.
        var removed: PanelID?

        /// Nothing moved.
        static let none = Transition()

        var isEmpty: Bool { self == .none }
    }

    /// The panels, in the order they were opened, which is the order the pills
    /// sit in. Nothing reorders them: a dock that shuffles under the pointer is
    /// a dock you have to read every time instead of remembering.
    private(set) var panels: [PanelID] = []

    /// The panel that is up, or nil when the stage is clear and the tab's own
    /// panes are in full view.
    private(set) var expanded: PanelID?

    var isEmpty: Bool { panels.isEmpty }
    var count: Int { panels.count }

    func contains(_ id: PanelID) -> Bool { panels.contains(id) }

    /// Opens a panel at the end of the dock and raises it, folding whatever was
    /// up.
    ///
    /// Raising it is not a choice the caller gets: a part you asked to open and
    /// that appears only as a pill is a part you cannot see, and every route
    /// into this — a zone, a decompressed body, a tool-module handing bytes
    /// over — is someone asking to look at something.
    mutating func open() -> (id: PanelID, transition: Transition) {
        let id = PanelID()
        panels.append(id)
        let folding = expanded
        expanded = id
        return (id, Transition(folding: folding, raising: id))
    }

    /// Raises `id`, folding whatever was up. A panel the dock does not hold, or
    /// the one already up, moves nothing.
    mutating func expand(_ id: PanelID) -> Transition {
        guard panels.contains(id), expanded != id else { return .none }
        let folding = expanded
        expanded = id
        return Transition(folding: folding, raising: id)
    }

    /// Folds the panel that is up, leaving the stage clear. Nothing takes its
    /// place — Esc means "let me see the dump", not "show me the next part".
    mutating func collapse() -> Transition {
        guard let up = expanded else { return .none }
        expanded = nil
        return Transition(folding: up)
    }

    /// Takes `id` out of the dock.
    ///
    /// One method for both ways a panel leaves — closed, or torn off into a tab
    /// of its own — because the dock cannot tell them apart and has no reason
    /// to: either way the pill goes, and either way the surface behind it is
    /// somebody else's to dispose of or to hand over.
    ///
    /// If it was up, the stage is left clear rather than handed to a neighbour.
    /// What the panel was covering is the file it came out of, and the moment
    /// you are most likely to close a fragment is just after putting its bytes
    /// back — raising the next pill would hide the very change you were about
    /// to look at.
    mutating func remove(_ id: PanelID) -> Transition {
        guard let index = panels.firstIndex(of: id) else { return .none }
        panels.remove(at: index)
        guard expanded == id else { return Transition(removed: id) }
        expanded = nil
        return Transition(folding: id, removed: id)
    }
}
