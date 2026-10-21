import AppPalette
import Cocoa
import ByteRipperCore
import HelpBook
import HelpUI
import Localization

/// The non-modal Find bar shown at the top of the window (§11), modelled after
/// TextEdit: a `Find` label, an editable pattern combo that stretches to fill
/// the remaining width, the encoding popup, a case-sensitive "Aa" toggle, joined
/// `<` `>` navigation, a Search All button that lists every occurrence in the
/// active pane's results panel, and a `Done` button — all on one line.
///
/// - Enter in the pattern field runs Find Next; Esc or `Done` closes the bar.
/// - The bar stays open after a search — only the selection moves.
/// - Picking an item from the pattern's history list loads that search (pattern
///   + encoding) but does NOT run it; only Enter, `<` and `>` search.
// help: window.find-bar
///
/// What to look for — the pattern field with its menu of recent queries and of
/// the pattern library, the encoding, Smart Search and the case toggle — is
/// `PatternQueryControls`, the one set of controls every pattern search in the
/// app is asked through; the bar adds what a step-by-step search of the dump
/// needs around it.
final class FindBarView: NSView {
    /// What the field is asking for (§11).
    ///
    /// The bar says which of the two questions it is and nothing more. Where
    /// the encoding is the user's choice it hands over the pattern that choice
    /// makes; where it is not, it hands over the text — deciding what to try,
    /// and in what order, is the model's job (`SmartSearch`), and the bar's job
    /// is to show what came back.
    typealias Request = PatternQueryControls.Request

    /// The pattern, the encoding, Smart Search and the case toggle.
    let query = PatternQueryControls()

    /// Fired when the user runs a search (Enter, `<` or `>`).
    var onSearch: ((Request, SearchDirection) -> Void)?
    /// Fired by **Save Search Pattern** with what the field describes. The
    /// owner asks for a name and stores it: a sheet belongs to a window (§11).
    var onAddToFavorites: ((SearchPatternEntry) -> Void)? {
        get { query.onAddToFavorites }
        set { query.onAddToFavorites = newValue }
    }

    /// Fired by **Manage Search Patterns…** — the owner opens the form.
    var onManageFavorites: (() -> Void)? {
        get { query.onManageFavorites }
        set { query.onManageFavorites = newValue }
    }

    /// Fired when the user closes the bar (Done or Esc).
    var onClose: (() -> Void)?
    /// Fired when the user runs Search All (§11): the same request.
    var onSearchAll: ((Request) -> Void)?

    /// Fired when the pattern in the field is edited, so the session it no
    /// longer describes can be dropped — the greys and the count with it.
    var onPatternEdited: (() -> Void)?

    /// Fired when the field is empty: there is nothing to search for.
    var onError: ((String) -> Void)?

    /// The point size every icon control on the bar draws its symbol at, so the
    /// chevrons, the list glyph and the "Aa" line up (§11).
    static var iconPointSize: CGFloat { PatternQueryControls.iconPointSize }

    /// UserDefaults keys of the standing choices — the query controls' own.
    static var caseSensitiveKey: String { PatternQueryControls.caseSensitiveKey }
    static var smartSearchKey: String { PatternQueryControls.smartSearchKey }

    /// The defaults domain the toggles live in. Swappable so tests run against
    /// an isolated store (§11).
    static var defaults: UserDefaults {
        get { PatternQueryControls.defaults }
        set { PatternQueryControls.defaults = newValue }
    }

