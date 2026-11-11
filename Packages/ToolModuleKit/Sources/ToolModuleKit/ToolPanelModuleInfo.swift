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
/// description's title, in a popover, read without opening the code.
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
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ToolPanelTable.codeBadgePointSize, weight: .regular))
        image?.isTemplate = true
        contentTintColor = .secondaryLabelColor
        setButtonType(.momentaryChange)
        target = nil
        action = #selector(ToolPanelModuleInfoResponder.showModuleInfo(_:))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
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

    /// On a selected row the (i) takes the selection's text colour, as the
    /// glyphs beside it do.
    public var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet {
            contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
}

/// The popover the (i) opens: the module's name, its summary, and
/// **Open with Code**.
@MainActor public final class ToolPanelModuleSummaryPopover: NSViewController {
    private let name: String
    private let summary: String
    private let openCode: () -> Void
    private let popover = NSPopover()

    private static var size: CGFloat { ToolPanelFont.size }
    private static var width: CGFloat { (size * 34).rounded() }
    private static var inset: CGFloat { (size * 1.2).rounded() }

    public init(name: String, summary: String, openCode: @escaping () -> Void) {
        self.name = name
        self.summary = summary
        self.openCode = openCode
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

    /// What the popover says, for the tests.
    public var shownName: String { name }
    public var shownSummary: String { summary }

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

        let words = NSTextField(wrappingLabelWithString: summary)
        words.font = .systemFont(ofSize: size)
        words.isSelectable = true
        words.preferredMaxLayoutWidth = inner
        words.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(words)

        let open = NSButton(title: L("Open with Code"), target: self, action: #selector(openClicked))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        ControlHelp.describe(open, L("Opens the module's bytes and its code"))
        stack.addArrangedSubview(open)
        view = stack
    }

    @objc private func openClicked() {
        close()
        openCode()
    }
}
