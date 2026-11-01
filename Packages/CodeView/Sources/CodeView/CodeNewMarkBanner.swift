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
/// The words are one selectable text view rather than labels: a label that is
/// selected is drawn by the field editor, which brings its own font and line
/// pitch, and the plate would change shape under the reader's hand.
///
/// The pane fills it and hides it; the plate itself only draws what it is
/// given, and an empty list is not shown at all.
final class CodeNewMarkBanner: NSView {
    private let badge = PartBadgeView(text: "")
    private let words = NSTextView()
    private var wordsHeight: NSLayoutConstraint!

    /// What the plate says now, for a test.
    private(set) var titleShown = ""
    private(set) var bulletsShown: [String] = []

    /// Whether the plate's words can be selected and copied, for a test.
    var wordsAreSelectable: Bool { words.isSelectable }

    /// The points the plate's words are set in, for a test: selecting a word
    /// must not change its size or its line pitch.
    var wordFontPoints: [CGFloat] {
        guard let storage = words.textStorage, storage.length > 0 else { return [] }
        var points: Set<CGFloat> = []
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let font = value as? NSFont { points.insert(font.pointSize) }
        }
        return points.sorted()
    }

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

        words.isEditable = false
        words.isSelectable = true
        words.isRichText = true
        words.drawsBackground = false
        words.textContainerInset = .zero
        words.textContainer?.lineFragmentPadding = 0
        words.textContainer?.widthTracksTextView = false
        words.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        words.isHorizontallyResizable = false
        words.isVerticallyResizable = false
        words.translatesAutoresizingMaskIntoConstraints = false

        // The words are tied to the plate's own edges rather than left to a
        // stack's alignment: the plate takes the pane's whole width, and a
        // stack laid its views out at the trailing edge once it was wider
        // than they were.
        for view in [badge, words] { addSubview(view) }
        wordsHeight = words.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset + 1),
            words.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            words.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            words.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            wordsHeight,
            words.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset)
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

    /// The text is laid out at the width the plate has, and the plate is as
    /// tall as the words turn out to be: a list that wraps to three lines
    /// makes a taller plate.
    override func layout() {
        super.layout()
        guard let container = words.textContainer, let manager = words.layoutManager else { return }
        let width = max(0, words.frame.width)
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = (manager.usedRect(for: container).height).rounded(.up)
        if abs(wordsHeight.constant - height) > 0.5 {
            wordsHeight.constant = max(height, 1)
        }
    }

    /// Says what the mark is about: the title, then a bullet list, each line
    /// hanging under its own text as a list is read.
    func show(title: String, lines: [String]) {
        titleShown = title
        bulletsShown = lines
        setAccessibilityLabel(title)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 4
        let bulletStyle = NSMutableParagraphStyle()
        bulletStyle.headIndent = 14
        bulletStyle.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
        bulletStyle.paragraphSpacing = 3

        let body = NSMutableAttributedString(attributedString: NSAttributedString(
            string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: titleStyle
            ]))
        for (index, bullet) in lines.enumerated() {
            if index > 0 { body.append(NSAttributedString(string: "\n")) }
            body.append(NSAttributedString(string: "•\t\(bullet)", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: bulletStyle
            ]))
        }
        words.textStorage?.setAttributedString(body)
        needsLayout = true
        isHidden = false
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        titleShown = ""
        bulletsShown = []
    }
}
