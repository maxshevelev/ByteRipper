import AppKit
import CodeAnalysis
import Localization

/// What a name in the code stands for, in a popover off the name: a constant
/// a review named (`PCI_CONFIG_ADDRESS`), a type the C names, a field of a
/// structure — or the one line that stands for the blocks the decompiler left
/// out as unreachable.
///
/// The reader clicked a name because the code does not say what it is. The
/// answer is the review's words for it and where they come from, the facts
/// under the name — the number, the enum, the type's C — and, for a
/// constant, the instructions that hold it, each a way there.
@MainActor final class CodeExplanationPopover: NSViewController {
    private let explanation: CodeExplanation
    private let model: CodeModel
    private let popover = NSPopover()
    /// Goes to a use: the instruction's line in the listing.
    var onUse: ((Int) -> Void)?

    /// More uses than this scroll inside the popover.
    private static let mostUses = 12

    /// The popover's type follows the code's zoom: the body a little larger
    /// than the code, as Xcode's Quick Help is, the name larger still.
    private static var size: CGFloat { CodePaneView.codeFont().pointSize }
    private static var width: CGFloat { (size * 40).rounded() }
    private static var inset: CGFloat { (size * 1.3).rounded() }

    init(explanation: CodeExplanation, model: CodeModel) {
        self.explanation = explanation
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.contentViewController = self
        popover.behavior = .transient
        popover.animates = false
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    var isShown: Bool { popover.isShown }

    var explanationShown: CodeExplanation { explanation }

    func close() { popover.performClose(nil) }

    override func loadView() {
        let size = Self.size
        let inner = Self.width - 2 * Self.inset
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = (size * 0.6).rounded()
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)

        let name = NSTextField(labelWithString: title())
        name.font = .systemFont(ofSize: (size * 1.35).rounded(), weight: .bold)
        name.isSelectable = true
        name.lineBreakMode = .byTruncatingMiddle
        name.widthAnchor.constraint(lessThanOrEqualToConstant: inner).isActive = true
        stack.addArrangedSubview(name)

        let facts = NSTextField(labelWithString: factsText())
        facts.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        facts.textColor = .secondaryLabelColor
        facts.isSelectable = true
        facts.lineBreakMode = .byTruncatingTail
        facts.widthAnchor.constraint(lessThanOrEqualToConstant: inner).isActive = true
        stack.addArrangedSubview(facts)

        let said = wordsText()
        let words = NSTextField(wrappingLabelWithString: said ?? L("The review has not explained this name yet."))
        words.font = .systemFont(ofSize: size + 1)
        words.textColor = said == nil ? .secondaryLabelColor : .labelColor
        words.isSelectable = true
        words.preferredMaxLayoutWidth = inner
        stack.addArrangedSubview(words)

        if let c = explanation.c {
            stack.setCustomSpacing(size, after: words)
            let code = codeBox(c, width: inner)
            stack.addArrangedSubview(code)
            stack.setCustomSpacing(size, after: code)
        }

        if !explanation.uses.isEmpty {
            let removed: Bool
            if case .unreachable = explanation.subject { removed = true } else { removed = false }
            let header = NSTextField(labelWithString: removed ? L("Removed blocks") : L("Used at"))
            header.font = .systemFont(ofSize: size + 1, weight: .semibold)
            stack.addArrangedSubview(header)
            let list = NSStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = stack.spacing / 2
            for use in explanation.uses {
                // The removed blocks are all the function's own: the address says it.
                let title = removed ? model.displayAddress(use.address)
                    : "\(model.functions[use.function].name) · \(model.displayAddress(use.address))"
                let button = NSButton(title: title, target: self, action: #selector(goToUse(_:)))
                button.isBordered = false
                button.font = .monospacedSystemFont(ofSize: size, weight: .regular)
                button.contentTintColor = .linkColor
                button.tag = use.line
                list.addArrangedSubview(button)
            }
            stack.addArrangedSubview(explanation.uses.count > Self.mostUses
                                     ? Self.scrolling(list, width: inner, height: (size * 18).rounded()) : list)
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
    }

    /// A long list of uses in a box of its own height that scrolls, so the
    /// popover stays on the screen.
    static func scrolling(_ list: NSStackView, width: CGFloat, height: CGFloat) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        list.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let rows = list.fittingSize.height
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            list.widthAnchor.constraint(equalToConstant: width),
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: min(rows, height))
        ])
        return scroll
    }

    /// The name as the code writes it; the removed blocks' line has a title.
    func title() -> String {
        if case .unreachable = explanation.subject { return L("Unreachable blocks") }
        return explanation.name
    }

    /// The review's words; for the removed blocks, what the decompiler did.
    func wordsText() -> String? {
        if case .unreachable = explanation.subject {
            return L("Ghidra's decompiler found that, with the values it knows, no path runs these blocks, and left them out of the C. Their instructions are still in the listing. A block that depends on what the hardware answers, such as a check Ghidra's model cannot fail, may still run on the board.")
        }
        return explanation.text
    }

    /// The number and its enum; a type's kind and size; a field's
    /// declaration and offset; how many blocks were removed.
    func factsText() -> String {
        switch explanation.subject {
        case .unreachable(let blocks):
            return String(format: L("%1$@ blocks removed from the C"), "\(blocks)")
        case .constant(_, let value):
            let number = CodeModel.number(value)
            guard let owner = explanation.enumName else { return number }
            return "\(number) · enum \(owner)"
        case .type:
            let kind = explanation.kind ?? ""
            guard explanation.size > 0 else { return kind }
            return String(format: L("%1$@ · %2$@ bytes"), kind, String(format: "0x%X", explanation.size))
        case .field(let type, let offset):
            let place = String(format: L("at +0x%1$@ in %2$@"), String(offset, radix: 16, uppercase: true), type)
            guard let declaration = explanation.declaration else { return place }
            return "\(declaration) · \(place)"
        }
    }

    /// The type's C on the page's own light ground in a rounded box, as
    /// Xcode sets a declaration: coloured as the code is, the field asked
    /// about marked, a long line scrolling inside.
    private func codeBox(_ c: String, width: CGFloat) -> NSView {
        let font = CodePaneView.codeFont()
        var links: [CodeLink] = []
        let text = NSMutableAttributedString(attributedString: CodeColors.attributed(
            c, tokens: model.lexC(c), font: font, links: &links, asTextLinks: false))
        if case .field(_, let offset) = explanation.subject,
           let line = Self.lineRange(in: c, offset: offset, name: String(explanation.name.split(separator: ".").last ?? "")) {
            text.addAttribute(.backgroundColor, value: CodeColors.symbolHighlight, range: line)
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        let pad = (font.pointSize * 0.8).rounded()
        textView.textContainerInset = NSSize(width: pad, height: pad)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                      height: CGFloat.greatestFiniteMagnitude)
        // Wider than the box when a line is: the text view grows to its
        // longest line instead of following the scroll view's width, and the
        // box scrolls sideways.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(text)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        textView.minSize = NSSize(width: width, height: 0)
        textView.setFrameSize(NSSize(width: max(ceil(used.width) + 2 * pad, width), height: ceil(used.height) + 2 * pad))
        let scroller = used.width + 2 * pad > width
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle) : 0
        let height = min(ceil(used.height) + 2 * pad + 2 + (NSScroller.preferredScrollerStyle == .legacy ? scroller : 0),
                         (font.pointSize * 20).rounded())

        let box = CodeSnippetBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: width),
            box.heightAnchor.constraint(equalToConstant: height)
        ])
        return box
    }

    /// The characters of a field's line in the type's C, `/* 0x04 */ … Name;`.
    static func lineRange(in c: String, offset: Int, name: String) -> NSRange? {
        let mark = String(format: "/* 0x%02X */", offset)
        let text = c as NSString
        var found: NSRange?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, _, stop in
            guard let line, line.contains(mark),
                  line.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b",
                             options: .regularExpression) != nil else { return }
            found = range
            stop.pointee = true
        }
        return found
    }

    @objc private func goToUse(_ sender: NSButton) {
        close()
        onUse?(sender.tag)
    }
}

/// A clip view whose list starts at the top, as a list is read.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// The light rounded ground a code snippet sits on in the popover: the
/// text background, a hairline border, as Xcode's Quick Help draws one.
final class CodeSnippetBox: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
