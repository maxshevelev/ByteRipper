import ByteRipperCore
import Cocoa
import HelpBook
import HelpUI
import Localization

/// The persisted editing behaviour: whether the edits that shift the file ask
/// first (§7.2), and how deep each document's undo history may grow
/// (`Design/PERSISTENT_UNDO_PLAN.md`, "Bounds").
///
/// Mirrors the `ComparisonSettings`/`LayoutSettings` pattern — read live from
/// `UserDefaults`, written through `set`. There is no notification: nothing on
/// screen derives from it, it is read at the moment an alert would be shown.
enum EditingSettings {
    static let warnsBeforeShiftingEditsKey = "WarnsBeforeShiftingEdits"

    /// Whether Paste Insert, Delete Bytes and the first insert-mode keystroke in
    /// a file ask before shifting every offset after them.
    ///
    /// On by default: shifting a dump's offsets is the one edit that can quietly
    /// ruin it, and §7.2 wants it confirmed. Off for someone who inserts often
    /// enough that the dialog is the thing in the way — every one of these edits
    /// is undoable, and the mode announces itself in the status bar (INS) and in
    /// the caret.
    static var warnsBeforeShiftingEdits: Bool {
        // `object(forKey:)` distinguishes "never set" from "set to false":
        // `bool(forKey:)` answers false for both, which would ship the warnings
        // switched off.
        AppDefaults.store.object(forKey: warnsBeforeShiftingEditsKey) as? Bool ?? true
    }

    static func set(warnsBeforeShiftingEdits: Bool) {
        AppDefaults.store.set(warnsBeforeShiftingEdits, forKey: warnsBeforeShiftingEditsKey)
    }

    static let undoHistoryMiBKey = "UndoHistoryMiB"
    static let undoStepsKey = "UndoSteps"

    /// What the size popup offers, in MiB. Large: dumps are large, and a
    /// replace of a 1 GB region keeps 2 GB — its bytes before and after.
    static let undoHistoryChoicesMiB = [512, 1024, 2048, 4096, 8192, 16384]
    static let defaultUndoHistoryMiB = 4096
    /// What the steps popup offers; 0 is no bound. A typed byte is one step,
    /// and in practice 10 000 is already more than anyone reaches.
    static let undoStepChoices = [1000, 10_000, 100_000, 0]
    static let defaultUndoSteps = 0

    /// The bytes of changes each document's history keeps, in MiB.
    static var undoHistoryMiB: Int {
        let stored = AppDefaults.store.integer(forKey: undoHistoryMiBKey)
        return undoHistoryChoicesMiB.contains(stored) ? stored : defaultUndoHistoryMiB
    }

    /// The changes each document's history keeps; 0 is no bound.
    static var undoSteps: Int {
        guard AppDefaults.store.object(forKey: undoStepsKey) != nil else { return defaultUndoSteps }
        let stored = AppDefaults.store.integer(forKey: undoStepsKey)
        return undoStepChoices.contains(stored) ? stored : defaultUndoSteps
    }

    static var undoLimits: UndoLimits {
        UndoLimits(bytes: UInt64(undoHistoryMiB) << 20, transactions: undoSteps == 0 ? nil : undoSteps)
    }

    static func set(undoHistoryMiB: Int) {
        AppDefaults.store.set(undoHistoryMiB, forKey: undoHistoryMiBKey)
        applyUndoLimits()
    }

    static func set(undoSteps: Int) {
        AppDefaults.store.set(undoSteps, forKey: undoStepsKey)
        applyUndoLimits()
    }

    /// Hands the stored bounds to every document's history, which reads them
    /// at its next edit. At launch, and whenever a bound changes.
    static func applyUndoLimits() {
        UndoLimits.current = undoLimits
    }

    /// Restores the built-in default (used by tests).
    static func resetToDefaults() {
        AppDefaults.store.removeObject(forKey: warnsBeforeShiftingEditsKey)
        AppDefaults.store.removeObject(forKey: undoHistoryMiBKey)
        AppDefaults.store.removeObject(forKey: undoStepsKey)
        applyUndoLimits()
    }
}

