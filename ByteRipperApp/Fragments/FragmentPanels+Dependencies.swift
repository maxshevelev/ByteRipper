import CodeAnalysis
import CodeView
import UEFIImage
import UEFITool

extension FragmentPanels {
    /// A Code panel that did not come by way of the UEFI tree — one a session
    /// brings back as the app starts — reads its module's dependency
    /// expression from the parent dump's tree once that is ready, so its
    /// Interfaces tab shows it as a panel opened from the tree does. The
    /// panel opens at once; the expression follows. A parent with no UEFI
    /// image, or a module the tree does not find, leaves the tab as it is.
    func readDependencies(of codePane: CodePaneView, manifest: AnalysisManifest, from parent: PaneViewModel) {
        guard let storage = parent.document?.storage,
              let tree = parent.uefiState.tree(makeSource: { LiveDocumentByteSource(storage: storage) },
                                               layout: parent.origin?.layout ?? .image)
        else { return }
        let fileName = parent.status.fileName
        Task { @MainActor [weak codePane] in
            await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
            guard codePane?.dependencies == nil,
                  let node = await UEFICodeOpening.imageNode(of: manifest, in: tree, fileName: fileName),
                  let outline = UEFICodeOpening.dependencyOutline(ofModule: node, in: tree, names: .empty),
                  let codePane, codePane.dependencies == nil
            else { return }
            codePane.dependencies = outline
        }
    }
}
