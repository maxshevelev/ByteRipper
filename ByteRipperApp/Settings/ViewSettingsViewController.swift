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
