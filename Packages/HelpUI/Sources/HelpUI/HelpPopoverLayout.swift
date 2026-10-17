import AppKit

/// The one shape every help popover has: a title over the words, flat on the
/// popover's own background, both from the same left edge, and as tall as the
/// words up to a limit past which they scroll.
///
/// Shared because a term's popover and a setting's answer the same kind of
/// question in the same place; two shapes for it read as two kinds of thing.
/// The type is the panel's rather than the help window's: a popover is read
/// beside a dump, at the size of the rows it explains, and the window's
/// reading size made a paragraph of it fill the box.
@MainActor public enum HelpPopoverLayout {
    /// The popover's width, and the margin its title and words keep from its
    /// edges.
    public static let width: CGFloat = 340
    public static let margin: CGFloat = 14
    /// The tallest the words get before they scroll: about twenty lines.
    public static let maxBodyHeight: CGFloat = 320
    /// The title's size and the words'.
    public static let titleSize: CGFloat = 15
    public static let bodySize: CGFloat = 12

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

    /// The popover's view: `title` over `body`, and `footer` — a button that
    /// takes the reader further — under them at the right, where there is
    /// one. Returns the view and the height the words were given.
    public static func build(title: NSTextField, body: HelpBodyView,
                             footer: NSView? = nil) -> (view: NSView, bodyHeight: CGFloat) {
        let root = NSView()
        // The words on the popover's background, not on a page of their own:
        // a white page under a material title is two surfaces where one is
        // meant.
        body.drawsBackground = false
        body.textInset = NSSize(width: margin, height: 0)
        let height = min(body.contentHeight(width: width), maxBodyHeight)

        for subview in [title, body] + (footer.map { [$0] } ?? []) { root.addSubview(subview) }
        var constraints = [
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
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
