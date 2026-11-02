import CodeAnalysis
import CodeView
import Foundation

/// Joins a code pane to the part it reads: an instruction selects its bytes, a
/// byte selection shows the instruction that holds it, and the snapshot says
/// when its module no longer matches — and to the store, whose revisions fill
/// the bar's comparison and mark what a later revision changed.
///
/// The same wiring serves a panel in the dock and a code screen in a tab —
/// the screen changing container must not change how the two halves talk.
/// It is one call on purpose: a container that wires a pane gets the whole
/// seam, so a control cannot be missing because a path was written before it
/// existed. `previous` is the artifact the pane replaced when a later revision
/// of the same reading arrived — the one the bar compares against at once.
@MainActor
func wireCodeScreen(_ codePane: CodePaneView, to pane: PaneViewModel, owner: MainViewController?,
                    previous: (revision: Int, artifact: CodeArtifact)? = nil,
                    reveal: @escaping (Range<UInt64>) -> Void) {
    owner?.filePaneView(for: pane)?.setHeaderAccessory(codePane.titleBarHelp)
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
    // The store's half of the seam: the revisions the bar offers, the New
    // marks a revision left, and the reader's place kept between launches.
    // Every container comes through here, so no pane is drawn without it.
    wireCodeRevisions(codePane, previous: previous)
}

/// Puts what a code screen holds on the pane drawn for it. A screen is the
/// panel's state and a pane only shows it, in a dock or in a tab: every container
/// comes through here, so none of them can lose part of it. The marks go first:
/// the function the place opens on is open, and its mark goes with the selection.
@MainActor
func presentCodeScreen(_ screen: CodeScreen, on codePane: CodePaneView) {
    codePane.setNewMarks(screen.newMarks)
    codePane.restoreComparisons(screen.comparisons, marks: screen.newMarks)
    // Before the place: the function the screen opens on is read from the line
    // it was left at.
    codePane.restoreTopLines(screen.topLines)
    codePane.restore(at: screen.place, function: screen.selectedFunction,
                     instruction: screen.selectedInstruction,
                     showsC: screen.showsC)
    codePane.openCallPlaces(screen.openCalls)
}

/// The dump bar's revision picker: the module's history read from the store,
/// and the code of the revision chosen in it. `previous` is the revision this
/// pane replaced when a later one arrived — it is compared against as soon as
/// the list is read, as the New marks go up with it.
@MainActor
func wireCodeRevisions(_ codePane: CodePaneView,
                       previous: (revision: Int, artifact: CodeArtifact)? = nil) {
    let manifest = codePane.manifest
    let module = manifest.module.sha256
    let recipe = manifest.recipe.id
    var digests: [Int: SHA256Digest] = [:]
    // The records of the last launch, read before anything can write: the
    // pane's own `restore` notes the function it opens on, and that note —
    // taken over a map the pane has not been given yet — would run ahead of
    // this read and leave nothing to compare with.
    let kept = CodeRevisionSeen.records(module: module, recipe: recipe)
    // What the reader has had in front of them is kept function by function,
    // so a revision that arrived while the app was closed still puts the
    // functions it changed up as New — against the code they last saw.
    codePane.onSeenChanged = { records in
        CodeRevisionSeen.save(records, module: module, recipe: recipe)
    }
    codePane.onChooseRevision = { [weak codePane] revision in
        guard let codePane else { return }
        // The function it was picked for: the code may take long enough to
        // read that the reader has moved on.
        let function = codePane.openFunctionEntry
        guard let revision else {
            codePane.setComparisonRevision(nil, artifact: nil, pinned: true, function: function)
            return
        }
        if let previous, previous.revision == revision {
            codePane.setComparisonRevision(revision, artifact: previous.artifact,
                                           pinned: true, function: function)
            return
        }
        guard let digest = digests[revision] else {
            codePane.setComparisonRevision(nil, artifact: nil, pinned: true, function: function)
            return
        }
        Task { @MainActor in
            let artifact = await CodeAnalysisStore.artifact(forRevision: digest)
            codePane.setComparisonRevision(revision, artifact: artifact, pinned: true, function: function)
        }
    }
    let history = Task { @MainActor in await CodeAnalysisStore.revisions(for: manifest) }
    // What a New mark compares with is read when a function asks for it, and
    // for that function: a revision's code is the size of the whole analysis.
    codePane.onReadRevision = { revision, function in
        if let previous, previous.revision == revision { return previous.artifact }
        let options = await history.value.options
        guard let digest = options.first(where: { $0.choice.revision == revision })?.artifact else { return nil }
        return await CodeAnalysisStore.artifact(forRevision: digest, function: function)
    }
    Task { @MainActor in
        let loaded = await history.value
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

        // The functions the last launch saw at another revision than the one
        // on screen are New against the revision their record names, and the
        // records say which without any code. A record whose revision the store
        // holds no code for cannot be compared, and its function waits unseen.
        let named = Set(kept.values.map(\.revision))
        var available = named.intersection(digests.keys)
        var inHand: [Int: CodeArtifact] = [:]
        if let previous, named.contains(previous.revision) {
            available.insert(previous.revision)
            inHand[previous.revision] = previous.artifact
        }
        codePane.restoreSeen(kept, baselines: inHand, available: available)
        // Only a function with no record takes code to judge.
        while let revision = codePane.nextRevisionToSettle {
            let read: CodeArtifact?
            if let digest = digests[revision] {
                read = await CodeAnalysisStore.artifact(forRevision: digest)
            } else {
                read = nil
            }
            codePane.settleUnrecorded(revision: revision, artifact: read)
        }
    }
}
