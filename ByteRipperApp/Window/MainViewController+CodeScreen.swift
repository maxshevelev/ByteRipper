import AppKit
import CodeAnalysis
import CodeView
import Localization
import PartCodec

/// The tab as a module's code screen (`Design/CODE_PANEL_PLAN.md`): opening
/// one, drawing it in single-file mode, leaving it for a comparison or another
/// document, and carrying it whole when its pane moves to another tab.
///
/// The state is `MainViewController`'s own (`codeScreen`, `codeScreenView`);
/// what to do with it is here, apart from the eight thousand lines of the
/// window's other work.
extension MainViewController {
    /// Releases the tab's code screen whole, when the pane leaving is the one
    /// it belongs to. A code tab torn off into another tab must stay a code
    /// tab; parting with the pane alone would make it a plain dump.
    func releasePanel(at index: Int) -> PanelContent? {
        captureCodeScreenState()
        guard index == 0, let code = codeScreen,
              code.pane === windowModel.pane1 else { return nil }
        let marks = windowModel.bookmarkStore.bookmarks
        let pane = releasePane(at: index)
        return PanelContent(pane: pane, bookmarks: marks, screen: .code(code.screen))
    }

    /// Keeps what the reader chose in the code pane — the function, the
    /// instruction, the ASM/C side — in the screen the tab carries, before the
    /// view that knows it goes away.
    func captureCodeScreenState() {
        guard var code = codeScreen, let view = codeScreenView else { return }
        code.screen.selectedFunction = view.selectedFunctionIndex
        code.screen.selectedInstruction = view.selectedInstructionIndex
        code.screen.place = view.selectedLocation
        code.screen.showsC = view.showsDecompiledC
        codeScreen = code
    }

    /// The code screen `pane` is showing, in this tab or in a panel over it.
    func codeScreen(for pane: PaneViewModel) -> CodeScreen? {
        if let codeScreen, codeScreen.pane === pane {
            return codeScreen.screen
        }
        return fragments.codeScreen(holding: pane)
    }

    /// The tab's code screen as it stands, for the workspace. Nil while the
    /// tab is showing something else — a comparison, or a new document — even
    /// if the screen's analysis is still remembered for a return.
    func currentCodeScreen() -> CodeScreen? {
        guard codeScreenView != nil else { return nil }
        captureCodeScreenState()
        return codeScreen?.screen
    }

    /// Makes `pane` this tab's code screen — its bytes and the analysis the
    /// workspace restored — so the next mode apply draws it as Code.
    func installCodeScreen(_ screen: CodeScreen, on pane: PaneViewModel) {
        codeScreen = (pane, pane.document, screen)
    }