    private var patternField: NSSearchField { query.patternField }
    private var encodingPopup: NSPopUpButton { query.encodingPopup }
    /// The "Aa" case toggle. Internal so a test can read the control itself.
    var caseButton: NSButton { query.caseButton }
    /// The Smart Search toggle.
    var smartButton: NSButton { query.smartButton }
    /// The joined `<` `>` navigation: two chevron buttons inside one rounded,
    /// bordered block split by a hairline (§11). Each button centres its own
    /// icon (AppKit does this for `NSButton`), and there is no selected-segment
    /// highlight — the pair reads as two commands, not one 2-state control.
    /// The ‹ › pair: a real two-segment `NSSegmentedControl` in momentary
    /// tracking, which is what Xcode's find bar uses and what makes the block
    /// look native — it was a pair of borderless buttons inside a hand-drawn
    /// bordered container, and the container had to imitate a bezel, a corner
    /// radius and a divider that the control draws itself (§11). Internal so a
    /// test can press a segment: there is no button to click any more.
    private(set) var navControl = NSSegmentedControl()
    /// The 1px rule between the bar and the pane below. A property (not a local)
    /// so `viewDidChangeEffectiveAppearance` can re-resolve its dynamic colour
    /// on a theme switch — a layer background baked in `setUp` would otherwise
    /// keep the launch theme's pixels (§3.1).
    /// The count: "3 of 128", "Not found", or nothing at all before a search
    /// (§11). Monospaced digits so a climbing number never shuffles the
    /// controls beside it.
    private let countLabel = NSTextField(labelWithString: "")
    /// Shown only when something is being withheld — too many matches to list,
    /// or too many to highlight — carrying the reason as its tooltip.
    private let warningView = NSImageView()

    private let separator = NSView()
    private let doneButton = NSButton()
    /// The Search All button: lists every occurrence of the pattern in the
    /// active pane's results panel (§11).
    private let findAllButton = NSButton()

    /// Whether this search matches bytes exactly (`PatternQueryControls`).
    var isCaseSensitive: Bool { query.isCaseSensitive }

