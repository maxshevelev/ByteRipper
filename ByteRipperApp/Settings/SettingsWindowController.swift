import Cocoa
import HelpBook
import HelpUI
import Localization

/// The Appearance section of the Settings window's View tab (§3.2): the
/// monospaced font (family and size), the row-height factor, and the app
/// theme. Every change
/// persists immediately through `AppearanceSettings.set` / `AppTheme.set` and
/// re-lays out every open hex view (or re-themes the app), so the effect is
/// visible live behind the settings window.
final class AppearanceSettingsViewController: NSViewController {
    private let fontPopup = NSPopUpButton()
    private let fontStepper = NSStepper()
    private let fontSizeValueLabel = NSTextField(labelWithString: "")
    private let scaleSlider = NSSlider()
    private let scaleValueLabel = NSTextField(labelWithString: "")
    private let themePopup = NSPopUpButton()

    // help: settings.appearance
    override func loadView() {
        let root = NSView()

        // Font row: a popup of "System" + the monospaced families, with the
        // font-size stepper + value sharing the same row (the size has no label
        // of its own). NSStepper's min/max/increment are Doubles; the size is an
        // integer number of points, so it steps by 1 and is read back through
        // `integerValue`.
        let fontLabel = NSTextField(labelWithString: L("Font:"))
        fontPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        fontPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        fontStepper.minValue = AppearanceSettings.fontSizeRange.lowerBound
        fontStepper.maxValue = AppearanceSettings.fontSizeRange.upperBound
        fontStepper.increment = 1
        fontStepper.valueWraps = false
        fontStepper.target = self
        fontStepper.action = #selector(fontSizeChanged(_:))
        let fontRow = NSStackView()
        fontRow.orientation = .horizontal
        fontRow.spacing = 8
        fontRow.addArrangedSubview(fontPopup)
        fontRow.addArrangedSubview(fontStepper)
        fontRow.addArrangedSubview(fontSizeValueLabel)

        // Row-height row: a slider snapping to 0.05 steps + the current value.
        let scaleLabel = NSTextField(labelWithString: L("Row Height:"))
        scaleSlider.minValue = Double(AppearanceSettings.rowHeightScaleRange.lowerBound)
        scaleSlider.maxValue = Double(AppearanceSettings.rowHeightScaleRange.upperBound)
        scaleSlider.numberOfTickMarks = 8
        scaleSlider.allowsTickMarkValuesOnly = true
        scaleSlider.isContinuous = true
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged(_:))
        scaleSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let scaleRow = NSStackView()
        scaleRow.orientation = .horizontal
        scaleRow.spacing = 8
        scaleRow.addArrangedSubview(scaleSlider)
        scaleRow.addArrangedSubview(scaleValueLabel)

        // Theme row: follow the system, or force light / dark.
        let themeLabel = NSTextField(labelWithString: L("Theme:"))
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        themePopup.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let grid = NSGridView(views: [
            [fontLabel, fontRow],
            [scaleLabel, scaleRow],
            [themeLabel, themePopup],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let caption = NSTextField(wrappingLabelWithString:
            L("The hex dump's font and row pitch. A smaller Row Height packs more rows onto the screen. Theme applies to the whole app."))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 3

        for subview in [grid, caption] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            caption.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            // Pin the caption's trailing edge (not just bound it) so the text
            // wraps at the window's width; with only a `lessThanOrEqualTo` the
            // label keeps its full one-line width and the view's fitting size —
            // which the window sizes to — is wrong.
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            // An exact width (not a floor): the window sizes to this view's
            // fitting size per tab, and a wrapping label's ideal width is its
            // full one-line text, so only a fixed width makes it wrap and the
            // fitting size come out right.
            SettingsMetrics.pinnedWidth(of: root),
        ])
        view = root

