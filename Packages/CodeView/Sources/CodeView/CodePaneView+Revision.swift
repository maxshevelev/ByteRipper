import ALSplitView
import AnalysisProfiles
import AppKit
import AppPalette
import CodeAnalysis
import Find
import HelpBook
import HelpUI
import Localization
import ToolModuleKit

// The Code panel against a revision of the module: the description and the C compared.
extension CodePaneView {
    // MARK: - The description against a revision

    /// What the description is compared with once the reader has chosen:
    /// nothing, or a revision. Nil until they choose; a New mark's revision
    /// stands for it then.
    enum DescriptionChoice: Equatable {
        case noComparison
        case against(Int)
    }


    /// The revision the bar shows as compared with: the description's while
    /// it is on screen, the function's otherwise.
    var barRevision: Int? { showsDescription ? descriptionBaseline?.revision : comparisonRevision }

    static let descriptionSeenKey = "description"
    var descriptionFingerprint: String { manifest.reading?.description?.hex ?? "" }

    func allSeenRecords(revision: Int) -> [String: SeenRecord] {
        var records = Self.seenRecords(of: artifact, revision: revision)
        records[Self.descriptionSeenKey] = SeenRecord(revision: revision, fingerprint: descriptionFingerprint)
        return records
    }

    /// The reader has the description in front of them: the next launch must
    /// not put it up as New for what they have just read.
    func noteDescriptionSeen() {
        guard let revision = manifest.reading?.rev else { return }
        seen[Self.descriptionSeenKey] = SeenRecord(revision: revision, fingerprint: descriptionFingerprint)
        if seenLoaded { onSeenChanged?(seen) }
    }

    /// Leaving the description takes its mark; what the mark compared it with
    /// stays, unless the reader has chosen since.
    func leaveDescriptionMark() {
        guard let mark = descriptionMark else { return }
        if descriptionChoice == nil { descriptionChoice = .against(mark) }
        descriptionMark = nil
        noteDescriptionSeen()
        marksChanged()
    }

    /// The reader's pick in the bar while the description is on screen.
    // help: panel.code.diff
    func chooseDescriptionRevision(_ revision: Int?) {
        descriptionChoice = revision.map { .against($0) } ?? .noComparison
        compareDescription(with: revision)
    }

    /// The comparison the description stands for: what the reader chose, or
    /// the revision its New mark is against, or none.
    func applyDescriptionComparison() {
        let wanted: Int?
        switch descriptionChoice {
        case .noComparison: wanted = nil
        case .against(let revision): wanted = revision
        case nil: wanted = descriptionMark
        }
        guard wanted != descriptionBaseline?.revision || (wanted != nil && descriptionBaseline == nil) else { return }
        compareDescription(with: wanted)
    }

    private func compareDescription(with revision: Int?) {
        guard let revision else {
            descriptionBeingRead = nil
            setDescriptionBaseline(nil)
            return
        }
        if let held = descriptionReads[revision] {
            descriptionBeingRead = nil
            setDescriptionBaseline((revision, held))
            return
        }
        guard let onReadDescription else { return }
        descriptionBeingRead = revision
        let work = beginRevisionWork(revision)
        let generation = readingGeneration
        descriptionRead = Task { @MainActor [weak self] in
            let text = await onReadDescription(revision)
            guard let self, self.readingGeneration == generation else { return }
            self.endWork(work)
            guard self.descriptionBeingRead == revision else { return }
            self.descriptionBeingRead = nil
            if let text {
                self.descriptionReads[revision] = text
                self.setDescriptionBaseline((revision, text))
            } else {
                self.selectRevisionItem(nil)
                self.unreadableFunction = self.openFunctionEntry
                self.onRevisionUnreadable?(revision)
            }
        }
    }

    private func setDescriptionBaseline(_ baseline: (revision: Int, text: String)?) {
        descriptionBaseline = baseline
        descriptionView.compare(with: baseline?.text)
        rebuildRevisionMenu()
        updateResetButton()
        updateHeaderForMode()
    }

