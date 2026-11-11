import AppKit
import CodeAnalysis
import Localization
import HelpUI
import ToolModuleKit

/// What a called function is, in a popover off the call: its name, its
/// signature, how far its review has got, the review's description of it and
/// a way there. The reader asks this without leaving the function they read;
/// ⌘-click and a double click still go there at once.
@MainActor final class CodeFunctionPopover: NSViewController {
    let function: CodeArtifact.Function
    /// The function's mark, as the list draws it: how far its review has got.
    let mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor)
    private let signatureTokens: [CodeToken]
    private let onGo: () -> Void
    private let popover = NSPopover()

    private static var size: CGFloat { ToolPanelPopover.size }

    init(function: CodeArtifact.Function, mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor),
         signatureTokens: [CodeToken], onGo: @escaping () -> Void) {
        self.function = function
        self.mark = mark
        self.signatureTokens = signatureTokens
        self.onGo = onGo
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(relativeTo rect: NSRect, of view: NSView) {
        ToolPanelPopover.show(popover, with: self, relativeTo: rect, of: view, edge: .maxY)
    }

    var isShown: Bool { popover.isShown }

    func close() { popover.performClose(nil) }

    /// The words the popover shows under the facts, for a test as well.
    var descriptionText: String? { Self.plate(ofC: function.c) }

    /// The first paragraph of what the review wrote over the function: the
    /// comments the C opens with, before its signature. It says what the
    /// function is for; the rest of the plate is read at the function. A
    /// decompiler's warning there is not the review's.
    static func plate(ofC c: String?) -> String? {
        guard var rest = c?[...] else { return nil }
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard rest.hasPrefix("/*"), let end = rest.range(of: "*/") else { return nil }
            let inner = rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]
            rest = rest[end.upperBound...]
            let lines = inner.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .drop(while: \.isEmpty)
                .prefix { !$0.isEmpty }
            let text = lines.joined(separator: " ")
            if !text.isEmpty, !text.hasPrefix("WARNING:") { return text }
        }
    }

    /// The signature, coloured as the code is.
    var signatureText: NSAttributedString? {
        guard let signature = function.signature else { return nil }
        var links: [CodeLink] = []
        return CodeColors.attributed(signature, tokens: signatureTokens,
                                     font: ToolPanelFont.monospaced(size: Self.size, bold: false),
                                     links: &links, asTextLinks: false, spacedCommas: true)
    }

    override func loadView() {
        let size = Self.size
        let inner = ToolPanelPopover.inner
        let stack = ToolPanelPopover.stack()

        // The pointer over the mark says the level and what is missing.
        let side = CodeNavigatorIcon.side(forFontSize: ToolPanelPopover.titleFont.pointSize)
        let image = CodeNavigatorIcon.image(mark.glyph, color: mark.color, side: side)
        let icon = NSImageView(image: image)
        icon.widthAnchor.constraint(equalToConstant: image.size.width).isActive = true
        icon.heightAnchor.constraint(equalToConstant: image.size.height).isActive = true
        ControlHelp.describe(icon, CodePaneView.reviewDetail(function))
        let name = ToolPanelPopover.title(function.name, width: inner - image.size.width - (size * 0.5).rounded())
        let title = NSStackView(views: [icon, name])
        title.orientation = .horizontal
        title.alignment = .centerY
        title.spacing = (size * 0.5).rounded()
        stack.addArrangedSubview(title)

        if let signature = signatureText {
            let line = NSTextField(wrappingLabelWithString: signature.string)
            line.attributedStringValue = signature
            line.preferredMaxLayoutWidth = inner
            stack.addArrangedSubview(line)
        }

        let said = descriptionText
        let words = ToolPanelPopover.prose(said ?? L("The review has not described this function yet."),
                                           said: said != nil)
        words.translatesAutoresizingMaskIntoConstraints = false
        // A long plate scrolls inside the popover, which stays on the screen.
        let height = ToolPanelPopover.tallestProse
        stack.addArrangedSubview(words.fittingSize.height > height
                                 ? CodeExplanationPopover.scrolling(words, width: inner, height: height) : words)

        let go = ToolPanelPopover.action(L("Go to Function"), target: self, action: #selector(goChosen))
        ControlHelp.describe(go, L("Go to Function"))
        stack.addArrangedSubview(go)

        view = ToolPanelPopover.content(stack)
    }

    /// Presses the button as the reader would, for a test.
    func pressGo() { goChosen() }

    @objc private func goChosen() {
        close()
        onGo()
    }
}
