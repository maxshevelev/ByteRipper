import AppPalette
import Cocoa
import ByteRipperCore
import HelpUI
import Localization

/// What to look for, asked the way the dump's Find bar asks it (§11): the
/// pattern field — whose magnifier drops the menu of recent queries and of the
/// pattern library, with the commands that keep, clear and manage them — the
/// encoding popup, the Smart Search toggle and the "Aa" case toggle.
///
/// One set of controls wherever a pattern is asked for, so it reads, behaves
/// and remembers alike: the Find bar is built round it, and a tool-module that
/// searches gets one through the seam (`ToolPatternQuery`). The recents and
/// the library are the app's one history and one library
/// (`FindHistoryStore`, `FavoritePatternStore`), and the Smart Search and case
/// toggles are the app's one pair of standing choices.
///
/// It holds no search of its own. It says what the field is asking for
/// (`searchRequest()`), and is told what came of it: the encoding Smart Search
/// settled on (`adopt(encoding:)`), and whether the search found anything —
/// only a search that did is written into the history (`recordFoundSearch`).
@MainActor
final class PatternQueryControls: NSObject, NSSearchFieldDelegate, NSMenuItemValidation {
    /// What the field is asking for (§11).
    ///
    /// The controls say which of the two questions it is and nothing more.
    /// Where the encoding is the user's choice they hand over the pattern that
    /// choice makes; where it is not, the text — deciding what to try, and in
    /// what order, is the model's job (`SmartSearch`).
    enum Request: Equatable {
        case pattern(SearchPattern, folding: CaseFolding)
        /// `preferring` is the encoding the field's contents came *with*, when
        /// they came from the history rather than from the keyboard: Smart
        /// Search tries it first and then falls back to its own order (§11).
        case smart(text: String, caseSensitive: Bool, preferring: SearchEncoding?)
    }

    // MARK: - What the owner hears

    /// Return in the field.
    var onSubmit: (() -> Void)?
    /// A row of either list was picked and loaded into the controls: it is
    /// chosen deliberately, so the owner runs it.
    var onPicked: (() -> Void)?
    /// The field is empty: there is nothing to search for, which the owner says
    /// the way it says "Not found".
    var onError: ((String) -> Void)?
    /// What the field holds is not a pattern — or no longer stands as one: a
    /// short verdict and the sentence behind it, or nil to clear.
    var onPatternError: ((_ label: String?, _ detail: String?) -> Void)?
    /// **Save Search Pattern** with what the field describes. The owner asks
    /// for a name and stores it: a sheet belongs to a window (§11).
    var onAddToFavorites: ((SearchPatternEntry) -> Void)?
    /// **Manage Search Patterns…** — the owner opens the form.
    var onManageFavorites: (() -> Void)?
    /// The pattern was edited, so the search it no longer describes ends.
    var onPatternEdited: (() -> Void)?

    // MARK: - Standing choices

    /// The point size every icon control draws its symbol at (§11).
    static let iconPointSize: CGFloat = 13
    /// The pattern menu's type sizes: rows and commands a size below the
    /// system menu's 13pt, and the flags a size below that again (§11).
    static let menuRowSize: CGFloat = 12
    static let menuFlagSize: CGFloat = 11

    /// UserDefaults key for the persisted case-sensitive toggle.
    static let caseSensitiveKey = "FindCaseSensitive"
    /// Whether Smart Search is on: remembered like the case toggle, and **on**
    /// until the user says otherwise (§11).
    static let smartSearchKey = "FindSmartSearch"

    /// The defaults domain the toggles live in. Swappable so tests run against
    /// an isolated store (§11).
    static var defaults: UserDefaults = AppDefaults.store

    // MARK: - The controls

    /// The pattern field: a search field, whose magnifier drops the menu with
    /// the two lists (§11, `Design/PATTERN_LIBRARY_IDEA.md`).
    let patternField = NSSearchField()
    let encodingPopup = NSPopUpButton()
    /// The "Aa" case toggle.
    let caseButton = NSButton()
    /// The Smart Search toggle, beside the encoding it makes a result rather
    /// than an instruction (§11).
    let smartButton = NSButton()

    /// The controls in their order, for an owner laying them out.
    var views: [NSView] { [patternField, encodingPopup, smartButton, caseButton] }

