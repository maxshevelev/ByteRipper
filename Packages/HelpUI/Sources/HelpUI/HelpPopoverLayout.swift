import AppKit

/// The one shape every help popover has: a title over the words, flat on the
/// popover's own background, both from the same left edge, and as tall as the
/// words up to a limit past which they scroll.
///
/// Shared because a term's popover and a setting's answer the same kind of
/// question in the same place; two shapes for it read as two kinds of thing.
/// The type is a panel's detail list's rather than the help window's — its
/// body size for the words, its heading size for the title — and it follows
/// the app's Zoom with them: a popover is read beside the rows it explains,
/// and at another size than theirs it reads as another thing.
@MainActor public enum HelpPopoverLayout {
    /// The size the words are drawn at: the panels' body size, which is the
    /// app's Zoom. HelpUI cannot read it itself — the panels' font lives in
    /// ToolModuleKit, which links HelpUI — so the app hands it in at launch,
    /// with the notification that says it moved.
    public static var textSize: @MainActor () -> CGFloat = { designSize }
    public static var textSizeDidChange: Notification.Name?

    /// The size the box below was drawn for; at any other the box grows or
    /// shrinks with the type, so a line holds the same words at every zoom.
    static let designSize: CGFloat = 13

    /// The words' size, and the title's — one point over, as a detail's
    /// heading is over its rows.
    public static var bodySize: CGFloat { textSize() }
    public static var titleSize: CGFloat { bodySize + 1 }

    /// The popover's width, and the margin its title and words keep from its
    /// edges.
    public static var width: CGFloat { scaled(340) }
    public static let margin: CGFloat = 14
    /// The tallest the words get before they scroll: about twenty lines.
    public static var maxBodyHeight: CGFloat { scaled(320) }

    private static func scaled(_ length: CGFloat) -> CGFloat {
        (length * bodySize / designSize).rounded()
    }

    /// Calls `handler` whenever the size moves, for a popover on screen to
    /// lay itself out again; the token is the caller's to keep. Nil where
    /// nobody said which notification that is.
    public static func observeTextSize(
        _ handler: @escaping @Sendable @MainActor () -> Void
    ) -> NSObjectProtocol? {
        guard let name = textSizeDidChange else { return nil }
        return NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    /// The title: what the popover is about.
    public static func title(_ words: String) -> NSTextField {
        let title = NSTextField(labelWithString: words)
        title.font = .systemFont(ofSize: titleSize, weight: .semibold)
        title.alignment = .left
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        return title
    }

    /// Plain words — a line break where the text has one — at the popover's
    /// size.
    public static func prose(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.alignment = .left
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: bodySize),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ])
    }

    /// Text rendered for the help window (`HelpText`), brought down to the
    /// popover's size: every font and every spacing by the same factor, so
    /// the text keeps its proportions.
    /// The newline that ends the window's last paragraph is dropped: in a
    /// popover sized to its words it is an empty line under them.
    public static func fitted(_ text: NSAttributedString) -> NSAttributedString {
        let scaled = NSMutableAttributedString(
            attributedString: HelpText.scaled(text, by: bodySize / HelpText.Size.body))
        while scaled.string.hasSuffix("\n") {
            scaled.deleteCharacters(in: NSRange(location: scaled.length - 1, length: 1))
        }
        return scaled
    }

    /// A line of the caller's own under the title: what a panel knows about
    /// the row that the row's name has no room for — a setting's condition, the
    /// thing that switches it off. Quiet, and as wide as the words up to the
    /// popover's margin, wrapping onto a second line rather than being cut.
    public static func note(_ words: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: words)
        note.font = .systemFont(ofSize: bodySize)
        note.textColor = .secondaryLabelColor
        note.isSelectable = true
        note.translatesAutoresizingMaskIntoConstraints = false
        return note
    }

    /// The popover's view: `title` over `body` — with `note`, where there is
    /// one, between them — and `footer`, a button that takes the reader
    /// further, under them at the right. Returns the view and the height the
    /// words were given.
    public static func build(title: NSTextField, body: HelpBodyView, note: NSTextField? = nil,
                             footer: NSView? = nil) -> (view: NSView, bodyHeight: CGFloat) {
        let root = NSView()
        // The words on the popover's background, not on a page of their own:
        // a white page under a material title is two surfaces where one is
        // meant.
        body.drawsBackground = false
        body.textInset = NSSize(width: margin, height: 0)
        let needed = body.contentHeight(width: width)
        let height = min(needed, maxBodyHeight)
        // Words that fit do not scroll: no scroller, and no bounce that would
        // say there was more to see.
        let fits = needed <= maxBodyHeight
        body.hasVerticalScroller = !fits
        body.verticalScrollElasticity = fits ? .none : .automatic
        body.horizontalScrollElasticity = .none

        for subview in [title, body] + (note.map { [$0] } ?? []) + (footer.map { [$0] } ?? []) {
            root.addSubview(subview)
        }
        var constraints = [
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
        ]
        if let note {
            constraints += [
                note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
                note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            ]
        }
        constraints += [
            body.topAnchor.constraint(equalTo: (note ?? title).bottomAnchor, constant: 6),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.heightAnchor.constraint(equalToConstant: height),

            root.widthAnchor.constraint(equalToConstant: width),
        ]
        if let footer {
            footer.translatesAutoresizingMaskIntoConstraints = false
            constraints += [
                footer.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
                footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
                footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            ]
        } else {
            constraints.append(body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12))
        }
        NSLayoutConstraint.activate(constraints)
        return (root, height)
    }
}
