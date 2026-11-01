import CodeAnalysis
import CodeView
import Foundation

/// Joins a code pane to the part it reads: an instruction selects its bytes, a
/// byte selection shows the instruction that holds it, and the snapshot says
/// when its module no longer matches.
///
/// The same wiring serves a panel in the dock and a code screen in a tab —
/// the screen changing container must not change how the two halves talk.
@MainActor
func wireCodeScreen(_ codePane: CodePaneView, to pane: PaneViewModel, owner: MainViewController?,
                    reveal: @escaping (Range<UInt64>) -> Void) {
    // A note on the code is the person's as one on the dump is: the same
    // form, the same window.
    codePane.onAnnotate = { [weak owner, weak pane] location, name in
        guard let owner, let pane else { return }
        owner.annotateCode(of: pane, at: location, suggesting: name)
    }
    codePane.onOpenNote = { [weak owner, weak pane] id in
        guard let owner, let pane else { return }
        owner.showNotesWindow(leaving: pane)
        NotesWindowController.instance.cards.select(id)
    }
    // A step through a name's uses that came round says so as a search that
    // wrapped does: the same plate, the same sign.
    codePane.onWrapOccurrences = { [weak owner] forward in
        owner?.showWrapNotice(direction: forward ? .forward : .backward)
    }
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

/// The dump bar's revision picker: the module's history read from the store,
/// and the code of the revision chosen in it. `previous` is the revision this
/// pane replaced when a later one arrived — it is compared against as soon as
/// the list is read, as the New marks go up with it.
@MainActor
func wireCodeRevisions(_ codePane: CodePaneView,
                       previous: (revision: Int, artifact: CodeArtifact)? = nil) {
    let manifest = codePane.manifest
    var digests: [Int: SHA256Digest] = [:]
    codePane.onChooseRevision = { [weak codePane] revision in
        guard let codePane else { return }
        guard let revision else {
            codePane.setComparisonRevision(nil, artifact: nil)
            return
        }
        if let previous, previous.revision == revision {
            codePane.setComparisonRevision(revision, artifact: previous.artifact)
            return
        }
        guard let digest = digests[revision] else {
            codePane.setComparisonRevision(nil, artifact: nil)
            return
        }
        Task { @MainActor in
            let artifact = await CodeAnalysisStore.artifact(forRevision: digest)
            codePane.setComparisonRevision(revision, artifact: artifact)
        }
    }
    Task { @MainActor in
        let loaded = await CodeAnalysisStore.revisions(for: manifest)
        let options = loaded.options
        digests = Dictionary(options.map { ($0.choice.revision, $0.artifact) },
                             uniquingKeysWith: { first, _ in first })
        var choices = options.map(\.choice)
        if let previous {
            if let at = choices.firstIndex(where: { $0.revision == previous.revision }) {
                choices[at] = CodePaneView.RevisionChoice(revision: choices[at].revision,
                                                          title: choices[at].title, hasCode: true)
            } else {
                choices.insert(CodePaneView.RevisionChoice(revision: previous.revision,
                                                           title: "r\(previous.revision)", hasCode: true),
                               at: 0)
            }
        }
        codePane.setRevisionChoices(choices, current: manifest.reading?.rev, knowsRevisions: loaded.hasHistory)
        if let previous {
            codePane.setComparisonRevision(previous.revision, artifact: previous.artifact, automatic: true)
        }
    }
}