        syncControls()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-sync in case settings changed from the menu (e.g. tests).
        syncControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Zoom In / Zoom Out change the same size this tab shows (§3.2), and
        // they can be pressed while the window is open — so the controls
        // follow the setting rather than only their own clicks.
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.syncControls()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
    }

    private var appearanceObserver: NSObjectProtocol?

    /// Loads the current settings into the controls.
    private func syncControls() {
        fontPopup.removeAllItems()
        // NSPopUpButton's own addItem(withTitle:) returns Void; build items on
        // its menu so each carries the family as its representedObject.
        let menu = fontPopup.menu!
        let systemItem = menu.addItem(withTitle: L("System"), action: nil, keyEquivalent: "")
        systemItem.representedObject = AppearanceSettings.systemFontSentinel
        let current = AppearanceSettings.fontFamily
        for family in AppearanceSettings.monospacedFontFamilies() {
            let item = menu.addItem(withTitle: family, action: nil, keyEquivalent: "")
            item.representedObject = family
        }
        let index = current.isEmpty ? 0 : fontPopup.indexOfItem(withRepresentedObject: current)
        fontPopup.selectItem(at: index >= 0 ? index : 0)

        fontStepper.integerValue = Int(AppearanceSettings.fontSize)
        fontSizeValueLabel.stringValue = Self.formatFontSize(AppearanceSettings.fontSize)

        scaleSlider.doubleValue = Double(AppearanceSettings.rowHeightScale)
        scaleValueLabel.stringValue = Self.formatScale(AppearanceSettings.rowHeightScale)

        themePopup.removeAllItems()
        for theme in AppTheme.allCases {
            themePopup.addItem(withTitle: theme.title)
        }
        themePopup.selectItem(at: AppTheme.allCases.firstIndex(of: AppTheme.current) ?? 0)
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let family = sender.selectedItem?.representedObject as? String ?? AppearanceSettings.systemFontSentinel
        AppearanceSettings.set(fontFamily: family, rowHeightScale: AppearanceSettings.rowHeightScale)
    }

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        let size = CGFloat(sender.integerValue)
        fontSizeValueLabel.stringValue = Self.formatFontSize(size)
        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily,
                               rowHeightScale: AppearanceSettings.rowHeightScale,
                               fontSize: size)
    }

    @objc private func scaleChanged(_ sender: NSSlider) {
        // Snap to the 0.05 tick grid (the slider already snaps with
        // allowsTickMarkValuesOnly; this keeps the stored value exact).
        let snapped = (sender.doubleValue / 0.05).rounded() * 0.05
        let scale = min(AppearanceSettings.rowHeightScaleRange.upperBound,
                        max(AppearanceSettings.rowHeightScaleRange.lowerBound, snapped))
        scaleValueLabel.stringValue = Self.formatScale(scale)
        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily, rowHeightScale: scale)
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let theme = AppTheme.allCases[sender.indexOfSelectedItem]
        AppTheme.set(theme)
    }

    private static func formatScale(_ scale: CGFloat) -> String {
        String(format: "%.2g×", scale)
    }

    private static func formatFontSize(_ size: CGFloat) -> String {
        "\(Int(size)) pt"
    }
}