    override init() {
        super.init()
        setUpPatternField()
        setUpEncodingPopup()
        setUpCaseButton()
        setUpSmartButton()
        updateCaseButtonVisibility()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Whether this search matches bytes exactly. Only the encodings whose case
    /// rules a fold can model are matched case-insensitively; for the rest this
    /// is always true (§11). With Smart Search on the popup names a result
    /// rather than the search, so the toggle alone answers: each attempt
    /// derives its own folding from its own encoding.
    var isCaseSensitive: Bool {
        guard !isSmartSearchEnabled else { return caseButton.state == .on }
        guard Self.supportsCaseFolding(currentEncoding()) else { return true }
        return caseButton.state == .on
    }

    /// Whether case-insensitive matching is meaningful for `encoding`: every
    /// text encoding, and not hex, whose input is bytes.
    static func supportsCaseFolding(_ encoding: SearchEncoding) -> Bool {
        switch encoding {
        case .ascii, .utf8, .utf16LE, .utf16BE: return true
        case .hex: return false
        }
    }

    /// Whether the encoding is a result rather than an instruction (§11).
    var isSmartSearchEnabled: Bool { smartButton.state == .on }

    /// On unless the user has turned it off.
    static var storedSmartSearch: Bool {
        defaults.object(forKey: smartSearchKey) as? Bool ?? true
    }

    /// What the field holds.
    var text: String {
        get { patternField.stringValue }
        set { setPatternText(newValue) }
    }

    // MARK: - Setup

    private func setUpPatternField() {
        patternField.setAccessibilityLabel(L("Find"))
        patternField.target = self
        patternField.action = #selector(patternFieldAction)
        // Return searches; typing does not.
        patternField.sendsWholeSearchString = true
        patternField.sendsSearchStringImmediately = false
        patternField.delegate = self
        // The menu is a *template*: the field copies it on every click, so it
        // has to be rebuilt whenever either list changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildPatternMenu),
            name: FavoritePatternStore.didChangeNotification, object: nil)
        rebuildPatternMenu()
    }