    static func supportsCaseFolding(_ encoding: SearchEncoding) -> Bool {
        PatternQueryControls.supportsCaseFolding(encoding)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Setup

    private func setUp() {
        // Background + a 1px separator so the bar reads as a distinct strip
        // between the title bar and the pane content.
        wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        // The colours are resolved against the appearance in force rather than
        // against whatever happens to be current here: a bar built while some
        // other view's drawing appearance was current baked *that* one, and
        // nothing afterwards told it to look again — which is a light bar in a
        // dark window that no theme switch will correct.
        refreshThemeColors()
        addSubview(separator)

        let findLabel = NSTextField(labelWithString: L("Find"))
        findLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        setUpQuery()
        setUpCountLabel()
        setUpNavControl()
        setUpFindAllButton()
        setUpDoneButton()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        // Vertical padding around the controls keeps the strip from looking
        // cramped; the bar's height comes from the controls plus this inset (§11).
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(findLabel)
        // The query controls: the field, the encoding, and next to it Smart
        // Search, which takes it over — with it on, the popup stops being the
        // question and becomes the answer — and the case toggle (§11).
        for view in query.views { stack.addArrangedSubview(view) }
        // After the query it describes, before the stepper that walks it —
        // where the platform's own find bar puts it (§11).
        stack.addArrangedSubview(countLabel)
        stack.addArrangedSubview(warningView)
        stack.addArrangedSubview(navControl)
        stack.addArrangedSubview(findAllButton)
        // The bar's own `?`, before the ✕ that shuts it: hex against text, what
        // the encodings are for, and the pattern library. A quiet glyph rather
        // than the platform's round button — the bar is a strip of borderless
        // icon controls, and a bezel here would be the one thing on it wearing
        // one (§11).
        stack.addArrangedSubview(HelpButton.inline(for: .topic(.search)))
        stack.addArrangedSubview(doneButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),

            // The pattern is the only control that grows; the rest keep their
            // intrinsic width. The stack's .fill distribution hands all extra
            // horizontal space to the view with the lowest hugging priority.
            patternField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        // Height of the nav block tracks the Aa case toggle — the bar's other
        // icon-only control — so the block reads the same size as its neighbours
        // (§11). Set here (not in setUpNavGroup) because the constraint needs
        // both views in the stack's hierarchy.
        // No height constraint: a segmented control knows its own metrics, and
        // pinning it to the toggle's height was only ever needed because the
        // hand-drawn container had none.

        // Give everything except the pattern a high hugging priority so only it
        // expands when the window is resized (§11).
        for view in [findLabel, encodingPopup, smartButton, caseButton, countLabel, warningView,
                     navControl, findAllButton, doneButton] {
            view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        patternField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        patternField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// Layer colors are resolved once when they are assigned: the
    /// `controlBackgroundColor`/`separatorColor` CGColors baked in `setUp` are
    /// captured before the bar is in a window, so a later switch to dark mode
    /// leaves the bar white. Re-resolve every dynamic layer color here, where
    /// the effective appearance is authoritative (§3.1).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshThemeColors()
    }

    /// Moving into a window is the other way the theme under a layer can change
    /// without the appearance itself doing so: a view built before its window
    /// existed resolved its colours against the application's appearance, which
    /// is not always the window's.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshThemeColors()
    }

    /// Re-resolves every dynamic layer colour against the appearance in force
    /// now. Idempotent and cheap, so it is called from anywhere the bar might
    /// be wearing another theme's pixels — including the moment it is shown,
    /// since a hidden view is the one place a stale layer can wait unseen.
    func refreshThemeColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
            // The case toggle's fill is a CGColor too (§11).
            query.syncCaseButtonAppearance()
        }
    }

    private func setUpQuery() {
        query.onSubmit = { [weak self] in self?.runSearch(.forward) }
        query.onPicked = { [weak self] in self?.runSearch(.forward, recordingHistory: false) }
        query.onError = { [weak self] message in self?.onError?(message) }
        query.onPatternError = { [weak self] label, detail in self?.show(patternError: label, detail: detail) }
        query.onPatternEdited = { [weak self] in
            self?.show(count: nil)
            self?.onPatternEdited?()
        }
    }

    /// Whether Smart Search is on.
    var isSmartSearchEnabled: Bool { query.isSmartSearchEnabled }

    private func setUpCountLabel() {
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setAccessibilityLabel(L("Matches"))
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        // Nothing to show until a search says otherwise; `show(count:)` brings
        // the label back and takes it away again (§11).
        countLabel.isHidden = true

        // A floor wide enough for four digits either side of "of", measured
        // from a template rather than from the value: the count changes with
        // every step, and a label that resizes drags the stepper with it (§11,
        // the same trick the results panel sizes its columns with). It holds
        // only while the label is shown — a hidden one is out of the layout.
        let template = "8888 of 8888" as NSString
        let width = template.size(withAttributes: [.font: countLabel.font!]).width
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(width)).isActive = true

        warningView.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                    accessibilityDescription: L("Warning"))
        warningView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.iconPointSize, weight: .regular)
        warningView.contentTintColor = .secondaryLabelColor
        warningView.isHidden = true
        warningView.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Shows what the search found, or nothing when there is no search
    /// (§11). At zero the stepper and Find All go dead: there is nothing to
    /// step through and nothing to list.
    ///
    /// With nothing to say the label leaves the bar rather than holding its
    /// template's width open: an empty reserved slot beside the pattern field
    /// reads as a control that failed to draw. The stack detaches a hidden
    /// arranged view, so the stepper closes up against the field — the same
    /// move the case toggle makes when the encoding is hex.
    func show(count: FindCount?) {
        self.count = count
        applyCountLabel()
    }

    /// What the field holds is not a pattern at all — `DE A` in hex, a
    /// character the chosen encoding cannot encode (§11).
    ///
    /// Reported in the count's place, in red. The two are answers to the same
    /// question — what does the field describe? — so only one of them can be
    /// true at a time, and the one place the eye already goes for that answer
    /// is beside the field. `detail` says what is wrong in full, as the
    /// label's tooltip; the label itself has to stay short enough to sit in a
    /// bar.
    func show(patternError message: String?, detail: String? = nil) {
        patternError = message.map { (label: $0, detail: detail ?? $0) }
        applyCountLabel()
    }

    private var count: FindCount?
    private var patternError: (label: String, detail: String)?

    private func applyCountLabel() {
        // The error outranks the count: a count belongs to a search, and there
        // is no search for something that is not a pattern.
        if let patternError {
            countLabel.stringValue = patternError.label
            countLabel.textColor = SemanticColors.bad
            countLabel.toolTip = patternError.detail
            countLabel.isHidden = false
            warningView.isHidden = true
            ControlHelp.describe(warningView, nil)
            return
        }
        countLabel.textColor = .secondaryLabelColor
        countLabel.stringValue = count?.text ?? ""
        countLabel.isHidden = count == nil
        countLabel.toolTip = count?.warning
        ControlHelp.describe(warningView, count?.warning)
        warningView.isHidden = count?.warning == nil
        // No search yet is not "no matches": the stepper is how a search is
        // started, so it stays live until a scan has actually come back empty.
        let live = count?.hasMatches ?? true
        navControl.isEnabled = live
        findAllButton.isEnabled = live
    }

    /// What the bar reads off the pane it describes (§11).
    ///
    /// The bar is one strip serving whichever pane is in front, and everything
    /// on it that describes a *search* describes that pane's search — in
    /// comparison mode the two panes have their own sets and their own results
    /// panels. So those readings travel together as one context, handed over
    /// whenever the active pane changes or its search does. A reading that
    /// arrives later becomes a field here, rather than another call the
    /// controller has to remember in each of the places a pane can change —
    /// which is how the results button came to keep the previous pane's state.
    ///
    /// What is *not* here: the pattern, the encoding, the case rule and Smart
    /// Search. Those are the user's standing choices, app-wide by design, and
    /// they do not change because another pane came forward.
    struct PaneContext: Equatable {
        /// The count region's reading: "3 of 128", "Not found", or nothing at
        /// all while no search of that pane's has come back.
        var count: FindCount?
        /// Whether that pane's results panel is on screen — what makes the
        /// results button read as on, since it is a toggle over that panel.
        var resultsShown: Bool
    }

    /// Points the bar at a pane, by handing it everything it reads off one.
    func apply(_ context: PaneContext) {
        show(count: context.count)
        setResultsShown(context.resultsShown)
    }

    /// Reflects whether the pane's results panel is open: the button is a
    /// toggle now, not a search (§11). Accent while the panel is up, the bar's
    /// quiet grey otherwise — the same "on" language the case toggle uses.
    private func setResultsShown(_ shown: Bool) {
        resultsShown = shown
        findAllButton.contentTintColor = shown ? .controlAccentColor : .secondaryLabelColor
        ControlHelp.describe(findAllButton, name: L("Search Results"),
                             tooltip: shown ? L("Hide Search Results") : L("Show Search Results"))
    }

    private var resultsShown = false
    var resultsShownForTests: Bool { resultsShown }

    /// What the count label reads, for tests.
    var countTextForTests: String { countLabel.stringValue }
    /// The field's menu, for tests: what the two lists hold, and what picking
    /// a row does.
    var patternMenuForTests: NSMenu? { patternField.searchMenuTemplate }
    /// Picks the menu row whose title starts with `prefix` — a favourite's
    /// name, or a recent's quoted pattern. Returns false when no row does.
    @discardableResult
    func pickPatternRowForTests(startingWith prefix: String) -> Bool {
        guard let item = patternMenuForTests?.items.first(where: {
            $0.representedObject != nil && ($0.attributedTitle?.string ?? $0.title)
                .hasPrefix(prefix)
        }), let action = item.action else { return false }
        NSApp.sendAction(action, to: item.target, from: item)
        return true
    }
    /// The rows of the field's menu as they read, for the test that the two
    /// lists are one format apart.
    var patternMenuRowsForTests: [String] {
        (patternMenuForTests?.items ?? []).map { $0.attributedTitle?.string ?? $0.title }
    }
    /// Picks the menu's command with this title — the two lists' rows are
    /// picked by `pickPatternRowForTests`.
    @discardableResult
    func pickCommandForTests(_ title: String) -> Bool {
        guard let item = patternMenuForTests?.items.first(where: {
            $0.representedObject == nil && ($0.attributedTitle?.string ?? $0.title) == title
        }), let action = item.action else { return false }
        NSApp.sendAction(action, to: item.target, from: item)
        return true
    }
    /// What the field holds, and what the popup names — for tests that assert
    /// a pick loaded all three.
    var patternTextForTests: String { patternField.stringValue }

    /// Types `text` into the field the way a user does: the text changes and
    /// the controls hear of it, so it is the reader's own pattern.
    func setPatternTextForTests(_ text: String) {
        query.text = text
        query.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                object: patternField))
    }
    var encodingForTests: SearchEncoding { query.currentEncoding() }
    func setPatternForTests(_ text: String) { patternField.stringValue = text }
    func setEncodingForTests(_ encoding: SearchEncoding) {
        query.select(encoding)
        query.encodingChanged()
    }

    /// Whether Smart Search reads as on, for tests.
    var smartSearchOnForTests: Bool { isSmartSearchEnabled }
    /// The encoding a picked entry (or a hand-chosen popup) left behind, for
    /// tests.
    var preferredEncodingForTests: SearchEncoding? { query.pickedEncoding }
    /// Its colour, for the test that an invalid pattern reads as an error.
    var countColorForTests: NSColor { countLabel.textColor ?? .labelColor }
    /// The label's tooltip — the count's withheld reason, or the full sentence
    /// behind a short "Invalid pattern".
    var countTooltipForTests: String? { countLabel.toolTip }
    /// Whether the count occupies any of the bar at all, for tests.
    var countShownForTests: Bool { !countLabel.isHidden }
    /// The warning glyph's sentence, or nil when it is not shown.
    var countWarningForTests: String? { warningView.isHidden ? nil : warningView.toolTip }
    /// Where the stepper sits in the bar, for the test that the count's width
    /// does not move it.
    var navControlFrameForTests: NSRect { navControl.frame }
    /// The pattern field's width, for the test that the count's slot is real
    /// and that the field is what gets it back.
    var patternFieldWidthForTests: CGFloat { patternField.frame.width }
    var navControlEnabledForTests: Bool { navControl.isEnabled }
    var findAllEnabledForTests: Bool { findAllButton.isEnabled }

    private func setUpNavControl() {
        // Two momentary segments: pressing one runs a search, neither stays
        // selected. `.separated` would split them into two pills; the default
        // style is the joined block the platform draws everywhere else.
        let chevron: (String, String) -> NSImage = { name, description in
            NSImage(systemSymbolName: name, accessibilityDescription: description)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(
                    pointSize: Self.iconPointSize, weight: .regular))
                ?? NSImage()
        }
        navControl = NSSegmentedControl(
            images: [chevron("chevron.left", L("Find Previous")),
                     chevron("chevron.right", L("Find Next"))],
            trackingMode: .momentary,
            target: self,
            action: #selector(navPressed(_:))
        )
        navControl.segmentStyle = .automatic
        navControl.setToolTip(L("Find Previous"), forSegment: Self.previousSegment)
        navControl.setToolTip(L("Find Next"), forSegment: Self.nextSegment)
        // The segments' own accessibility comes from the images' descriptions;
        // the control needs a name of its own for the group (§15).
        navControl.setAccessibilityLabel(L("Find Previous / Find Next"))
        navControl.translatesAutoresizingMaskIntoConstraints = false
    }

    static let previousSegment = 0
    static let nextSegment = 1

    private func setUpFindAllButton() {
        // Borderless and quiet grey, like every other icon control on the bar:
        // one style, so nothing here reads as "selected" except the case
        // toggle when it is on. No `setButtonType`: the default momentary
        // push-in dims the icon while it is held.
        findAllButton.isBordered = false
        findAllButton.imagePosition = .imageOnly
        findAllButton.contentTintColor = .secondaryLabelColor
        findAllButton.image = NSImage(systemSymbolName: "list.bullet",
                                      accessibilityDescription: L("Find All"))
        findAllButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.iconPointSize, weight: .regular)
        ControlHelp.describe(findAllButton, name: L("Search Results"),
                             tooltip: L("Show Search Results"))
        findAllButton.target = self
        findAllButton.action = #selector(findAllPressed)
    }

    private func setUpDoneButton() {
        doneButton.title = L("Done")
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        doneButton.setAccessibilityLabel(L("Done"))
        // Escape is *not* wired here any more. It belongs to the pattern
        // field: the first press closes the field's menu, the second clears
        // the field — which ends the search, since clearing is a text change
        // (§11). A find bar that takes Escape as its way out is one with no
        // clear control; this one has the field's ⊗, so Escape has an obvious
        // job that is not closing, and `Done` and the ⊗ are the exits
        // (`Design/PATTERN_LIBRARY_IDEA.md`).
    }

    // MARK: - Test seams

    /// Selects `encoding` the way a click on the popup would, action included —
    /// the case toggle's enabled state follows the encoding (§11).
    func selectEncodingForTests(_ encoding: SearchEncoding) {
        query.select(encoding)
        query.encodingChanged()
    }

    /// Sets the case toggle the way a click on it would, action included. A
    /// click cannot be synthesized reliably in a headless host, and what the
    /// tests are about is what the button then shows and reports.
    func setCaseSensitiveForTests(_ on: Bool) {
        caseButton.state = on ? .on : .off
        query.caseToggled()
    }

    // MARK: - Show

    /// Fills the controls — a staged pattern, else the last search — and the
    /// standing choices, and selects the field's text so typing replaces it.
    func prepareForShow() {
        show(patternError: nil)
        query.prepareForShow()
        if window != nil {
            patternField.selectText(nil)
        }
    }

    // MARK: - Use Selection for Find (§11)

    /// ⌘E: the selection becomes the pattern to search for, and nothing else
    /// happens — the bar is not opened, no search is run (§11).
    func stage(_ pattern: SelectionFindPattern) {
        query.stage(pattern)
        show(count: nil)
    }

    /// The staged pattern, for tests.
    var stagedPatternForTests: SelectionFindPattern? { query.stagedPattern }

    /// ⌘F on a bar that is already open: the field takes focus and its text is
    /// selected, so typing replaces it — and nothing is rewritten (§11).
    func focusForEditing() {
        window?.makeFirstResponder(patternField)
        patternField.selectText(nil)
    }

    /// Restores first responder to the pattern field after a search run from the
    /// bar, so a subsequent Enter keeps re-searching (§11).
    func focusPatternField() {
        window?.makeFirstResponder(patternField)
    }

    /// What the field currently describes, as an entry.
    func entryForField() -> SearchPatternEntry { query.entryForField() }

    // MARK: - Actions

    @objc private func navPressed(_ sender: NSSegmentedControl) {
        press(segment: sender.selectedSegment)
    }

    private func press(segment: Int) {
        runSearch(segment == Self.previousSegment ? .backward : .forward)
    }

    /// Edit ▸ Find Next (⌘G) and Find Previous (⇧⌘G): the field's pattern,
    /// or the find pasteboard's string when that is new to the field — a
    /// search run elsewhere in the app, or in another app — searched for as
    /// the arrows would. Handed back rather than sent through `onSearch`, so
    /// the window can tell a ⌘G from a press in the bar: the keyboard stays
    /// where it was after one, and comes back to the field after the other.
    func requestForFindAgain() -> Request? {
        query.adoptFindPasteboard(intoEmptyField: true)
        guard let request = query.searchRequest() else { return nil }  // reported inside
        if case .pattern(let pattern, _) = request { query.normalizeHexText(of: pattern) }
        query.noteSearchStarted(recording: true)
        return request
    }

    /// Presses one of the ‹ › segments the way a click would, mapping included.
    func pressFindForTests(_ direction: SearchDirection) {
        press(segment: direction == .backward ? Self.previousSegment : Self.nextSegment)
    }

    /// Presses Find All the way a click does.
    func pressFindAllForTests() {
        runSearchAll()
    }

    @objc private func donePressed() {
        onClose?()
    }

    @objc private func findAllPressed() {
        runSearchAll()
    }

    /// Esc can also reach the bar through the responder chain.
    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    // MARK: - Search

    private func runSearch(_ direction: SearchDirection, recordingHistory: Bool = true) {
        guard let request = query.searchRequest() else { return }  // reported inside
        if case .pattern(let pattern, _) = request { query.normalizeHexText(of: pattern) }
        query.noteSearchStarted(recording: recordingHistory)
        onSearch?(request, direction)
    }

    /// Runs a Search All: the same parse and history bookkeeping as a plain
    /// search, every occurrence collected instead of moving the caret.
    private func runSearchAll() {
        guard let request = query.searchRequest() else { return }  // reported inside
        if case .pattern(let pattern, _) = request { query.normalizeHexText(of: pattern) }
        query.noteSearchStarted(recording: true)
        onSearchAll?(request)
    }

    /// The model found no encoding that can read what is in the field (§11).
    func reportNoUsablePattern() { query.reportNoUsablePattern() }

    /// The search that was started found something, in `encoding` (§11).
    func recordFoundSearch(encoding: SearchEncoding) { query.recordFoundSearch(encoding: encoding) }

    /// The encoding a Smart Search settled on (§11).
    func adopt(encoding: SearchEncoding) { query.adopt(encoding: encoding) }
}
