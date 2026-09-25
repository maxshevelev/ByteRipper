import AppKit
import HelpBook

/// The prose, scrolling, with the book's own links live in it.
///
/// A read-only `NSTextView` rather than a stack of labels: the help is running
/// text with links in it, and a text view gives selection, copy, Find, VoiceOver
/// and link handling for free — all of which a column of labels would have to
/// be taught one at a time.
@MainActor public final class HelpBodyView: NSScrollView {
    /// A link in the text was clicked.
    public var onFollow: ((HelpLink) -> Void)?

    private let text = HelpTextView()

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = true
        borderType = .noBorder

        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 20, height: 18)
        // The prose follows the window's width and never scrolls sideways: a
        // help page that can be scrolled left and right is a help page whose
        // line length nobody chose.
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand
        ]
        text.onFollow = { [weak self] link in self?.onFollow?(link) }
        documentView = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `content`, scrolled back to the top: a new page starts at its
    /// title, never wherever the last one had been left.
    public func show(_ content: NSAttributedString) {
        text.textStorage?.setAttributedString(content)
        text.scroll(.zero)
        // The scroll view keeps its own idea of where it is, and setting the
        // document view's origin alone leaves it half a page down when the new
        // page is shorter than the last.
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    /// What the view is showing, for the tests that read it.
    public var shownText: String { text.string }
}

/// The text view itself, which is where a click on a link is caught.
private final class HelpTextView: NSTextView {
    var onFollow: ((HelpLink) -> Void)?

    /// AppKit's own answer for a clicked link. Returning true means "handled":
    /// the book's own links are followed inside the window, and anything else
    /// is left to the system — which is what an http link in a future page
    /// would need.
    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)),
              let destination = HelpText.link(from: url)
        else {
            super.clicked(onLink: link, at: charIndex)
            return
        }
        onFollow?(destination)
    }
}
