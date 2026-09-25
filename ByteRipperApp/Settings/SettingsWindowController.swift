import Cocoa
import Localization

/// The Appearance tab of the Settings window (§3.2): the monospaced font
/// (family and size), the row-height factor, and the app theme. Every change
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

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: L("Appearance"))
        titleLabel.font = .boldSystemFont(ofSize: 15)

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
/// with an Appearance tab (§3.2), a Layout tab (§6), a Comparison tab (§10.3.1),
/// a Text Decoding tab (§3.4), a Favorites tab (§11) and a File Types tab (§25). Owned by `MainWindowController`; the App
/// menu's "Settings…" item shows it.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let appearanceController = AppearanceSettingsViewController()
    private let layoutController = LayoutSettingsViewController()
    private let comparisonController = ComparisonSettingsViewController()
    private let editingController = EditingSettingsViewController()
    private let textDecodingController = TextDecodingSettingsViewController()
    private let fileTypesController = FileTypesSettingsViewController()
    private let favoritesController = FavoritePatternsSettingsViewController()
    private let languageController = LanguageSettingsViewController()

    private static let appearanceItemID = NSToolbarItem.Identifier("Appearance")
    private static let layoutItemID = NSToolbarItem.Identifier("Layout")
    private static let comparisonItemID = NSToolbarItem.Identifier("Comparison")
    private static let editingItemID = NSToolbarItem.Identifier("Editing")
    private static let textDecodingItemID = NSToolbarItem.Identifier("TextDecoding")
    private static let fileTypesItemID = NSToolbarItem.Identifier("FileTypes")
    private static let favoritesItemID = NSToolbarItem.Identifier("Favorites")
    private static let languageItemID = NSToolbarItem.Identifier("Language")

    init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.width(), height: 235),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("ByteRipper Settings")
        window.isReleasedWhenClosed = false
        // Autosave the position only. The size must track the active tab's
        // content (see `selectTab`), so it is deliberately not autosaved — a
        // saved size would pin the window at whatever tab was last shown.
        super.init(window: window)

        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        window.contentViewController = appearanceController
    }

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

    /// What each tab is called, in one place.
    ///
    /// The toolbar builds its items from this and `SettingsMetrics` measures
    /// it: a label written out twice is a label that drifts, and here the
    /// second copy would be the one deciding how wide the window is.
    static func label(for identifier: NSToolbarItem.Identifier) -> String {
        switch identifier {
        case appearanceItemID: return L("Appearance")
        case layoutItemID: return L("Layout")
        case comparisonItemID: return L("Comparison")
        case editingItemID: return L("Editing")
        case textDecodingItemID: return L("Text Decoding")
        case favoritesItemID: return L("Search Patterns")
        case fileTypesItemID: return L("File Types")
        case languageItemID: return L("Language")
        default: return ""
        }
    }

    /// Every tab's label, in toolbar order — the words the toolbar is
    /// actually showing.
    ///
    /// Captured once, the first time anything asks. Picking another language
    /// in the Language tab changes what `L()` returns straight away, but not
    /// what the toolbar says: its items were built with the old words and keep
    /// them until the app restarts. Measuring the new words would resize the
    /// window around labels nobody can see — which is what made the window
    /// jump, and shrink under its own toolbar, on a language change.
    static let toolbarLabels: [String] = tabIdentifiers.map(label(for:))

    static let tabIdentifiers: [NSToolbarItem.Identifier] = [
        appearanceItemID, layoutItemID, comparisonItemID, editingItemID,
        textDecodingItemID, favoritesItemID, fileTypesItemID, languageItemID,
    ]

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        // help: settings.appearance
        case Self.appearanceItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: L("Appearance"))
            item.target = self
            item.action = #selector(appearanceTabTapped)
        // help: settings.layout
        case Self.layoutItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: L("Layout"))
            item.target = self
            item.action = #selector(layoutTabTapped)
        // help: settings.comparison
        case Self.comparisonItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                 accessibilityDescription: L("Comparison"))
            item.target = self
            item.action = #selector(comparisonTabTapped)
        // help: settings.editing
        case Self.editingItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "square.and.pencil",
                                 accessibilityDescription: L("Editing"))
            item.target = self
            item.action = #selector(editingTabTapped)
        // help: settings.patterns
        case Self.favoritesItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "star", accessibilityDescription: L("Search Patterns"))
            item.target = self
            item.action = #selector(favoritesTabTapped)
        // help: settings.file-types
        case Self.fileTypesItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "doc.badge.gearshape",
                                 accessibilityDescription: L("File Types"))
            item.target = self
            item.action = #selector(fileTypesTabTapped)
        // help: settings.language
        case Self.languageItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: L("Language"))
            item.target = self
            item.action = #selector(languageTabTapped)
        // help: settings.text-decoding
        case Self.textDecodingItemID:
            item.label = Self.label(for: itemIdentifier)
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "textformat.abc", accessibilityDescription: L("Text Decoding"))
            item.target = self
            item.action = #selector(textDecodingTabTapped)
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
    private func fitWindowToContent() {
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
        window.setFrame(frame, display: true, animate: false)
    }

    private func selectTab(_ controller: NSViewController) {
        window?.contentViewController = controller
        fitWindowToContent()
    }

    @objc private func appearanceTabTapped() {
        selectTab(appearanceController)
    }

    @objc private func layoutTabTapped() {
        selectTab(layoutController)
    }

    @objc private func comparisonTabTapped() {
        selectTab(comparisonController)
    }

    @objc private func editingTabTapped() {
        selectTab(editingController)
    }

    @objc private func textDecodingTabTapped() {
        selectTab(textDecodingController)
    }

    @objc private func fileTypesTabTapped() {
        selectTab(fileTypesController)
    }

    @objc private func favoritesTabTapped() {
        selectTab(favoritesController)
    }

    @objc private func languageTabTapped() {
        selectTab(languageController)
    }

    /// Re-sizes the window to the tab it is showing. The Language tab grows
    /// when it starts offering the relaunch, and the window is sized to its
    /// content rather than the other way round.
    func fitToCurrentTab() {
        fitWindowToContent()
    }

    /// The Language tab, for the tests that drive the choice.
    var language: LanguageSettingsViewController { languageController }

    /// Opens the window on the Favorites tab — where **Manage Favorites…** in
    /// the Find bar's menu leads (§11). A named destination rather than "open
    /// Settings and look for it": the menu item promises a list, so it lands on
    /// the list.
    func showFavorites(_ sender: Any?) {
        selectTab(favoritesController)
        showWindow(sender)
    }
}