    /// For a test: what the description is compared with, the diff it shows,
    /// and whether it carries a New mark.
    var descriptionComparisonRevision: Int? { descriptionBaseline?.revision }
    var descriptionDiffCounts: (added: Int, removed: Int)? {
        descriptionView.shownDiff.map { ($0.added, $0.removed) }
    }
    var descriptionTints: [DescriptionTextView.Tint] { descriptionView.tints }
    public var descriptionIsNew: Bool { descriptionMark != nil }
    var descriptionBadgeIsShown: Bool { !descriptionBadgeHolder.isHidden }
    var descriptionBadgeFrame: NSRect { convert(descriptionBadgeHolder.bounds, from: descriptionBadgeHolder) }
    var descriptionButtonFrame: NSRect { convert(descriptionButton.bounds, from: descriptionButton) }

    func drawDescriptionBadge() {
        descriptionBadgeHolder.isHidden = descriptionMark == nil
        moduleBeforeBadge?.isActive = descriptionMark != nil
    }

    /// The book's trailing margin: the pane's padding, badge or none.
    static let bookTrailing: CGFloat = -8

    /// The room between the New badge and the book on its right.
    static let badgeToBook: CGFloat = 4

    /// Back to the code from the description, on the side it was left on.
    func leaveDescription() {
        guard showsDescription else { return }
        mode = codeShowsC ? 1 : 0
        applyMode()
    }
    /// The analyses the header can offer, the chosen one first.
    public var offeredRecipes: [AnalysisManifest] { recipes }

    /// Chooses one of `offeredRecipes`; the app loads its artifact and rebuilds
    /// the screen.
    public func chooseRecipe(at index: Int) {
        guard recipes.indices.contains(index),
              recipes[index].recipe.id != manifest.recipe.id, !isLoadingRecipe else { return }
        // A large module's artifact takes a moment to read: the dropdown
        // waits, with a spinner beside it, until the app replaces this pane
        // with the chosen analysis — or calls `recipeLoadFailed`.
        recipeLine.isEnabled = false
        recipeSpinner.isHidden = false
        recipeSpinner.startAnimation(nil)
        analysisProblem = nil
        recipeWork = beginWork(L("Reading the analysis…"))
        onChooseRecipe?(recipes[index])
    }

    /// Whether an analysis the reader chose is being read.
    public var isLoadingRecipe: Bool { !recipeSpinner.isHidden }

    /// The chosen analysis could not be read: the pane keeps the one it has,
    /// the dropdown says so again, and `problem` — nil for a connection that
    /// failed, which the app shows elsewhere — stays in the dump bar until
    /// another is chosen.
    public func recipeLoadFailed(problem: String? = nil) {
        analysisProblem = problem
        recipeSpinner.stopAnimation(nil)
        recipeSpinner.isHidden = true
        recipeLine.isEnabled = true
        if let recipeWork { endWork(recipeWork) }
        recipeWork = nil
        updateProblemLine()
    }

    /// Switches the navigator: Functions, Strings, POST writes, Status codes.
    public func selectList(_ list: List) {
        guard state.show(list) else { return }
        drawNavigator()
        if list != .functions, state.rowCount > 0 {
            selectNavigatorRow(0)
        }
    }

    /// Filters the list in front. Functions match their name, signature,
    /// address or instruction text; strings and the two call lists match what
    /// they say.
    public func filter(by text: String) {
        searchField.stringValue = text
        state.search(text)
        drawNavigator()
    }

    /// Puts the listing back where a screen that moved container left it:
    /// the function, the instruction and the ASM/C choice.
    /// Puts the reader back where it was: at `location` when this artifact
    /// still has it, otherwise at the indices — what a workspace written
    /// before places were kept by address holds.
    public func restore(at location: CodeLocation? = nil, function: Int?, instruction: Int?,
                        showsC: Bool) {
        var function = function
        var instruction = instruction
        if let location, !location.isEmpty {
            let found = model.indices(of: location)
            if found.function != nil || found.line != nil {
                function = found.function
                instruction = found.line
            }
            // The instruction comes with its function's code, when that does.
            if location.address != nil, let held = found.function, found.line == nil, model.isPending(held) {
                whenRead([held]) { [weak self] in
                    guard let self, self.state.function == held,
                          let line = self.model.indices(of: location).line else { return }
                    self.select(line: line)
                }
            }
        }
        if let function {
            selectFunction(at: function, notify: false)
        }
        if let instruction, model.lines.indices.contains(instruction) {
            select(line: instruction)
        }
        mode = showsC ? 1 : 0
        applyMode()
        resetHistory()
    }

    /// Shows the decompiled C instead of the assembly, or the other way round,
    /// without moving the reader's place: what a Code panel opened with the
    /// listing already showing asks for.
    public func showDecompiledC(_ showsC: Bool) {
        guard showsDecompiledC != showsC || showsDescription else { return }
        mode = showsC ? 1 : 0
        applyMode()
    }

