import AppKit
import HelpUI
import Localization

/// What answers a click on a row's (i): the panel's controller, found up the
/// responder chain from the button, so a recycled cell needs no target.
@MainActor @objc public protocol ToolPanelModuleInfoResponder {
    /// The (i) of the row holding `sender` was clicked.
    func showModuleInfo(_ sender: NSButton)
}

/// The (i) a row wears where something stands behind it to open: a module's
/// summary in the UEFI tree, a CPUID's processors in the FIT table. A real
/// button, so a click on it is the button's and never the text's or the
/// row's; a link's colour, because it opens something; the size of the
/// code badges beside it (`Design/DESIGN_GUIDE.md` §4).
public class ToolPanelInfoButton: NSButton {
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
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        paint()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The glyph's side, for a place that sets the button by hand.
    public static var side: CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: ToolPanelTable.codeBadgePointSize, weight: .semibold)
        return NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.size.width ?? ToolPanelTable.codeBadgePointSize
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

// help: panel.uefi.module-summary
/// The (i) after a module's badges: its summary, the paragraph under its
/// description's title, in a popover, read without opening the code.
public final class ToolPanelModuleInfoButton: ToolPanelInfoButton {
    override public init(frame: NSRect) {
        super.init(frame: frame)
        // The panel's controller sets itself as the target when it makes the
        // cell; nil sends up the responder chain, which reaches the controller
        // only while the focus is in its own panel.
        target = nil
        action = #selector(ToolPanelModuleInfoResponder.showModuleInfo(_:))
        ControlHelp.describe(self, name: L("Module summary"),
                             tooltip: L("Shows the module's summary from its description"))
        isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var tag: Int {
        get { ToolPanelTable.codeInfoTag }
        set {}
    }
}

/// The popover the (i) opens, at once: the module's name, its summary, and
/// **Open with Code**. What is still loading — the description, the code —
/// shows as progress where it will be.
@MainActor public final class ToolPanelModuleSummaryPopover: NSViewController {
    private let name: String
    private let popover = NSPopover()
    private var openCode: (() -> Void)?

    private lazy var words = ToolPanelPopover.prose("")
    private let wordsProgress = NSProgressIndicator()
    private lazy var open = ToolPanelPopover.action(L("Open with Code"), target: self,
                                                    action: #selector(openClicked))
    private let codeProgress = NSProgressIndicator()
    private let codeState = NSTextField(labelWithString: "")

    public init(name: String) {
        self.name = name
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func show(relativeTo rect: NSRect, of view: NSView) {
        // From a row of the tree: beside it, so the rows under it stay in sight.
        ToolPanelPopover.show(popover, with: self, relativeTo: rect, of: view, edge: .maxX)
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
        let stack = ToolPanelPopover.stack()
        stack.addArrangedSubview(ToolPanelPopover.title(name))

        // The summary's place, with a spinner in it until the description is read.
        wordsProgress.style = .spinning
        wordsProgress.controlSize = .small
        wordsProgress.isIndeterminate = true
        wordsProgress.startAnimation(nil)
        ControlHelp.describe(wordsProgress, L("Reading the module's description"))
        stack.addArrangedSubview(wordsProgress)
        words.widthAnchor.constraint(equalToConstant: ToolPanelPopover.inner).isActive = true
        words.isHidden = true
        stack.addArrangedSubview(words)

        // The button, dimmed beside a spinner until the code is loaded.
        open.isEnabled = false
        ControlHelp.describe(open, L("Opens the module's bytes and its code"))
        codeProgress.style = .spinning
        codeProgress.controlSize = .small
        codeProgress.isIndeterminate = true
        codeProgress.startAnimation(nil)
        ControlHelp.describe(codeProgress, L("Loading the module's code"))
        codeState.font = .systemFont(ofSize: ToolPanelPopover.size)
        codeState.textColor = .secondaryLabelColor
        codeState.isHidden = true
        let row = NSStackView(views: [open, codeProgress, codeState])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = ToolPanelPopover.spacing
        stack.addArrangedSubview(row)
        view = ToolPanelPopover.content(stack)
    }

    @objc private func openClicked() {
        guard let openCode else { return }
        close()
        openCode()
    }
}
