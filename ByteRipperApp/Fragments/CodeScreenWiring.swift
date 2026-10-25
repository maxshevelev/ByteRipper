import CodeView
import Foundation

/// Joins a code pane to the part it reads: an instruction selects its bytes, a
/// byte selection shows the instruction that holds it, and the snapshot says
/// when its module no longer matches.
///
/// The same wiring serves a panel in the dock and a code screen in a tab —
/// the screen changing container must not change how the two halves talk.
@MainActor
func wireCodeScreen(_ codePane: CodePaneView, to pane: PaneViewModel,
                    reveal: @escaping (Range<UInt64>) -> Void) {
    codePane.onSelectRange = { [weak pane] range in
        guard let pane else { return }
        pane.select(range: range)
        reveal(range)
    }
    // A function is a stretch of the dump to look at, not a selection to
    // replace: it becomes the focused zone, the dump's main highlight.
    codePane.onFocusRange = { [weak codePane, weak pane] range in
        guard let pane else { return }
        pane.focusCodeRange(range, named: codePane?.selectedFunction?.name ?? "")
        reveal(range)
    }
    // The hex view's own selection callback stays its own; the code screen
    // observes the selection through a second channel, so this join can be
    // made again for a screen that moved container without stacking copies.
    pane.onSelectionObserved = { [weak codePane, weak pane] in
        guard let pane else { return }
        let selection = pane.hexSelection()
        codePane?.setStale(pane.origin.map { $0.state != .intact } ?? false)
        codePane?.selectModuleRange(selection.start..<selection.end)
    }
    let selection = pane.hexSelection()
    codePane.setStale(pane.origin.map { $0.state != .intact } ?? false)
    codePane.selectModuleRange(selection.start..<selection.end)
}