    private func setUpEncodingPopup() {
        encodingPopup.addItems(withTitles: SearchEncoding.allCases.map(\.displayName))
        encodingPopup.setAccessibilityLabel(L("Encoding"))
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged)
    }

    private func setUpCaseButton() {
        // The type before the bezel: assigning `bezelStyle` re-derives the
        // cell's masks, and a type set first reverted to momentary in a real
        // window. Borderless, the state carried by the glyph's colour and
        // weight, as Xcode's find bar says it.
        caseButton.isBordered = false
        caseButton.imagePosition = .imageOnly
        caseButton.image = NSImage(systemSymbolName: "textformat",
                                   accessibilityDescription: L("Case Sensitive"))
        caseButton.setButtonType(.pushOnPushOff)
        ControlHelp.describe(caseButton, L("Case Sensitive"))
        caseButton.target = self
        caseButton.action = #selector(caseToggled)
        caseButton.state = (Self.defaults.object(forKey: Self.caseSensitiveKey) as? Bool ?? false) ? .on : .off
        syncCaseButtonAppearance()
    }

    /// Paints the toggle to match its state (§11): accent-blue and semibold
    /// means on, quiet grey and regular means off — two cues, colour and
    /// weight, and the tooltip says it in words as well.
    func syncCaseButtonAppearance() {
        let on = caseButton.state == .on
        caseButton.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        caseButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.iconPointSize, weight: on ? .semibold : .regular)
        ControlHelp.describe(caseButton, name: L("Case Sensitive"),
                             tooltip: on
                                 ? L("Case Sensitive — matching exactly")
                                 : L("Case Sensitive — off, upper and lower case match"))
    }

    /// The Smart Search toggle: the same borderless glyph the case toggle is,
    /// in the same two states (§3.2, §11).
    private func setUpSmartButton() {
        smartButton.isBordered = false
        smartButton.imagePosition = .imageOnly
        smartButton.image = NSImage(systemSymbolName: "wand.and.sparkles",
                                    accessibilityDescription: L("Smart Search"))
        smartButton.setButtonType(.pushOnPushOff)
        smartButton.setAccessibilityLabel(L("Smart Search"))
        smartButton.target = self
        smartButton.action = #selector(smartToggled)
        smartButton.state = Self.storedSmartSearch ? .on : .off
        syncSmartButtonAppearance()
    }

    private func syncSmartButtonAppearance() {
        let on = isSmartSearchEnabled
        smartButton.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        smartButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.iconPointSize, weight: on ? .semibold : .regular)
        ControlHelp.describe(smartButton, name: L("Smart Search"),
                             tooltip: on
                                 ? L("Smart Search — the encoding is whichever one finds a match")
                                 : L("Smart Search — off, searching the chosen encoding only"))
    }

    @objc private func smartToggled() {
        Self.defaults.set(isSmartSearchEnabled, forKey: Self.smartSearchKey)
        syncSmartButtonAppearance()
        // The field means something else now: a complaint about the chosen
        // encoding no longer stands, and the case toggle is offered because a
        // text scan will happen whatever the popup says.
        onPatternError?(nil, nil)
        updateCaseButtonVisibility()
    }

    /// The standing choices as they are stored now — another set of these
    /// controls may have changed them since this one was built.
    func reloadStandingChoices() {
        smartButton.state = Self.storedSmartSearch ? .on : .off
        syncSmartButtonAppearance()
        caseButton.state = (Self.defaults.object(forKey: Self.caseSensitiveKey) as? Bool ?? false) ? .on : .off
        syncCaseButtonAppearance()
        updateCaseButtonVisibility()
        rebuildPatternMenu()
    }

    // MARK: - Opening

    /// Fills the controls for an opening: a staged pattern, else the last
    /// search that found something — pattern *and* the encoding it was found
    /// in — else nothing; and the standing choices as stored.
    func prepareForShow() {
        onPatternError?(nil, nil)
        if let staged = stagedPattern {
            applyStaged(staged)
        } else if let mostRecent = FindHistoryStore.mostRecent {
            patternField.stringValue = mostRecent.pattern
            select(mostRecent.encoding)
            pickedEncoding = mostRecent.encoding
        } else {
            patternField.stringValue = ""
            encodingPopup.selectItem(at: 0)
        }
        reloadStandingChoices()
    }

    // MARK: - Use Selection for Find (§11)

    /// The pattern a selection was put into, kept so the *next* open offers it.
    /// Dropped by a keystroke in the field, a row picked, and a search.
    private(set) var stagedPattern: SelectionFindPattern?

    /// ⌘E: the selection becomes the pattern to search for, and nothing else
    /// happens (§11).
    func stage(_ pattern: SelectionFindPattern) {
        stagedPattern = pattern
        applyStaged(pattern)
        onPatternError?(nil, nil)
        onPatternEdited?()
    }

    private func applyStaged(_ pattern: SelectionFindPattern) {
        setPatternText(pattern.text)
        select(pattern.encoding)
        pickedEncoding = pattern.encoding
        updateCaseButtonVisibility()
    }

    // MARK: - The menu

    /// Rebuilds the field's menu: the two lists and the commands that belong to
    /// each (§11, `Design/PATTERN_LIBRARY_IDEA.md`).
    @objc func rebuildPatternMenu() {
        let menu = NSMenu()
        let recents = FindHistoryStore.recent
        if !recents.isEmpty {
            menu.addItem(Self.menuHeader(L("Recent Queries"), symbol: "clock"))
            for entry in recents { menu.addItem(patternItem(for: entry)) }
            menu.addItem(.separator())
        }
        menu.addItem(command(L("Save Search Pattern"), #selector(addToFavorites)))
        if !recents.isEmpty {
            menu.addItem(command(L("Clear Recents"), #selector(clearRecents)))
        }
        let favorites = FavoritePatternStore.favorites
        if !favorites.isEmpty {
            menu.addItem(.separator())
            menu.addItem(Self.menuHeader(L("Search Patterns"), symbol: "star.fill"))
            for entry in favorites { menu.addItem(patternItem(for: entry)) }
        }
        menu.addItem(.separator())
        menu.addItem(manageItem())
        patternField.searchMenuTemplate = menu
    }

    /// **Manage Search Patterns…**, carrying whatever is wrong with the
    /// library, in red, in the words the Settings tab uses (§11).
    private func manageItem() -> NSMenuItem {
        let item = command(L("Manage Search Patterns…"), #selector(manageFavorites))
        guard let problem = FavoritePatternStore.syncProblem else { return item }
        let title = NSMutableAttributedString(
            string: L("Manage Search Patterns…"),
            attributes: [.font: NSFont.systemFont(ofSize: Self.menuRowSize)])
        title.append(NSAttributedString(
            string: "  \(problem)",
            attributes: [.font: NSFont.systemFont(ofSize: Self.menuFlagSize),
                         .foregroundColor: SemanticColors.bad]))
        item.attributedTitle = title
        item.image = NSImage(systemSymbolName: "exclamationmark.octagon.fill",
                             accessibilityDescription: problem)
        return item
    }

    /// A section header carrying an icon: a disabled item with the symbol as
    /// its image.
    private static func menuHeader(_ title: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: menuFlagSize, weight: .semibold))
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: menuFlagSize, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }

    /// One row of either list: `Name: "pattern"  flags` for a favourite,
    /// `"pattern"  flags` for a recent — one renderer, because a favourite is a
    /// recent with a name (§11).
    private func patternItem(for entry: SearchPatternEntry) -> NSMenuItem {
        let item = command(entry.name.isEmpty ? entry.pattern : entry.name,
                           #selector(patternPicked(_:)))
        item.representedObject = entry.storedValue
        let row: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Self.menuRowSize),
        ]
        let title = NSMutableAttributedString()
        if !entry.name.isEmpty {
            title.append(NSAttributedString(string: "\(entry.name): ", attributes: row))
        }
        title.append(NSAttributedString(string: "\"\(entry.pattern)\"", attributes: row))
        let flags = entry.encoding == .hex
            ? entry.encoding.displayName
            : entry.encoding.displayName + ", "
                + (entry.caseSensitive ? L("match case") : L("ignore case"))
        title.append(NSAttributedString(
            string: "  \(flags)",
            attributes: [.font: NSFont.systemFont(ofSize: Self.menuFlagSize),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = title
        if !entry.isUsable {
            item.image = NSImage(systemSymbolName: "exclamationmark.octagon.fill",
                                 accessibilityDescription: L("Invalid pattern"))
        }
        return item
    }

    /// A menu row with a target and an action.
    private func command(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.attributedTitle = NSAttributedString(
            string: title, attributes: [.font: NSFont.systemFont(ofSize: Self.menuRowSize)])
        return item
    }

    // MARK: - The field

    /// Writes `text` into the field without it counting as typing, through
    /// the live field editor when there is one.
    func setPatternText(_ text: String) {
        if let editor = patternField.currentEditor() {
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        patternField.stringValue = text
    }

    /// Writes a hex pattern back in the form a dump prints it — `deadbeef`
    /// becomes `DE AD BE EF` (§11) — on a search, never while typing.
    func normalizeHexText(of pattern: SearchPattern) {
        guard pattern.encoding == .hex else { return }
        let text = pattern.hexText
        guard text != patternField.stringValue else { return }
        setPatternText(text)
    }

    /// The field takes the keyboard, its text selected so typing replaces it.
    func focus() {
        patternField.window?.makeFirstResponder(patternField)
        patternField.selectText(nil)
    }

    // MARK: - Actions

    @objc private func patternFieldAction() {
        onSubmit?()
    }

    /// A row of either list was picked: it fills the controls — pattern,
    /// encoding and case rule — and the owner runs it. A pick records nothing
    /// in the history: the history is what was *typed* (§11).
    @objc private func patternPicked(_ sender: NSMenuItem) {
        guard let stored = sender.representedObject as? [String: Any],
              let entry = SearchPatternEntry(stored: stored) else { return }
        apply(entry)
        onPicked?()
    }

    /// With an empty field there is nothing to keep, so the command is dimmed.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(addToFavorites) else { return true }
        return !patternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func addToFavorites() {
        onAddToFavorites?(entryForField())
    }

    @objc private func clearRecents() {
        FindHistoryStore.clear()
        rebuildPatternMenu()
    }

    @objc private func manageFavorites() {
        onManageFavorites?()
    }

    /// What the field currently describes, as an entry. The encoding is the
    /// popup's, which after a Smart Search is the one that *worked* (§11).
    func entryForField() -> SearchPatternEntry {
        SearchPatternEntry(pattern: patternField.stringValue,
                           encoding: currentEncoding(),
                           caseSensitive: isCaseSensitive)
    }

    /// Typing ends the search that was running; clearing the field — Escape,
    /// the ⊗ — arrives here too (§11).
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === patternField else { return }
        pickedEncoding = nil
        stagedPattern = nil
        onPatternError?(nil, nil)
        onPatternEdited?()
    }

    @objc func encodingChanged() {
        updateCaseButtonVisibility()
        pickedEncoding = currentEncoding()
        onPatternError?(nil, nil)
    }

    @objc func caseToggled() {
        Self.defaults.set(caseButton.state == .on, forKey: Self.caseSensitiveKey)
        syncCaseButtonAppearance()
    }

    // MARK: - The request

    /// What the field is asking for, or nil when it is asking for nothing —
    /// reported through `onPatternError`, or for an empty field `onError`.
    func searchRequest() -> Request? {
        guard isSmartSearchEnabled else {
            guard let pattern = parsedPattern() else { return nil }
            return .pattern(pattern,
                            folding: CaseFolding(encoding: pattern.encoding,
                                                 caseSensitive: isCaseSensitive))
        }
        let text = patternField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onError?(Self.errorText(for: SearchError.emptyPattern))
            return nil
        }
        onPatternError?(nil, nil)
        return .smart(text: text, caseSensitive: isCaseSensitive, preferring: pickedEncoding)
    }

    /// The encoding the field's contents arrived with — a picked entry, a
    /// staged selection, the popup chosen by hand — which Smart Search tries
    /// first (§11). Cleared by a keystroke.
    private(set) var pickedEncoding: SearchEncoding?

    /// The model found no encoding that can read what is in the field (§11).
    func reportNoUsablePattern() {
        onPatternError?(L("Invalid pattern"), L("No encoding in the list can read that pattern."))
    }

    /// What was typed when a search started, waiting to be remembered: the
    /// history is the searches that found something (§11).
    private var searchToRecord: (text: String, caseSensitive: Bool)?

    /// A search is starting: it supersedes a staged pattern, and what was typed
    /// is kept to be written down if it finds anything. A picked row records
    /// nothing.
    func noteSearchStarted(recording: Bool) {
        stagedPattern = nil
        searchToRecord = recording ? (patternField.stringValue, isCaseSensitive) : nil
    }

    /// The search that was started found something, in `encoding` — so it is
    /// worth offering again (§11).
    func recordFoundSearch(encoding: SearchEncoding) {
        guard let started = searchToRecord else { return }
        searchToRecord = nil
        if FindHistoryStore.record(pattern: started.text, encoding: encoding,
                                   caseSensitive: started.caseSensitive) {
            rebuildPatternMenu()
        }
    }

    /// The encoding a Smart Search settled on: shown in the popup, and where
    /// the next search of the same text starts (§11).
    func adopt(encoding: SearchEncoding) {
        select(encoding)
        pickedEncoding = encoding
        updateCaseButtonVisibility()
        if encoding == .hex,
           let pattern = try? SearchEngine.parsePattern(patternField.stringValue, encoding: encoding) {
            normalizeHexText(of: pattern)
            searchToRecord?.text = pattern.hexText
        }
    }

    private func parsedPattern() -> SearchPattern? {
        do {
            let pattern = try SearchEngine.parsePattern(patternField.stringValue,
                                                        encoding: currentEncoding())
            onPatternError?(nil, nil)
            return pattern
        } catch {
            // An empty field is no pattern rather than a bad one.
            guard !patternField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                onPatternError?(nil, nil)
                onError?(Self.errorText(for: SearchError.emptyPattern))
                return nil
            }
            onPatternError?(L("Invalid pattern"), Self.errorText(for: error))
            return nil
        }
    }

    func currentEncoding() -> SearchEncoding {
        let index = max(0, encodingPopup.indexOfSelectedItem)
        return SearchEncoding.allCases[min(index, SearchEncoding.allCases.count - 1)]
    }

    func select(_ encoding: SearchEncoding) {
        if let index = SearchEncoding.allCases.firstIndex(of: encoding) {
            encodingPopup.selectItem(at: index)
        }
    }

    /// Loads a picked entry: the pattern, the encoding, and the case rule —
    /// all three, or the row was lying about what it searches (§11).
    func apply(_ entry: SearchPatternEntry) {
        setPatternText(entry.pattern)
        stagedPattern = nil
        select(entry.encoding)
        pickedEncoding = entry.encoding
        // Hex is always byte-exact: its flag is recorded but never restored.
        if entry.encoding != .hex {
            caseButton.state = entry.caseSensitive ? .on : .off
            Self.defaults.set(entry.caseSensitive, forKey: Self.caseSensitiveKey)
        }
        syncCaseButtonAppearance()
        updateCaseButtonVisibility()
        onPatternError?(nil, nil)
    }

    /// Shows the case toggle only where case means something: with Smart
    /// Search on, or a text encoding chosen (§11).
    func updateCaseButtonVisibility() {
        let foldable = isSmartSearchEnabled || Self.supportsCaseFolding(currentEncoding())
        caseButton.isHidden = !foldable
        caseButton.isEnabled = foldable
        syncCaseButtonAppearance()
    }

    static func errorText(for error: Error) -> String {
        if let searchError = error as? SearchError {
            switch searchError {
            case .emptyPattern: return L("Enter a non-empty pattern.")
            case .invalidHexPattern: return L("Invalid hex — use pairs like DE AD BE EF.")
            case .undecodableText: return L("Text cannot be encoded in the selected encoding.")
            }
        }
        return L("Invalid pattern.")
    }
}
