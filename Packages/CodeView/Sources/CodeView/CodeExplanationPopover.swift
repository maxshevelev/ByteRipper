import AppKit
import CodeAnalysis
import Localization

/// What a name in the code stands for, in a popover off the name: a constant
/// a review named (`PCI_CONFIG_ADDRESS`), a type the C names, a field of a
/// structure.
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

    /// The widest a popover gets; a type's long line scrolls inside it.
    private static let width: CGFloat = 460
    private static let codeHeight: CGFloat = 240
    private static let mostUses = 12

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
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let name = NSTextField(labelWithString: explanation.name)
        name.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        name.isSelectable = true
        name.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(name)

        let facts = NSTextField(labelWithString: factsText())
        facts.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        facts.textColor = .secondaryLabelColor
        facts.isSelectable = true
        stack.addArrangedSubview(facts)

        let words = NSTextField(wrappingLabelWithString: explanation.text
                                ?? L("The review has not explained this name yet."))
        words.font = .systemFont(ofSize: 12)
        words.textColor = explanation.text == nil ? .secondaryLabelColor : .labelColor
        words.isSelectable = true
        words.preferredMaxLayoutWidth = Self.width - 28
        stack.addArrangedSubview(words)
        stack.setCustomSpacing(10, after: words)

        if let c = explanation.c {
            let code = codeView(c)
            stack.addArrangedSubview(code)
            code.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        }

        if !explanation.uses.isEmpty {
            let header = NSTextField(labelWithString: L("Used at"))
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            for use in explanation.uses.prefix(Self.mostUses) {
                let title = "\(model.functions[use.function].name) · \(model.displayAddress(use.address))"
                let button = NSButton(title: title, target: self, action: #selector(goToUse(_:)))
                button.isBordered = false
                button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                button.contentTintColor = .linkColor
                button.tag = use.line
                stack.addArrangedSubview(button)
            }
            if explanation.uses.count > Self.mostUses {
                let more = NSTextField(labelWithString: String(
                    format: L("and %1$@ more"), "\(explanation.uses.count - Self.mostUses)"))
                more.font = .systemFont(ofSize: 11)
                more.textColor = .secondaryLabelColor
                stack.addArrangedSubview(more)
            }
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
    }

    /// The number and its enum; a type's kind and size; a field's
    /// declaration and offset.
    func factsText() -> String {
        switch explanation.subject {
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

    /// The type's C, coloured as the code is, the field asked about marked.
    private func codeView(_ c: String) -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var links: [CodeLink] = []
        let text = NSMutableAttributedString(attributedString: CodeColors.attributed(
            c, tokens: model.lexC(c), font: font, links: &links, asTextLinks: false))
        if case .field(_, let offset) = explanation.subject,
           let line = Self.lineRange(in: c, offset: offset, name: String(explanation.name.split(separator: ".").last ?? "")) {
            text.addAttribute(.backgroundColor, value: CodeColors.symbolHighlight, range: line)
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                      height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.textStorage?.setAttributedString(text)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        let height = min(ceil(used) + 4, Self.codeHeight)
        scroll.heightAnchor.constraint(equalToConstant: max(height, 16)).isActive = true
        return scroll
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
