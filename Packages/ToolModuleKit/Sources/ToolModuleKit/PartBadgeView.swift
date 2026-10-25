import AppKit

/// A word in a capsule: what a part's codec says its bytes are
/// (`PartCodec.badge`) — in a fragment panel's header, on its pill in the
/// dock, on an agent's annotation card and in the UEFI panel's search results.
/// Here rather than in the app because a tool-module draws it too, and one
/// badge drawn by two pieces of code is two badges that drift apart.
///
/// Drawn rather than built from a layer, so the fill follows the appearance:
/// a layer's colour is a `CGColor` fixed when it was set, and a capsule that
/// stays light after the window goes dark is a capsule nobody can read.
public final class PartBadgeView: NSView {
    public var text = "" {
        didSet {
            label.stringValue = text
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Whether the word is a conversion the bytes went through — `LZMA`,
    /// `XOR 77` — rather than something else about them, `Read-only` or
    /// `Code`. A conversion carries ⇄ before the word.
    public var isTransform = false {
        didSet {
            guard isTransform != oldValue else { return }
            placeSymbol()
            invalidateIntrinsicContentSize()
        }
    }

    /// A symbol before the word, for a badge that is a kind rather than a
    /// conversion — the code glyph on a `Code` badge. Ignored while
    /// `isTransform` draws its own ⇄.
    public var symbolName: String? {
        didSet {
            guard symbolName != oldValue else { return }
            placeSymbol()
            invalidateIntrinsicContentSize()
        }
    }

    /// The word's font; the symbol is sized from it.
    public var font: NSFont = .systemFont(ofSize: 10, weight: .medium) {
        didSet {
            label.font = font
            symbolView.symbolConfiguration = Self.symbolConfiguration(for: font)
            invalidateIntrinsicContentSize()
        }
    }

    /// The colour to draw in on a filled background — a selected pill's —
    /// where the label colour on a quaternary capsule does not read: the
    /// word in it, the capsule a wash of it. Nil for the ordinary label colour.
    public var ink: NSColor? {
        didSet {
            guard ink != oldValue else { return }
            label.textColor = ink ?? .labelColor
            symbolView.contentTintColor = label.textColor
            needsDisplay = true
        }
    }

    private let label = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    private lazy var labelAtInset = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset.width)
    private lazy var labelAfterSymbol = label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: Self.symbolGap)
    private static let inset = NSSize(width: 6, height: 1)
    private static let symbolGap: CGFloat = 3

    private static func symbolConfiguration(for font: NSFont) -> NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: font.pointSize - 2, weight: .semibold)
    }

    public init(text: String = "", isTransform: Bool = false,
                symbolName: String? = nil) {
        super.init(frame: .zero)
        label.font = font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        symbolView.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        symbolView.symbolConfiguration = Self.symbolConfiguration(for: font)
        symbolView.contentTintColor = .labelColor
        symbolView.isHidden = true
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)
        self.symbolName = symbolName
        // Breakable: a header with no badge collapses this view to no width,
        // and two required insets inside nothing are a conflict the engine
        // resolves by breaking something of the window's instead.
        let symbolLeading = symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset.width)
        let trailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset.width)
        for constraint in [labelAtInset, labelAfterSymbol, symbolLeading, trailing] {
            constraint.priority = .defaultHigh
        }
        NSLayoutConstraint.activate([
            symbolLeading, trailing,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        self.text = text
        label.stringValue = text
        self.isTransform = isTransform
        placeSymbol()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var hasSymbol: Bool { isTransform || symbolName != nil }

    /// Shows the symbol and moves the word after it, or hides it and moves the
    /// word back.
    private func placeSymbol() {
        if isTransform {
            symbolView.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                       accessibilityDescription: nil)
        } else if let symbolName {
            symbolView.image = NSImage(systemSymbolName: symbolName,
                                       accessibilityDescription: nil)
        }
        symbolView.symbolConfiguration = Self.symbolConfiguration(for: font)
        symbolView.isHidden = !hasSymbol
        labelAtInset.isActive = !hasSymbol
        labelAfterSymbol.isActive = hasSymbol
    }

    public override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        let symbolWidth = hasSymbol ? symbolView.intrinsicContentSize.width + Self.symbolGap : 0
        return NSSize(width: size.width + symbolWidth + 2 * Self.inset.width, height: size.height + 2 * Self.inset.height)
    }

    public override func accessibilityValue() -> Any? { text }

    public override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (ink?.withAlphaComponent(0.25) ?? NSColor.quaternaryLabelColor).setFill()
        path.fill()
    }
}
