import AppKit
import HelpUI
import Localization

/// A command or a configuration the person copies into another program: the
/// whole text in a monospaced box, wrapped so none of it is hidden, and a copy
/// button beside it. The server console's copy line, in AppKit; the Agent and
/// Code Analysis tabs show every such text this way.
///
/// The text is a selectable label rather than a scroll view: what is copied is
/// all on screen, and part of it can still be selected by hand.
final class CopyableTextView: NSView {
    private let field = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    private var restore: DispatchWorkItem?
    private let copyHelp: String

    /// What is shown and what the button copies.
    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// `copyHelp` is the button's words: what it puts on the clipboard.
    init(text: String = "", copyHelp: String) {
        self.copyHelp = copyHelp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        field.stringValue = text
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.isSelectable = true
        // By words, and a path longer than the line breaks inside itself.
        field.lineBreakMode = .byWordWrapping
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = Self.symbol("doc.on.doc", copyHelp)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(copyText)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        ControlHelp.describe(button, copyHelp)

        addSubview(field)
        addSubview(button)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            button.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            // At the first line, not the middle: a long text wraps to several.
            button.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 20),
            bottomAnchor.constraint(greaterThanOrEqualTo: button.bottomAnchor, constant: 5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    /// The box follows the theme: its colours are read again on each change.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// The label wraps at the width the box is given, not at its own.
    override func layout() {
        super.layout()
        let width = field.frame.width
        if width > 0, field.preferredMaxLayoutWidth != width {
            field.preferredMaxLayoutWidth = width
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // A check mark for a moment says it was copied, where the person is looking.
        restore?.cancel()
        button.image = Self.symbol("checkmark", L("Copied"))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.button.image = Self.symbol("doc.on.doc", self.copyHelp)
        }
        restore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    /// For the tests: the copy button, as a person presses it.
    func copyForTesting() { copyText() }
}