/// The Editing section of the General tab: whether the shifting-edit
/// confirmations appear, and the undo history's two bounds. The switch is the
/// same one the alerts' "Do not ask again" checkbox flips, which is why the
/// section reads its values on every appearance — dismissing an alert with
/// that box ticked must be reflected here.
final class EditingSettingsViewController: NSViewController {
    private let warnCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let historySizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let historyStepsPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    override func loadView() {
        let root = NSView()

        // help: settings.editing
        warnCheckbox.title = L("Ask before edits that shift the file")
        warnCheckbox.target = self
        warnCheckbox.action = #selector(warnChanged(_:))

        let caption = NSTextField(wrappingLabelWithString:
            L("Insert mode, Paste Insert and Delete Bytes move every byte after the edit, so they ask first. Turn this off to edit without the dialog — the edits stay undoable, and insert mode still shows INS in the status bar."))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 3

        // A `?` of its own beside the window's: this section's switch turns off the
        // dialogs that stand between a flash dump and an edit that shifts every
        // byte after it, and the page on editing says how the modes differ and
        // why those edits are the dangerous ones (the Agent tab keeps one for
        // the same reason: its page is not the Settings page).
        let help = HelpButton.standard(for: .topic(.editing))

        // help: settings.editing.undo-history
        let sizeLabel = NSTextField(labelWithString: L("Undo history size:"))
        for mib in EditingSettings.undoHistoryChoicesMiB {
            historySizePopup.addItem(withTitle: ByteCountFormatter.string(fromByteCount: Int64(mib) << 20, countStyle: .memory))
            historySizePopup.lastItem?.representedObject = NSNumber(value: mib)
        }
        historySizePopup.target = self
        historySizePopup.action = #selector(historySizeChanged(_:))
        ControlHelp.describe(historySizePopup, L("How many bytes of changes each document's undo history keeps"))
        let stepsLabel = NSTextField(labelWithString: L("Undo steps:"))
        for steps in EditingSettings.undoStepChoices {
            historyStepsPopup.addItem(withTitle: Self.stepsTitle(steps))
            historyStepsPopup.lastItem?.representedObject = NSNumber(value: steps)
        }
        historyStepsPopup.target = self
        historyStepsPopup.action = #selector(historyStepsChanged(_:))
        ControlHelp.describe(historyStepsPopup, L("How many changes each document's undo history keeps"))
        let limitsGrid = NSGridView(views: [[sizeLabel, historySizePopup], [stepsLabel, historyStepsPopup]])
        limitsGrid.rowSpacing = 8
        limitsGrid.columnSpacing = 8
        limitsGrid.column(at: 0).xPlacement = .trailing
        let limitsCaption = NSTextField(wrappingLabelWithString:
            L("Each open document keeps an undo history of its own. The bytes of its changes are kept in a temporary file, not in memory, before and after alike: overwriting 1 GB keeps 2 GB. Past either limit the oldest changes can no longer be undone. A lower limit takes effect at the next change; a single change larger than the limit is still kept, so it can be undone."))
        limitsCaption.font = .systemFont(ofSize: 11)
        limitsCaption.textColor = .secondaryLabelColor
        limitsCaption.maximumNumberOfLines = 0

        for subview in [warnCheckbox, caption, help, limitsGrid, limitsCaption] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            warnCheckbox.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            warnCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            help.centerYAnchor.constraint(equalTo: warnCheckbox.centerYAnchor),
            help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            warnCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: help.leadingAnchor, constant: -8),

            caption.topAnchor.constraint(equalTo: warnCheckbox.bottomAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            limitsGrid.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 20),
            limitsGrid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            limitsGrid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),

            limitsCaption.topAnchor.constraint(equalTo: limitsGrid.bottomAnchor, constant: 12),
            limitsCaption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            limitsCaption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            // Pin the last caption's bottom edge so the fitting height is the
            // content's height, not a floor — a floor leaves an empty band below
            // the text.
            limitsCaption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            // Exact width: the window sizes to this view's fitting size, and a
            // wrapping label's ideal width is its full one-line text, so only a
            // fixed width makes it wrap and the fitting size come out right.
            SettingsMetrics.pinnedWidth(of: root),
        ])
        view = root
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    /// Reads the stored value into the checkbox. Internal so a test can check
    /// the tab reflects a value an alert's checkbox wrote.
    func refresh() {
        warnCheckbox.state = EditingSettings.warnsBeforeShiftingEdits ? .on : .off
        historySizePopup.selectItem(at: historySizePopup.indexOfItem(
            withRepresentedObject: NSNumber(value: EditingSettings.undoHistoryMiB)))
        historyStepsPopup.selectItem(at: historyStepsPopup.indexOfItem(
            withRepresentedObject: NSNumber(value: EditingSettings.undoSteps)))
    }

    /// "10 000" in the language's own digits grouping; "Unlimited" for 0.
    static func stepsTitle(_ steps: Int) -> String {
        guard steps > 0 else { return L("Unlimited") }
        return NumberFormatter.localizedString(from: NSNumber(value: steps), number: .decimal)
    }

    /// The popups' choices, for tests.
    var historySizeShownMiB: Int? { (historySizePopup.selectedItem?.representedObject as? NSNumber)?.intValue }
    var historyStepsShown: Int? { (historyStepsPopup.selectedItem?.representedObject as? NSNumber)?.intValue }
    func chooseHistorySize(mib: Int) {
        historySizePopup.selectItem(at: historySizePopup.indexOfItem(withRepresentedObject: NSNumber(value: mib)))
        historySizeChanged(historySizePopup)
    }
    func chooseHistorySteps(_ steps: Int) {
        historyStepsPopup.selectItem(at: historyStepsPopup.indexOfItem(withRepresentedObject: NSNumber(value: steps)))
        historyStepsChanged(historyStepsPopup)
    }

    @objc private func historySizeChanged(_ sender: NSPopUpButton) {
        guard let mib = (sender.selectedItem?.representedObject as? NSNumber)?.intValue else { return }
        EditingSettings.set(undoHistoryMiB: mib)
    }

    @objc private func historyStepsChanged(_ sender: NSPopUpButton) {
        guard let steps = (sender.selectedItem?.representedObject as? NSNumber)?.intValue else { return }
        EditingSettings.set(undoSteps: steps)
    }

    /// The checkbox's current state, for tests.
    var warnsBeforeShiftingEdits: Bool { warnCheckbox.state == .on }

    @objc private func warnChanged(_ sender: NSButton) {
        EditingSettings.set(warnsBeforeShiftingEdits: sender.state == .on)
    }
}
