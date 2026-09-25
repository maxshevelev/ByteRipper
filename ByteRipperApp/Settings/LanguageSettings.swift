import Cocoa
import HelpBook
import HelpUI
import Localization

/// The Language tab of the Settings window: which language the app speaks.
///
/// It exists because the Mac's language and the bench's language are not always
/// the same. A shop in Germany may run its Macs in German and want its firmware
/// tools in English, because English is what the datasheets, the forums and the
/// other tools say; a technician may want the opposite. Following the system is
/// the default and the right one, but it must not be the only one.
///
/// The change needs a relaunch, and the tab says so rather than pretending
/// otherwise. A menu bar, a window's labels and a panel's columns are built
/// when they are built; re-reading every one of them at run time would be a
/// second layout path through the whole app, kept correct forever, for a
/// setting a user touches once. The help is the exception — it is rebuilt from
/// the book on every page shown, so it changes language immediately, and that
/// is worth having because the help is where a reader goes when the words are
/// the problem.
final class LanguageSettingsViewController: NSViewController {
    private let languagePopup = NSPopUpButton()
    private let relaunchButton = NSButton()
    private let noticeLabel = NSTextField(labelWithString: "")

    /// The order the popup offers: follow the Mac first, then the languages
    /// themselves in the order they were added.
    private var choices: [LanguageChoice] {
        [.system] + AppLanguage.allCases.map(LanguageChoice.fixed)
    }

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: L("Language"))
        titleLabel.font = .boldSystemFont(ofSize: 15)

        let languageLabel = NSTextField(labelWithString: L("Language:"))
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languagePopup.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let caption = NSTextField(wrappingLabelWithString: L(
            "Follow the Mac, or pick a language of your own. Firmware terms — $FPT, Boot Guard, FIT — keep their English names in every language, because that is what the datasheets and the other tools call them."))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 4

        // Shown only once the choice has actually moved, so a tab the user is
        // only looking at says nothing about relaunching.
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = SemanticSettingsColors.notice
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.isHidden = true
        // The notice is what gives way when the row is short of room: it
        // wraps to its second line, and the button beside it keeps its width.
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        relaunchButton.title = L("Relaunch Now")
        relaunchButton.bezelStyle = .rounded
        relaunchButton.target = self
        relaunchButton.action = #selector(relaunch)
        relaunchButton.isHidden = true
        // A button clipped to half a word is worse than a wrapped sentence:
        // «Перезапустить» is half again as wide as "Relaunch Now", and the
        // stack was taking the difference out of the button.
        relaunchButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        relaunchButton.setContentHuggingPriority(.required, for: .horizontal)

        let help = HelpButton.standard(for: .topic(.settings))

        let grid = NSGridView(views: [[languageLabel, languagePopup]])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        let noticeRow = NSStackView(views: [noticeLabel, relaunchButton])
        noticeRow.orientation = .horizontal
        noticeRow.alignment = .centerY
        noticeRow.spacing = 10

        for subview in [titleLabel, grid, caption, noticeRow, help] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            help.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            grid.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),

            caption.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            // Pinned rather than bounded, so the label wraps at the window's
            // width and the fitting size the window is sized to comes out right.
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            noticeRow.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 14),
            noticeRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            // Pinned, not bounded: the row has to know its width for the
            // notice to wrap inside it. Bounded, the label kept its full
            // one-line width and the button was pushed out of the window.
            noticeRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            noticeRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            SettingsMetrics.pinnedWidth(of: root),
        ])
        view = root
        syncControls()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        syncControls()
    }

    /// Fills the popup and puts the tick on what is stored.
    ///
    /// Each language names itself in itself — Русский, Deutsch — because a
    /// reader hunting for their own language must not have to read another one
    /// to find it. "Follow the Mac" names, in brackets, what it currently
    /// resolves to, so the choice says what it will actually do.
    private func syncControls() {
        let menu = NSMenu()
        for choice in choices {
            let title: String
            switch choice {
            case .system:
                let resolved = LanguageChoice.system
                    .resolve(preferred: Localization.preferredLanguages)
                title = L("Same as the Mac (%1$@)", resolved.ownName)
            case .fixed(let language):
                title = language.ownName
            }
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        languagePopup.menu = menu
        languagePopup.selectItem(at: choices.firstIndex(of: Localization.choice) ?? 0)
    }

    /// The choice the popup is on, for the tests.
    var selectedChoice: LanguageChoice {
        choices.indices.contains(languagePopup.indexOfSelectedItem)
            ? choices[languagePopup.indexOfSelectedItem]
            : .system
    }

    /// Whether the tab is offering the relaunch, for the tests.
    var offersRelaunch: Bool { !relaunchButton.isHidden }

    /// The button itself, so a test can check it is not clipped.
    var relaunchButtonForTesting: NSButton { relaunchButton }

    /// Puts the tab in the state a language change leaves it in.
    func showRelaunchNoticeForTesting() { showRelaunchNotice() }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let chosen = selectedChoice
        guard chosen != Localization.choice else { return }
        Localization.set(chosen)
        // The book is the one thing that can change language without a
        // relaunch: every page is rebuilt from it when it is shown.
        Help.reload()
        showRelaunchNotice()
    }

    private func showRelaunchNotice() {
        noticeLabel.stringValue = L("The help changes language now. The menus and windows change when ByteRipper starts again.")
        noticeLabel.isHidden = false
        relaunchButton.isHidden = false
        // The tab grew; the window is sized to its content.
        (view.window?.windowController as? SettingsWindowController)?.fitToCurrentTab()
    }

    /// Quits and comes back, which is the whole of what the change needs.
    ///
    /// `open -n` on the app's own bundle after asking the app to terminate:
    /// relaunching from inside a sandboxed app is not something AppKit offers,
    /// and a detached `open` is what every app that does this uses. Under test
    /// it does nothing — a suite that relaunches its host is a suite that does
    /// not finish.
    @objc private func relaunch() {
        guard !AppDefaults.isUnderTest else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// The one colour this tab needs that is not a state: a line saying something
/// is waiting on the user. The palette's caution, which is what it is.
private enum SemanticSettingsColors {
    static var notice: NSColor { .secondaryLabelColor }
}
