import AppKit

/// The one layout of an information popover (`Design/DESIGN_GUIDE.md` §2.1):
/// one that says what something is and offers the one place it leads to —
/// the function under a call, a name the code explains, a function's callers,
/// a module's summary in the UEFI tree.
///
/// The metrics were written in each popover and had drifted apart: the
/// module summary's title, margins, prose and width were all a little
/// smaller than the code panel's three, and its action was the default
/// button where **Go to Function** was not. They live here once; a popover
/// asks for its parts rather than spelling sizes.
///
/// Every size follows the app's Zoom (`ToolPanelFont.size`), read when the
/// popover is made.
@MainActor public enum ToolPanelPopover {
    /// Body text: the zoom.
    public static var size: CGFloat { ToolPanelFont.size }
    /// The popover's width, margins included, unless its content sets it (a
    /// table sized to its columns).
    public static var width: CGFloat { (size * 40).rounded() }
    /// The margin on all four sides.
    public static var margin: CGFloat { (size * 1.3).rounded() }
    /// Between the parts.
    public static var spacing: CGFloat { (size * 0.6).rounded() }
    /// The width inside the margins: what a wrapping text is laid out to.
    public static var inner: CGFloat { width - 2 * margin }
    /// How tall prose grows before it scrolls inside the popover.
    public static var tallestProse: CGFloat { (size * 22).rounded() }

    public static var titleFont: NSFont { .systemFont(ofSize: (size * 1.2).rounded(), weight: .bold) }
    /// Prose a reader reads — a summary, a plate: the body size, as the help
    /// popovers' words are (`HelpPopoverLayout.bodySize`).
    public static var proseFont: NSFont { .systemFont(ofSize: size) }
    /// A header over a part of the popover.
    public static var headerFont: NSFont { .systemFont(ofSize: size, weight: .semibold) }
    /// Where the words come from, under them: smaller.
    public static var noteFont: NSFont { .systemFont(ofSize: max(size - 2, 9)) }

    /// The column the parts stand in, top to bottom.
    public static func stack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    /// The title, bold, cut in the middle when it is longer than `inner`.
    public static func title(_ text: String, width: CGFloat? = nil) -> NSTextField {
        let title = NSTextField(labelWithString: text)
        title.font = titleFont
        title.isSelectable = true
        title.lineBreakMode = .byTruncatingMiddle
        title.widthAnchor.constraint(lessThanOrEqualToConstant: width ?? inner).isActive = true
        return title
    }

    /// Prose, wrapped to `inner`. Secondary colour when it says that there is
    /// nothing to say yet (`said == false`).
    public static func prose(_ text: String, said: Bool = true) -> NSTextField {
        let words = NSTextField(wrappingLabelWithString: text)
        words.font = proseFont
        words.textColor = said ? .labelColor : .secondaryLabelColor
        words.isSelectable = true
        words.preferredMaxLayoutWidth = inner
        return words
    }

    /// The one action the popover leads to: a regular button, and the
    /// default one — the popover is for it, so Return does it and it wears
    /// the accent colour.
    public static func action(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        return button
    }

    /// `stack` inside its margins, `width` wide in all. The margins are the
    /// container's constraints, not the stack's `edgeInsets`: with a wrapping
    /// label in it a stack reports a width without its right inset, and the
    /// popover cuts the text at its edge.
    public static func content(_ stack: NSStackView, width: CGFloat? = nil) -> NSView {
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width ?? Self.width),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),
        ])
        return container
    }

    /// `content` in a box `height` tall at most that scrolls, `width` wide:
    /// a long list or a long text keeps the popover on the screen.
    public static func scrolling(_ content: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        content.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let rows = content.fittingSize.height
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.widthAnchor.constraint(equalToConstant: width),
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: min(rows, height)),
        ])
        return scroll
    }

    /// A clip view that starts at the top.
    private final class FlippedClip: NSClipView {
        override var isFlipped: Bool { true }
    }

    /// Shows `controller` in `popover` beside `rect`: transient, at once.
    /// `.maxY` from a word in text; `.maxX` from a row of a list or a tree,
    /// so the rows under it stay in sight.
    public static func show(_ popover: NSPopover, with controller: NSViewController,
                            relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge) {
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
    }
}
