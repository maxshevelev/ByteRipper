import Cocoa
import Localization

/// Whether the app brings its workspace back at launch: the tabs and the files
/// in them, where each pane was scrolled to and what was selected, the
/// bookmarks, the segments and the tool panels (`Design/WORKSPACE_PLAN.md`).
///
/// Mirrors the `EditingSettings` pattern — read live from `UserDefaults`,
/// written through `set`. There is no notification: the value is read at quit,
/// to decide whether to write the workspace down, and at launch, to decide
/// whether to read it back.
enum WorkspaceSettings {
    static let restoresWorkspaceKey = "RestoresWorkspaceOnLaunch"

    /// Off by default: a hex editor that reopens last week's dumps unasked is
    /// a surprise on a repair bench, where every job is a different board.
    static var restoresWorkspace: Bool {
        AppDefaults.store.bool(forKey: restoresWorkspaceKey)
    }

    static func set(restoresWorkspace: Bool) {
        AppDefaults.store.set(restoresWorkspace, forKey: restoresWorkspaceKey)
    }

    /// Restores the built-in default (used by tests).
    static func resetToDefaults() {
        AppDefaults.store.removeObject(forKey: restoresWorkspaceKey)
    }
}

/// The General tab of the Settings window: what the program does rather than
/// how it looks — whether the workspace comes back at launch, how differences
/// are grouped, and whether the edits that shift the file ask first.
///
/// Comparison and Editing were tabs of their own, one control each; with the
/// workspace switch they make one page, and it comes first, as General does in
/// the system's own settings windows.
final class GeneralSettingsViewController: SectionedSettingsViewController {
    private let workspaceController = WorkspaceSettingsViewController()
    private let comparisonController = ComparisonSettingsViewController()
    private let editingController = EditingSettingsViewController()

    /// The sections, for the tests that drive them.
    var workspace: WorkspaceSettingsViewController { workspaceController }
    var comparison: ComparisonSettingsViewController { comparisonController }
    var editing: EditingSettingsViewController { editingController }

    override var sections: [NSViewController] { [workspaceController, comparisonController, editingController] }
}

/// The General tab's workspace section: one switch, and what it brings back.
final class WorkspaceSettingsViewController: NSViewController {
    private let restoreCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    override func loadView() {
        let root = NSView()

        // help: settings.general.restore-workspace
        restoreCheckbox.title = L("Reopen the workspace at launch")
        restoreCheckbox.target = self
        restoreCheckbox.action = #selector(restoreChanged(_:))

        let caption = NSTextField(wrappingLabelWithString:
            L("The tabs and the files in them come back as they were at quit: addresses on screen, cursor and selection, bookmarks, segments and tool panels. Unsaved changes are not kept — quitting asks about them first."))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 4

        for subview in [restoreCheckbox, caption] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            restoreCheckbox.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            restoreCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            restoreCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),

            caption.topAnchor.constraint(equalTo: restoreCheckbox.bottomAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            SettingsMetrics.pinnedWidth(of: root),
        ])
        view = root
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func refresh() {
        restoreCheckbox.state = WorkspaceSettings.restoresWorkspace ? .on : .off
    }

    /// The checkbox, for tests.
    var restoreCheckboxForTesting: NSButton { restoreCheckbox }

    @objc private func restoreChanged(_ sender: NSButton) {
        WorkspaceSettings.set(restoresWorkspace: sender.state == .on)
    }
}