    /// Shows the stale banner. The app calls this when the module's current
    /// bytes no longer match the manifest.
    public func setStale(_ stale: Bool, reason: String? = nil) {
        staleLabel.stringValue = stale
            ? (reason ?? L("The module changed after this analysis."))
            : ""
        staleLabel.isHidden = !stale
    }

    /// Selects a function and its first instruction. A reader's choice also
    /// marks the function's whole stored range as the dump's main zone; it
    /// does not take the selection, which belongs to the reader.
    public func selectFunction(at index: Int, notify: Bool = true) {
        guard model.functions.indices.contains(index) else { return }
        let previous = state.function
        // The function being left keeps the line it was read at; the one
        // arrived at is read from its own, in `updateC` and `updateDiff`.
        if let previous, previous != index, model.functions.indices.contains(previous),
           !model.isPending(previous), let line = currentTopLine() {
            topLines[model.functions[previous].entry.description] = line
        }
        // A caller can point at a function the current search or list hides:
        // show Functions, with the filter cleared, before selecting it.
        revealInNavigator(index)
        state.selectFunction(index)
        redrawCallTree(leaving: previous)
        noteSeen(index)
        // Arriving at a function a revision changed does not take its New
        // mark: the reader sees which function changed while reading it, and
        // the mark goes when they move on to another one. Leaving it is
        // having seen it, and the next launch is told so.
        if let previous, previous != index {
            noteSeen(previous)
            if let taken = unopenedChanges.removeValue(forKey: previous) {
                keepComparison(of: previous, from: taken)
                syncingSelection = true
                functionTable.reloadData()
                syncingSelection = false
                marksChanged()
            }
        }
        // The function's mark says which revision it is new against: opening
        // it compares with that revision, so the reader sees the change the
        // mark is about even after further revisions have arrived.
        applyOpenComparison(for: index)
        updateProblemLine()
        drawSelection()
        if notify, let range = model.moduleRange(ofFunction: index) {
            onFocusRange?(range)
        }
    }

    /// The function on screen, by the entry that outlives a revision.
    public var openFunctionEntry: CodeAddress? {
        guard let index = state.function, model.functions.indices.contains(index) else { return nil }
        return model.functions[index].entry
    }

    /// The comparison each function was left with, for the pane drawn next.
    public var keptComparisons: [CodeAddress: FunctionComparison] { functionComparisons }

    /// Takes the comparisons of the pane before this one. `marks` are the marks
    /// that pane carried: a function wearing a mark it did not is new against a
    /// revision that came since, and that mark is what opening it shows.
    public func restoreComparisons(_ kept: [CodeAddress: FunctionComparison], marks: [NewMark]) {
        let carried = Set(marks.map(\.entry))
        var marked: Set<CodeAddress> = []
        for index in unopenedChanges.keys where model.functions.indices.contains(index) {
            marked.insert(model.functions[index].entry)
        }
        for (entry, comparison) in kept where !marked.contains(entry) || carried.contains(entry) {
            functionComparisons[entry] = comparison
        }
        if let index = state.function { applyOpenComparison(for: index) }
    }

    /// A function that loses its mark having been open keeps what the mark
    /// compared it with, unless the reader has chosen for it since.
    func keepComparison(of index: Int, from mark: NewMark.Baseline) {
        guard mark.revision != nil, model.functions.indices.contains(index) else { return }
        let entry = model.functions[index].entry
        if functionComparisons[entry] == nil { functionComparisons[entry] = .against(mark) }
    }

