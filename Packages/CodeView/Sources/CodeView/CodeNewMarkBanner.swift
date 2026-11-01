import AppKit
import Localization
import ToolModuleKit

/// The plate over the code that says why the function on screen wears **New**
/// when the comparison cannot: what changed besides the code — another name,
/// another signature, a function this revision added — and, the code reading
/// the same in both revisions, what the mark is about then. A yellow notice,
/// as macOS draws one, over the code it is about, wearing the same **New**
/// badge the function's row wears, so the notice says what it is about before
/// its words are read.
///
/// The pane fills it and hides it; the plate itself only draws what it is
/// given, and an empty list is not shown at all.
final class CodeNewMarkBanner: NSView {
    private let badge = PartBadgeView(text: "")
    private let heading = NSTextField(labelWithString: "")
    private let bullets = NSTextField(labelWithString: "")

    /// What the plate says now, for a test.
    private(set) var titleShown = ""
    private(set) var bulletsShown: [String] = []

    /// Whether the plate's words can be selected and copied, for a test.
    var wordsAreSelectable: Bool { heading.isSelectable && bullets.isSelectable }

    /// The points the plate's words are set in, for a test: selecting a word
    /// must not change its size.
    var wordFontPoints: [CGFloat] { [heading.font?.pointSize ?? 0, bullets.font?.pointSize ?? 0] }

    /// The room between the plate's edge and its words.
    private static let inset: CGFloat = 10

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setAccessibilityRole(.group)

        badge.text = L("New")
        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.ink = .controlAccentColor
        badge.translatesAutoresizingMaskIntoConstraints = false

        heading.translatesAutoresizingMaskIntoConstraints = false
        // The plate is a notice the reader may want to quote: its words are
        // selected and copied as the code's are.
        heading.isSelectable = true
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .labelColor
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bullets.translatesAutoresizingMaskIntoConstraints = false
        bullets.isSelectable = true
        // A selected label is drawn by the field editor, which takes the
        // field's own font: left at the default, the words would grow as soon
        // as the reader selects one.
        bullets.font = .systemFont(ofSize: 12)
        bullets.lineBreakMode = .byWordWrapping
        bullets.maximumNumberOfLines = 0
        bullets.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The words are tied to the plate's own edges rather than left to a
        // stack's alignment: the plate takes the pane's whole width, and a
        // stack laid its views out at the trailing edge once it was wider
        // than they were.
        for view in [badge, heading, bullets] { addSubview(view) }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            heading.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.inset),
            heading.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            bullets.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            bullets.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            bullets.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 6),
            bullets.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The plate's ground and border follow the appearance, as the code's do.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = CodeColors.newMarkBannerBackground.cgColor
            layer?.borderColor = CodeColors.newMarkBannerBorder.cgColor
        }
    }

    /// Says what the mark is about. A bullet list, each line hanging under its
    /// own text as a list is read.
    func show(title: String, lines: [String]) {
        titleShown = title
        bulletsShown = lines
        heading.stringValue = title
        setAccessibilityLabel(title)
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 14
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
        paragraph.paragraphSpacing = 3
        let text = NSMutableAttributedString()
        for (index, bullet) in lines.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: "•\t\(bullet)", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        }
        bullets.attributedStringValue = text
        isHidden = false
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        titleShown = ""
        bulletsShown = []
    }
}