    /// Another analysis of the module, chosen in the header. The store supplies
    /// its artifact; the tab then rebuilds the same screen with it, keeping the
    /// function, instruction and ASM/C side.
    func chooseCodeRecipe(_ manifest: AnalysisManifest, for pane: PaneViewModel) {
        guard let current = codeScreen, current.pane === pane else { return }
        captureCodeScreenState()
        guard let current = codeScreen else { return }
        let screen = current.screen
        let dumpVisible = codeScreenView?.isHexDumpVisible ?? true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let artifact = await CodeAnalysisStore.artifact(for: manifest) else {
                self.codeScreenView?.recipeLoadFailed()
                self.reportCodeAnalysisUnreadable()
                return
            }
            let next = CodeScreen(manifest: manifest, artifact: artifact,
                                  bytes: screen.bytes,
                                  selectedFunction: screen.selectedFunction,
                                  selectedInstruction: screen.selectedInstruction,
                                  place: screen.place,
                                  showsC: screen.showsC,
                                  recipes: screen.recipes)
            self.codeScreen = (pane, pane.document, next)
            self.apply(mode: .singleFile)
            self.codeScreenView?.setHexDumpVisible(dumpVisible, animated: false)
        }
    }

    /// Opens a module's bytes with its stored code pane beside them
    /// (`Design/CODE_PANEL_PLAN.md`). The codec is the read-only one the
    /// UEFI panel handed over: the bytes open as a part, and Update in Parent
    /// refuses them with the analysis's reason.
    ///
    /// A Code panel of the same module already open over `pane` is raised and
    /// moved to `location` rather than opened twice. Returns the panel.
    @discardableResult
    func openCode(named name: String, from pane: PaneViewModel, source: Range<UInt64>,
                  manifest: AnalysisManifest, artifact: CodeArtifact,
                  recipes: [AnalysisManifest] = [], codec: any PartCodec,
                  at location: CodeLocation? = nil) -> FragmentDock.PanelID? {
        if let open = fragments.codePanel(module: manifest.module.sha256, over: pane) {
            fragments.expand(open)
            if let location, !location.isEmpty { fragments.codePane(open)?.go(to: location) }
            return open
        }
        guard let document = pane.document,
              let content = try? DocumentPartReader(document: document)
        else { return nil }
        let parent = PartParent(content: content, source: source, name: pane.status.fileName,
                                partName: name)
        do {
            let bytes = try codec.decode(parent)
            guard let origin = DocumentOrigin(
                parent: pane, source: source, partName: name,
                layout: .image, codec: codec, content: bytes)
            else { return nil }
            return fragments.openCode(bytes, named: name, origin: origin,
                                      manifest: manifest, artifact: artifact,
                                      recipes: recipes, at: location)
        } catch {
            let refusal = error as? PartRefusal
            presentAlert(title: refusal?.title.text ?? L("Those bytes could not be read."),
                         message: refusal?.message.text ?? "\(error)", outcome: .problem)
            return nil
        }
    }

    /// A recipe chosen from the panel's header names an artifact the store no
    /// longer has, or cannot read.
    func reportCodeAnalysisUnreadable() {
        presentAlert(title: L("The code analysis could not be read."),
                     message: L("The stored analysis is missing or cannot be read. The panel keeps the analysis it has."),
                     outcome: .problem)
    }

    /// The code pane drawing `pane`: the tab's code screen, or a code panel.
    func codePaneView(for pane: PaneViewModel) -> CodePaneView? {
        if let codeScreen, codeScreen.pane === pane { return codeScreenView }
        return fragments.panel(holding: pane).flatMap { fragments.codePane($0) }
    }

    /// Hands every code pane of this tab the annotations on its module's code,
    /// from whatever dump they were made on: a note is about the code, and
    /// the same module's code is the same wherever it is.
    func applyCodeNotes() {
        let annotations = AgentAnnotationTools.current?.all() ?? []
        for pane in [codeScreenView].compactMap({ $0 }) + fragments.codePanes {
            let module = pane.manifest.module.sha256.hex
            pane.setNotes(annotations.compactMap { annotation in
                guard let code = annotation.code, code.module == module else { return nil }
                return CodeNote(id: annotation.id, title: annotation.title, note: annotation.note,
                                location: code.location, byPerson: annotation.author == .person)
            })
        }
    }

    /// The code pane that has the keyboard — the tab's code screen or a code
    /// panel in the dock — when one has.
    ///
    /// Failing that, the code in front: a Code panel raised over the dump, or
    /// the tab's own code screen with no panel over it. A click on a link
    /// leaves the keyboard where it was, and ⌘[ must still walk the code the
    /// reader is looking at, not the dump behind it.
    func focusedCodePane() -> CodePaneView? {
        let panes = [codeScreenView].compactMap { $0 } + fragments.codePanes
        if let responder = view.window?.firstResponder as? NSView,
           let focused = panes.first(where: { responder.isDescendant(of: $0) }) {
            return focused
        }
        if let front = fragments.expanded {
            return fragments.codePane(front)
        }
        return codeScreenView
    }

    // MARK: - Drawing the screen

    /// The single-file content of a code screen: the pane's title bar across
    /// the top, then the functions, the code and the bytes. The functions are
    /// the screen: no tool strip, no map, exactly as in the dock.
    func codeScreenContent(_ screen: CodeScreen, in pane: FilePaneView,
                           of paneModel: PaneViewModel) -> NSView {
        paneModel.panelBadge = .code
        if minimapVisibleBeforeCode == nil {
            minimapVisibleBeforeCode = surface.minimap.isPanelVisible
        }
        surface.tools.activate(nil, animated: false, movesWindow: false)
        surface.tools.allowsSelection = false
        surface.minimap.setPanelVisible(false, animated: false)
        let codePane = CodePaneView(manifest: screen.manifest,
                                    artifact: screen.artifact,
                                    moduleBytes: screen.bytes,
                                    hexView: pane,
                                    recipes: screen.recipes)
        codeScreenView = codePane
        codePane.onChooseRecipe = { [weak self, weak paneModel] manifest in
            guard let self, let paneModel else { return }
            self.chooseCodeRecipe(manifest, for: paneModel)
        }
        wireCodeScreen(codePane, to: paneModel, owner: self) { [weak self, weak paneModel] range in
            guard let paneModel else { return }
            self?.filePaneView(for: paneModel)?
                .revealOffsetCentered(range.lowerBound)
        }
        applyCodeNotes()
        codePane.restore(at: screen.place, function: screen.selectedFunction,
                         instruction: screen.selectedInstruction,
                         showsC: screen.showsC)
        codePane.focusSelectedFunction()
        // The file name belongs to the whole window, not to the strip
        // over the bytes: take the pane's title bar out and lay it
        // across the top, as a fragment panel does. The window closes
        // the tab, so the pane's own ✕ would be a second close.
        pane.hidesCloseButton = true
        let header = pane.hoistHeader()
        let container = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        codePane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(codePane)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            codePane.topAnchor.constraint(equalTo: header.bottomAnchor),
            codePane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            codePane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            codePane.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    /// Puts an ordinary dump's chrome back on a pane that was a code screen:
    /// its own title bar and close button, the tool strip and the map.
    func leaveCodeScreen(in pane: FilePaneView, of paneModel: PaneViewModel) {
        if pane.isHeaderHoisted {
            pane.restoreHeader()
            pane.hidesCloseButton = false
        }
        codeScreenView = nil
        paneModel.panelBadge = nil
        restoreChromeAfterCodeScreen()
    }

    /// A code screen is single-file: while a second pane is up, the tab is an
    /// ordinary comparison and its tools are its own again. The screen is
    /// remembered for the return to one pane.
    func leaveCodeScreenForComparison() {
        captureCodeScreenState()
        codeScreenView = nil
        if let code = codeScreen {
            let view = paneView(for: code.pane)
            if view.isHeaderHoisted {
                view.restoreHeader()
                view.hidesCloseButton = false
            }
        }
        codeScreen?.pane.panelBadge = nil
        restoreChromeAfterCodeScreen()
    }

    private func restoreChromeAfterCodeScreen() {
        surface.tools.allowsSelection = true
        if let wasVisible = minimapVisibleBeforeCode {
            minimapVisibleBeforeCode = nil
            surface.minimap.setPanelVisible(wasVisible, animated: false)
        }
    }
}
