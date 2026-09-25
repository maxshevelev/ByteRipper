import Cocoa
import Localization

/// The persisted comparison behaviour (§10.3.1): how far apart differing bytes
/// may sit and still count as one change for Next/Previous Difference.
///
/// Mirrors the `LayoutSettings`/`AppearanceSettings` pattern — read live from
/// `UserDefaults`, and `set` posts `didChangeNotification` so an open comparison
/// re-groups its hunks without rescanning the files.
enum ComparisonSettings {
    static let groupingGapKey = "DifferenceGroupingGap"

    /// Posted after the grouping distance changes (§10.3.1).
    static let didChangeNotification = Notification.Name("ComparisonSettingsDidChange")

    /// The distances the Settings popup offers, in bytes — one, two, four and
    /// sixteen hex rows.
    static let groupingGapChoices: [UInt64] = [16, 32, 64, 256]

    /// Four rows: close enough that a press moves to a change you were not
    /// already looking at, without folding neighbouring changes into one.
    static let defaultGroupingGap: UInt64 = 64

    /// The configured distance, falling back to the default for an unset or
    /// unrecognised value.
    static var groupingGap: UInt64 {
        let stored = AppDefaults.store.integer(forKey: groupingGapKey)
        guard stored > 0 else { return defaultGroupingGap }
        let value = UInt64(stored)
        return groupingGapChoices.contains(value) ? value : defaultGroupingGap
    }

    /// Persists the distance and notifies observers to re-group (§10.3.1).
    static func set(groupingGap: UInt64) {
        AppDefaults.store.set(Int(groupingGap), forKey: groupingGapKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Restores the built-in default and notifies (used by tests).
    static func resetToDefaults() {
        AppDefaults.store.removeObject(forKey: groupingGapKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

/// The Comparison tab of the Settings window (§10.3.1): the grouping distance
/// diff navigation steps by. The change persists immediately and applies to an
/// open comparison live, matching the other tabs.
final class ComparisonSettingsViewController: NSViewController {
    private let groupingPopup = NSPopUpButton()

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: L("Comparison"))
        titleLabel.font = .boldSystemFont(ofSize: 15)

        let groupingLabel = NSTextField(labelWithString: L("Group Differences Within:"))
        groupingPopup.target = self
        groupingPopup.action = #selector(groupingChanged(_:))
        groupingPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let grid = NSGridView(views: [
            [groupingLabel, groupingPopup],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let caption = NSTextField(wrappingLabelWithString:
            L("Next / Previous Difference steps between changes, not bytes: differing bytes closer together than this belong to one change. A smaller value stops more often. Byte highlighting is always per byte."))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 3

        for subview in [titleLabel, grid, caption] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            grid.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            caption.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            // Pin the caption's trailing edge so the text wraps at the window's
            // width; the window resizes to this view's fitting size per tab.
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            // Exact width: the window sizes to this view's fitting size, and a
            // wrapping label's ideal width is its full one-line text, so only a
            // fixed width makes it wrap and the fitting size come out right.
            SettingsMetrics.pinnedWidth(of: root),
        ])
        view = root

        syncControls()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        syncControls()
    }

    /// Loads the current setting into the popup.
    private func syncControls() {
        groupingPopup.removeAllItems()
        let menu = groupingPopup.menu!
        for gap in ComparisonSettings.groupingGapChoices {
            let item = menu.addItem(withTitle: Self.title(for: gap), action: nil, keyEquivalent: "")
            item.representedObject = NSNumber(value: gap)
        }
        let current = ComparisonSettings.groupingGap
        groupingPopup.selectItem(at: ComparisonSettings.groupingGapChoices.firstIndex(of: current) ?? 0)
    }

    @objc private func groupingChanged(_ sender: NSPopUpButton) {
        guard let gap = (sender.selectedItem?.representedObject as? NSNumber)?.uint64Value else { return }
        ComparisonSettings.set(groupingGap: gap)
    }

    /// "256 bytes (16 rows)" — the byte count is what the grouping actually
    /// measures; the row count is how it reads on screen.
    ///
    /// One whole phrase per choice, because both nouns decline: Russian wants
    /// «16 байт (1 строка)», «32 байта (2 строки)», «256 байт (16 строк)», and
    /// no arithmetic on `gap` gets there. The default is for a gap nobody has
    /// offered yet, and reads in numbers alone.
    private static func title(for gap: UInt64) -> String {
        switch gap {
        case 16: return L("16 bytes (1 row)")
        case 32: return L("32 bytes (2 rows)")
        case 64: return L("64 bytes (4 rows)")
        case 256: return L("256 bytes (16 rows)")
        default: return L("%1$@ bytes (%2$@ rows)", gap, gap / 16)
        }
    }
}
