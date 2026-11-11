import AppKit
import HelpUI
import Localization

/// What answers a click on a row's (i): the panel's controller, found up the
/// responder chain from the button, so a recycled cell needs no target.
@MainActor @objc public protocol ToolPanelModuleInfoResponder {
    /// The (i) of the row holding `sender` was clicked.
    func showModuleInfo(_ sender: NSButton)
}

// help: panel.uefi.module-summary
/// The (i) after a module's badges: its summary, the paragraph under its
/// description's title, in a popover, read without opening the code. A link's
/// colour, as the CPUID's (i) of a microcode is: it opens something.
public final class ToolPanelModuleInfoButton: NSButton {
    public convenience init() {
        self.init(frame: .zero)
    }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        title = ""
        setButtonType(.momentaryChange)
        // The panel's controller sets itself as the target when it makes the
        // cell; nil sends up the responder chain, which reaches the controller
        // only while the focus is in its own panel.
        target = nil
        action = #selector(ToolPanelModuleInfoResponder.showModuleInfo(_:))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        ControlHelp.describe(self, name: L("Module summary"),
                             tooltip: L("Shows the module's summary from its description"))
        paint()
        isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var tag: Int {
        get { ToolPanelTable.codeInfoTag }
        set {}
    }

    /// A link's colour; on a selected row the selection's text colour, as
    /// the glyphs beside it take: blue on the accent is not seen.
    public private(set) var color: NSColor = .linkColor

    public var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet {
            color = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .linkColor
            paint()
        }
    }

    private func paint() {
        let config = NSImage.SymbolConfiguration(pointSize: ToolPanelTable.codeBadgePointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}

/// The popover the (i) opens, at once: the module's name, its summary, and
/// **Open with Code**. What is still loading — the description, the code —
/// shows as progress where it will be.
@MainActor public final class ToolPanelModuleSummaryPopover: NSViewController {
    private let name: String
    private let popover = NSPopover()
    private var openCode: (() -> Void)?

    private let words = NSTextField(wrappingLabelWithString: "")
    private let wordsProgress = NSProgressIndicator()
    private let open = NSButton()
    private let codeProgress = NSProgressIndicator()
    private let codeState = NSTextField(labelWithString: "")

    private static var size: CGFloat { ToolPanelFont.size }
    private static var width: CGFloat { (size * 34).rounded() }
    private static var inset: CGFloat { (size * 1.2).rounded() }

    public init(name: String) {
        self.name = name
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func show(relativeTo rect: NSRect, of view: NSView) {
        popover.contentViewController = self
        popover.behavior = .transient
        popover.animates = false
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }

    public var isShown: Bool { popover.isShown }
    public func close() { popover.performClose(nil) }

    /// The description is read: its summary takes the progress's place.
    public func showSummary(_ summary: String) {
        loadViewIfNeeded()
        words.stringValue = summary
        words.isHidden = false
        wordsProgress.stopAnimation(nil)
        wordsProgress.isHidden = true
    }

    /// The code is loaded: **Open with Code** opens it.
    public func codeReady(_ open: @escaping () -> Void) {
        loadViewIfNeeded()
        openCode = open
        self.open.isEnabled = true
        codeProgress.stopAnimation(nil)
        codeProgress.isHidden = true
        codeState.isHidden = true
    }

    /// The code could not be loaded: why, instead of the progress.
    public func codeFailed(_ message: String) {
        loadViewIfNeeded()
        openCode = nil
        open.isEnabled = false
        codeProgress.stopAnimation(nil)
        codeProgress.isHidden = true
        codeState.stringValue = message
        codeState.isHidden = false
    }

    /// What the popover says and whether its code is loaded, for the tests.
    public var shownName: String { name }
    public var shownSummary: String? { words.isHidden ? nil : words.stringValue }
    public var isLoadingSummary: Bool { !wordsProgress.isHidden }
    public var isLoadingCode: Bool { !codeProgress.isHidden }
    public var canOpenCode: Bool { open.isEnabled }
    public func clickOpen() { open.performClick(nil) }

    override public func loadView() {
        let size = Self.size
        let inner = Self.width - 2 * Self.inset
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = (size * 0.6).rounded()
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)

        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: (size * 1.25).rounded(), weight: .bold)
        title.isSelectable = true
        title.lineBreakMode = .byTruncatingMiddle
        title.widthAnchor.constraint(lessThanOrEqualToConstant: inner).isActive = true
        stack.addArrangedSubview(title)

        // The summary's place, with a spinner in it until the description is read.
        wordsProgress.style = .spinning
        wordsProgress.controlSize = .small
        wordsProgress.isIndeterminate = true
        wordsProgress.startAnimation(nil)
        ControlHelp.describe(wordsProgress, L("Reading the module's description"))
        stack.addArrangedSubview(wordsProgress)
        words.font = .systemFont(ofSize: size)
        words.isSelectable = true
        words.preferredMaxLayoutWidth = inner
        words.widthAnchor.constraint(equalToConstant: inner).isActive = true
        words.isHidden = true
        stack.addArrangedSubview(words)

        // The button, dimmed beside a spinner until the code is loaded.
        open.title = L("Open with Code")
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.target = self
        open.action = #selector(openClicked)
        open.isEnabled = false
        ControlHelp.describe(open, L("Opens the module's bytes and its code"))
        codeProgress.style = .spinning
        codeProgress.controlSize = .small
        codeProgress.isIndeterminate = true
        codeProgress.startAnimation(nil)
        ControlHelp.describe(codeProgress, L("Loading the module's code"))
        codeState.font = .systemFont(ofSize: size)
        codeState.textColor = .secondaryLabelColor
        codeState.isHidden = true
        let row = NSStackView(views: [open, codeProgress, codeState])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = (size * 0.6).rounded()
        stack.addArrangedSubview(row)
        view = stack
    }

    @objc private func openClicked() {
        guard let openCode else { return }
        close()
        openCode()
    }
}
