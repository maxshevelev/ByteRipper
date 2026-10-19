import Cocoa
import Localization
import UniformTypeIdentifiers
import Workspace

/// Projects (`Design/WORKSPACE_PLAN.md`, "Projects"): a workspace kept in a
/// file the person names, `.brp`, and switched between.
///
/// A project is live. While it is open everything is recorded into it —
/// the tabs, the untitled documents, the unsaved changes of its files — so
/// leaving it asks nothing: switching to another project, closing it, or
/// quitting. Only the session without a project asks, when a project is about
/// to replace it.
extension AppDelegate {
    /// The open project's package, or nil for the session without one.
    var currentProject: URL? { workspaceRecorder?.project?.url }

    /// Whether quitting keeps the windows for the next launch — a project
    /// always, the session when it is restored — and closing the last window
    /// is therefore a quit rather than an emptying.
    var keepsWindowsAtQuit: Bool {
        workspaceRecorder != nil && (currentProject != nil || WorkspaceSettings.restoresWorkspace)
    }

    /// The project's name as windows show it.
    var currentProjectName: String? {
        currentProject.map { ($0.lastPathComponent as NSString).deletingPathExtension }
    }

    // MARK: - Menu commands

    /// File ▸ Save as Project…: the session — or the open project — written
    /// into a new project, which is then the one open.
    // help: menu.file.save-as-project
    @objc func saveAsProject(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.byteRipperProject]
        panel.nameFieldStringValue = currentProjectName ?? L("Project")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveSession(asProjectAt: url)
    }

    /// File ▸ Open Recent Project ▸ a project.
    @objc func openRecentProject(_ sender: Any?) {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String else { return }
        openProject(at: URL(fileURLWithPath: path))
    }

    @objc func clearRecentProjects(_ sender: Any?) {
        RecentProjectsStore.clear()
    }

    /// File ▸ Close Project: the project is left as it is — everything in it
    /// is already written — and the app goes back to an empty session.
    // help: menu.file.close-project
    @objc func closeProject(_ sender: Any?) {
        guard let recorder = workspaceRecorder, recorder.project != nil else { return }
        recorder.record()
        closeEverythingKept()
        recorder.switchTo(project: nil)
        RecentProjectsStore.lastProject = nil
        makeWindow()
        refreshProjectName()
    }

    // MARK: - Saving

    /// Writes the current windows into a project at `url` and makes it the
    /// open one. A package already there is replaced: the save panel asked.
    @discardableResult
    func saveSession(asProjectAt url: URL) -> Bool {
        guard let recorder = workspaceRecorder else { return false }
        let wasProject = recorder.project != nil
        // The project being left keeps what it had up to now.
        recorder.record()
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        recorder.switchTo(project: WorkspaceFolder.project(at: url))
        recorder.record()
        guard FileManager.default.fileExists(atPath: WorkspaceFolder.project(at: url).fileURL.path) else {
            presentProjectError(L("The project could not be written."), url: url)
            return false
        }
        // The session without a project is this project now.
        if !wasProject { recorder.discardSession() }
        projectOpened(url)
        return true
    }

    // MARK: - Opening

    /// Opens the project at `url` in place of what is open now. The open
    /// project is left as it stands; a session without a project that holds
    /// anything is offered to be saved as one first.
    func openProject(at url: URL) {
        guard let recorder = workspaceRecorder else { return }
        if let current = currentProject, current.standardizedFileURL == url.standardizedFileURL {
            windowControllers.last?.window?.makeKeyAndOrderFront(nil)
            return
        }
        let folder = WorkspaceFolder.project(at: url)
        guard let workspace = folder.read() else {
            presentProjectError(L("The project could not be read."), url: url)
            return
        }
        leaveCurrentSession { [weak self] in
            guard let self else { return }
            recorder.switchTo(project: folder)
            if !self.rebuild(workspace, with: recorder) {
                self.makeWindow()
            }
            self.projectOpened(url)
        }
    }

    /// Clears the screen for another project: the open project is written and
    /// its windows go without a question; the session without a project asks
    /// whether to keep it as a project, and otherwise goes the ordinary way,
    /// asking about what would be lost. `then` runs once the screen is clear;
    /// not at all when the person cancelled.
    private func leaveCurrentSession(then proceed: @escaping () -> Void) {
        guard let recorder = workspaceRecorder else { return }
        if recorder.project != nil {
            recorder.record()
            closeEverythingKept()
            proceed()
            return
        }
        guard sessionHoldsAnything else {
            closeEverythingKept()
            proceed()
            return
        }
        switch askToSaveSessionAsProject() {
        case .alertFirstButtonReturn:  // Save…
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.byteRipperProject]
            panel.nameFieldStringValue = L("Project")
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url, saveSession(asProjectAt: url) else { return }
            recorder.record()
            closeEverythingKept()
            proceed()
        case .alertSecondButtonReturn:  // Don't Save
            askToClose(windowControllers, keeping: { _ in false }) { [weak self] agreed in
                guard agreed, let self else { return }
                self.closeEverythingKept()
                recorder.discardSession()
                proceed()
            }
        default:
            break
        }
    }

    /// Whether the session without a project has anything a project would
    /// keep: a file in some tab, a panel, or the Annotations window.
    private var sessionHoldsAnything: Bool {
        NotesWindowController.isOpen || windowControllers.contains {
            $0.mainViewController.windowModel.hasOpenFile || !$0.mainViewController.fragments.isEmpty
        }
    }

    private func askToSaveSessionAsProject() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = L("Save the current session as a project?")
        alert.informativeText = L("Opening a project closes what is open now. Saved as a project, it can be opened again as it is.")
        alert.addButton(withTitle: L("Save…"))
        alert.addButton(withTitle: L("Don't Save"))
        alert.addButton(withTitle: L("Cancel"))
        return MainViewController.presentModal(alert, defaultInTest: .alertThirdButtonReturn)
    }

    /// Closes every window without asking: whatever they hold is written
    /// already, into the project being left, or was answered for.
    private func closeEverythingKept() {
        isSwitchingProjects = true
        defer { isSwitchingProjects = false }
        workspaceRecorder?.isPaused = true
        defer { workspaceRecorder?.isPaused = false }
        for controller in windowControllers {
            controller.window?.close()
        }
        NotesWindowController.shared?.window?.close()
    }

    private func projectOpened(_ url: URL) {
        RecentProjectsStore.record(url)
        RecentProjectsStore.lastProject = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshProjectName()
    }

    /// Every window says which project it belongs to.
    func refreshProjectName() {
        for controller in windowControllers {
            controller.mainViewController.projectName = currentProjectName
        }
    }

    private func presentProjectError(_ message: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = url.path
        alert.addButton(withTitle: L("OK"))
        _ = MainViewController.presentModal(alert, defaultInTest: .alertFirstButtonReturn)
    }
}