/// The Settings window. Closes on Escape, like a sheet: every preference is
/// applied and persisted live the moment it changes, so there is nothing to
/// confirm or lose — Esc is simply "I'm done" (the same `cancelOperation`
/// hook the Find bar uses for its own Esc-to-dismiss).
final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// The app's Settings window — a standard toolbar-tabbed preference dialog,
/// with a View tab (Appearance §3.2, Layout §6 and Language), a Comparison tab
/// (§10.3.1), an Editing tab, a Text Decoding tab (§3.4), a Favorites tab (§11)
/// and a File Types tab (§25). Owned by `MainWindowController`; the App menu's
/// "Settings…" item shows it.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let viewController = ViewSettingsViewController()
    private let comparisonController = ComparisonSettingsViewController()
    private let editingController = EditingSettingsViewController()
    private let textDecodingController = TextDecodingSettingsViewController()
    private let fileTypesController = FileTypesSettingsViewController()
    private let favoritesController = FavoritePatternsSettingsViewController()
    private let agentController = AgentSettingsViewController()

    private static let viewItemID = NSToolbarItem.Identifier("View")
    private static let comparisonItemID = NSToolbarItem.Identifier("Comparison")
    private static let editingItemID = NSToolbarItem.Identifier("Editing")
    private static let textDecodingItemID = NSToolbarItem.Identifier("TextDecoding")
    private static let fileTypesItemID = NSToolbarItem.Identifier("FileTypes")
    private static let favoritesItemID = NSToolbarItem.Identifier("Favorites")
    private static let agentItemID = NSToolbarItem.Identifier("Agent")

    init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.width(), height: 235),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Autosave the position only. The size must track the active tab's
        // content (see `select`), so it is deliberately not autosaved — a
        // saved size would pin the window at whatever tab was last shown.
        super.init(window: window)

        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        installHelpButton()
        select(Self.viewItemID, animate: false)
    }

    /// The `?` for the whole window: at the trailing end of the title bar,
    /// level with the traffic lights.
    ///
    /// One button for every tab, not one per tab: the Settings page covers the
    /// whole window, and a `?` that appears on some tabs and not on others
    /// reads as though only those tabs have help. It lives in the window's
    /// chrome so that it stays put while the tabs below it change size. Two
    /// tabs add a `?` of their own beside their first control, because a page
    /// other than Settings explains them: Editing (the editing modes, and why
    /// the shifting edits ask first) and Agent.
    ///
    /// Not a titlebar accessory: with a preference-style toolbar, AppKit puts
    /// a trailing accessory in the toolbar's row, beside the last tab. The
    /// view the traffic lights sit in is the one row that is the title's, so
    /// the button goes there and centres on the close button.
    private let helpButton: HelpButton = {
        let help = HelpButton.standard(for: .topic(.settings))
        help.controlSize = .small
        return help
    }()

    private func installHelpButton() {
        guard let close = window?.standardWindowButton(.closeButton),
              let titlebar = close.superview else { return }
        helpButton.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(helpButton)
        NSLayoutConstraint.activate([
            helpButton.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            helpButton.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -8),
        ])
    }

    /// The window's `?`, for the tests.
    var helpButtonForTesting: HelpButton { helpButton }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        // Size to the initial tab's content before showing, so the window
        // appears at the right height (and the centre is computed from it).
        fitWindowToContent()
        // Center on first show; keep a position the user already moved to.
        if window?.isVisible != true {
            window?.center()
        }
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.tabIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.tabIdentifiers
    }

    /// Every tab is selectable: the toolbar marks the one on screen, as
    /// Finder's and Safari's settings do, instead of leaving the reader to
    /// tell it from the content below.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.tabIdentifiers
    }

    /// What each tab is called, in one place.
    ///
    /// The toolbar builds its items from this and `SettingsMetrics` measures
    /// it: a label written out twice is a label that drifts, and here the
    /// second copy would be the one deciding how wide the window is.
    static func label(for identifier: NSToolbarItem.Identifier) -> String {
        switch identifier {
        case viewItemID: return L("View", context: "settings")
        case comparisonItemID: return L("Comparison")
        case editingItemID: return L("Editing")
        case textDecodingItemID: return L("Text Decoding")
        case favoritesItemID: return L("Search Patterns")
        case fileTypesItemID: return L("File Types")
        case agentItemID: return L("Agent")
        default: return ""
        }
    }

    /// Every tab's label, in toolbar order — the words the toolbar is
    /// actually showing.
    ///
    /// Captured once, the first time anything asks. Picking another language
    /// in the View tab changes what `L()` returns straight away, but not
    /// what the toolbar says: its items were built with the old words and keep
    /// them until the app restarts. Measuring the new words would resize the
    /// window around labels nobody can see — which is what made the window
    /// jump, and shrink under its own toolbar, on a language change.
    static let toolbarLabels: [String] = tabIdentifiers.map(label(for:))

    static let tabIdentifiers: [NSToolbarItem.Identifier] = [
        viewItemID, comparisonItemID, editingItemID,
        textDecodingItemID, favoritesItemID, fileTypesItemID, agentItemID,
    ]

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        // help: settings.view
        case Self.viewItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(tabTapped(_:))
        // help: settings.comparison
        case Self.comparisonItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                 accessibilityDescription: L("Comparison"))
            item.target = self
            item.action = #selector(tabTapped(_:))
        // help: settings.editing
        case Self.editingItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "square.and.pencil",
                                 accessibilityDescription: L("Editing"))
            item.target = self
            item.action = #selector(tabTapped(_:))
        // help: settings.patterns
        case Self.favoritesItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "star", accessibilityDescription: L("Search Patterns"))
            item.target = self
            item.action = #selector(tabTapped(_:))
        // help: settings.file-types
        case Self.fileTypesItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "doc.badge.gearshape",
                                 accessibilityDescription: L("File Types"))
            item.target = self
            item.action = #selector(tabTapped(_:))
        // help: settings.agent
        case Self.agentItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: AgentService.symbolName(connected: false),
                                 accessibilityDescription: L("Agent"))
            item.target = self
            item.action = #selector(tabTapped(_:))
        // help: settings.text-decoding
        case Self.textDecodingItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "textformat.abc", accessibilityDescription: L("Text Decoding"))
            item.target = self
            item.action = #selector(tabTapped(_:))
        default:
            return nil
        }
        return item
    }

    /// Resizes the window to fit its current tab's content, keeping the top
    /// edge fixed so the window grows or shrinks in place. Setting
    /// `contentViewController` alone resizes only on the first assignment —
    /// afterwards the window keeps its size and the tab's view is stretched to
    /// it — so the size is driven explicitly from the view's fitting size. Each
    /// tab's view sizes itself via constraints (a min-width the text wraps to,
    /// and a height pinned from the top), so the fitting size is the right size.
    private func fitWindowToContent(animate: Bool = false) {
        guard let window, let controller = window.contentViewController else { return }
        // The tabs' widths depend on the translated toolbar labels and on the
        // system's UI font size; both are re-measured here rather than frozen
        // at the moment a tab was first built.
        SettingsMetrics.refresh()
        let top = window.frame.maxY
        let fitting = controller.view.fittingSize
        let windowSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: fitting)).size
        var frame = window.frame
        frame.size = windowSize
        frame.origin.y = top - windowSize.height
        window.setFrame(frame, display: true, animate: animate)
    }

    /// The controller each tab shows.
    private func controller(for identifier: NSToolbarItem.Identifier) -> NSViewController? {
        switch identifier {
        case Self.viewItemID: return viewController
        case Self.comparisonItemID: return comparisonController
        case Self.editingItemID: return editingController
        case Self.textDecodingItemID: return textDecodingController
        case Self.favoritesItemID: return favoritesController
        case Self.fileTypesItemID: return fileTypesController
        case Self.agentItemID: return agentController
        default: return nil
        }
    }

    /// Shows a tab the way the system's own settings windows do: its item
    /// marked in the toolbar, its name as the window's title, and the window
    /// growing or shrinking to it in one short animation while it is on
    /// screen. The title is the tab's because the toolbar already says whose
    /// settings these are; Finder's window reads "General", not "Finder
    /// Settings".
    private func select(_ identifier: NSToolbarItem.Identifier, animate: Bool = true) {
        guard let window, let controller = controller(for: identifier) else { return }
        window.toolbar?.selectedItemIdentifier = identifier
        window.title = Self.label(for: identifier)
        window.contentViewController = controller
        fitWindowToContent(animate: animate && window.isVisible
                           && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    @objc private func tabTapped(_ sender: NSToolbarItem) {
        select(sender.itemIdentifier)
    }

    /// Re-sizes the window to the tab it is showing. The View tab grows when
    /// its Language section starts offering the relaunch, and the window is sized to its
    /// content rather than the other way round.
    func fitToCurrentTab() {
        fitWindowToContent()
    }

    /// The Language section, for the tests that drive the choice.
    var language: LanguageSettingsViewController { viewController.language }

    /// Opens the window on the Favorites tab — where **Manage Favorites…** in
    /// the Find bar's menu leads (§11). A named destination rather than "open
    /// Settings and look for it": the menu item promises a list, so it lands on
    /// the list.
    func showFavorites(_ sender: Any?) {
        select(Self.favoritesItemID)
        showWindow(sender)
    }

    /// Opens the window on the Agent tab — where the Agent window and the menu
    /// bar's agent item send someone who wants to switch the service on or
    /// copy a client's configuration.
    func showAgent(_ sender: Any?) {
        select(Self.agentItemID)
        showWindow(sender)
    }

    /// The Agent tab, for the tests that drive it.
    var agent: AgentSettingsViewController { agentController }
}
