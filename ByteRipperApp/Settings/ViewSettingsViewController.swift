import Cocoa
import Localization

/// The View tab of the Settings window: Appearance (§3.2), Layout (§6) and
/// Language, one above the other.
///
/// They were three tabs of their own, each with two or three controls, and
/// eight tabs were more than a toolbar of translated labels holds comfortably.
/// All three are about how the app looks rather than what it does, so they
/// share a page. Each section is still its own view controller — it keeps its
/// own syncing, its own observers and its own tests — and this one only stacks
/// them, with a rule between.
final class ViewSettingsViewController: NSViewController {
    private let appearanceController = AppearanceSettingsViewController()
    private let layoutController = LayoutSettingsViewController()
    private let languageController = LanguageSettingsViewController()

    /// The Language section, for the tests that drive the choice.
    var language: LanguageSettingsViewController { languageController }

    override func loadView() {
        let sections: [NSViewController] = [appearanceController, layoutController, languageController]
        var views: [NSView] = []
        for (index, section) in sections.enumerated() {
            addChild(section)
            if index > 0 { views.append(Self.separator()) }
            views.append(section.view)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        view = stack

        Self.alignLabelColumns(of: sections.compactMap { Self.firstGrid(in: $0.view) })
    }

    /// Gives every section's label column the width of the widest label in
    /// any of them, so the colons line up down the page and the controls all
    /// start at one edge. Each section lays out its own grid; on one page,
    /// three grids each as wide as their own labels read as three ragged
    /// forms. Measured, not written down: the labels are translated.
    private static func alignLabelColumns(of grids: [NSGridView]) {
        let widest = grids.flatMap { grid in
            (0..<grid.numberOfRows).compactMap { grid.cell(atColumnIndex: 0, rowIndex: $0).contentView }
        }.map(\.fittingSize.width).max() ?? 0
        for grid in grids where grid.numberOfColumns > 0 {
            grid.column(at: 0).width = ceil(widest)
        }
    }

    private static func firstGrid(in view: NSView) -> NSGridView? {
        if let grid = view as? NSGridView { return grid }
        for subview in view.subviews {
            if let grid = firstGrid(in: subview) { return grid }
        }
        return nil
    }

    /// A rule between two sections, inset to the sections' own margins.
    private static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: holder.topAnchor),
            line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 18),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -18),
            SettingsMetrics.pinnedWidth(of: holder),
        ])
        return holder
    }
}