    /// The comparison an open function stands for: what it was left with, or
    /// the revision its New mark was made against, or none. A function the
    /// earlier revision did not have reads as all added, as the diff of a
    /// function it lacks is.
    func applyOpenComparison(for index: Int) {
        guard model.functions.indices.contains(index) else { return }
        let kept = functionComparisons[model.functions[index].entry]
        let wanted: NewMark.Baseline?
        switch kept {
        case .noComparison: wanted = nil
        case .against(let baseline): wanted = baseline
        case nil: wanted = unopenedChanges[index]
        }
        guard let mark = wanted, let revision = mark.revision else {
            if comparisonRevision != nil { setComparisonRevision(nil, artifact: nil) }
            return
        }
        let entry = model.functions[index].entry
        // The same revision still has to be read again for another function.
        guard comparisonRevision != revision || (baselineReadFor != nil && baselineReadFor != entry) else { return }
        let read = mark.artifact == nil ? readRevisions[RevisionRead(revision: revision, function: entry)] : nil
        guard let held = mark.artifact ?? read else {
            // The code of that revision is read now, the first time something
            // needs it. Until it comes the function reads as it is: another
            // function's comparison would be with the wrong revision.
            if comparisonRevision != nil { setComparisonRevision(nil, artifact: nil) }
            readRevision(revision, function: entry)
            return
        }
        // Told apart only now that the code is here: a record made against
        // another copy of that revision. Nothing changed, so a mark would be
        // about the bookkeeping and not about the function.
        if kept == nil, mark.artifact == nil, Self.holdsTheSame(artifact.functions[index], in: held, now: artifact) {
            takeMark(of: index)
            return
        }
        setComparisonRevision(revision, artifact: held, pinned: false, function: nil,
                              readFor: mark.artifact == nil ? entry : mark.readFor)
    }

    /// Reads a revision's code for the comparison of `function`, and goes on
    /// with the function on screen when it comes.
    private func readRevision(_ revision: Int, function: CodeAddress) {
        let wanted = RevisionRead(revision: revision, function: function)
        guard let onReadRevision, revisionsBeingRead.insert(wanted).inserted else { return }
        revisionReads += 1
        let generation = readingGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let read = await self.whileReadingRevision(revision) {
                await onReadRevision(revision, function)
            }
            guard self.readingGeneration == generation else { return }
            self.revisionsBeingRead.remove(wanted)
            guard let read else { return }
            self.keepRead(read, wanted)
            if let index = self.state.function { self.applyOpenComparison(for: index) }
            self.updateNewMarkBanner()
        }
    }

    /// Keeps the reads made last. Each holds one function's code and the tables
    /// of its revision, so they are not all held for the marks that may ask.
    func keepRead(_ read: CodeArtifact, _ wanted: RevisionRead) {
        readRevisions[wanted] = read
        readOrder.removeAll { $0 == wanted }
        readOrder.append(wanted)
        while readOrder.count > Self.readsKept {
            readRevisions[readOrder.removeFirst()] = nil
        }
    }

    /// Takes a mark that turned out to be about nothing: the reader is as far
    /// along as the code.
    private func takeMark(of index: Int) {
        unopenedChanges[index] = nil
        if let revision = manifest.reading?.rev {
            let function = artifact.functions[index]
            seen[function.entry.description] = SeenRecord(revision: revision,
                                                          fingerprint: Self.fingerprint(of: function))
            if seenLoaded { onSeenChanged?(seen) }
        }
        syncingSelection = true
        functionTable.reloadData()
        syncingSelection = false
        marksChanged()
        applyOpenComparison(for: index)
        updateNewMarkBanner()
    }

    struct RevisionRead: Hashable {
        let revision: Int
        let function: CodeAddress
    }
    private static let readsKept = 8

    /// Marks the selected function's range as the main zone without a click —
    /// what the screen does when it opens on a function.
    public func focusSelectedFunction() {
        guard let function = state.function,
              let range = model.moduleRange(ofFunction: function)
        else { return }
        onFocusRange?(range)
    }

    /// Selects an instruction by its index in the artifact, as a click would.
    public func selectInstruction(at index: Int) {
        guard model.lines.indices.contains(index) else { return }
        select(line: index)
        notifyInstruction()
    }

    /// Selects the instruction covering `range` of the module without moving
    /// the hex view back: the selection came from there.
    public func selectModuleRange(_ range: Range<UInt64>) {
        // The selection the pane asked for itself, for a link to data, says
        // nothing about the code: data is no instruction, and the nearest line
        // before it — a line of some other function — is not where the reader
        // is. Only a selection made in the hex view steers the code.
        guard state.list == .functions, !syncingSelection, !selectingBytes else { return }
        if let pending = model.pendingFunction(forModuleRange: range) {
            whenRead([pending]) { [weak self] in self?.selectModuleRange(range) }
            return
        }
        guard let line = model.line(forModuleRange: range) else { return }
        select(line: line)
    }



    /// The whole stored range of a function, for the hex view and for tests.
    public func moduleRange(forFunction index: Int) -> Range<UInt64>? {
        model.moduleRange(ofFunction: index)
    }

}
