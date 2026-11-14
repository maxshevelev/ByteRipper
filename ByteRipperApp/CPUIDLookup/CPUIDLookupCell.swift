import Cocoa
import IntelCPUID
import ToolModuleKit

/// A cell of the lookup table: its text, with what the query found in it
/// marked.
///
/// The mark is a yellow wash with dark text, which reads on a plain row, an
/// alternate one and a selected one alike, in both appearances; the rest of
/// the text takes the row's colours, so it is drawn again when the row is
/// selected (`backgroundStyle`).
@MainActor
final class CPUIDLookupCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var text = ""
    private var query = ""
    private var suffix: String?
    private var monospaced = false
    private var bold = false
    private var muted = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        // One line, cut at its end: a long list of code names must not
        // wrap and be shown from its middle.
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.isScrollable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, query: String, monospaced: Bool = false, bold: Bool = false,
              muted: Bool = false, suffix: String? = nil) {
        self.text = text
        self.query = query
        self.monospaced = monospaced
        self.bold = bold
        self.muted = muted
        self.suffix = suffix
        label.toolTip = text.count > 24 ? text : nil
        draw()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { draw() }
    }

    static let markColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.94, green: 0.79, blue: 0.29, alpha: 1)
            : NSColor(srgbRed: 1.0, green: 0.90, blue: 0.54, alpha: 1)
    }

    private func draw() {
        let emphasized = backgroundStyle == .emphasized
        // The tool panels' size, which View ▸ Zoom moves; the monospaced
        // face a point under it, where its wider letters match the body.
        let size = monospaced ? ToolPanelFont.size - 1 : ToolPanelFont.size
        let font: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
            : .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let color: NSColor = emphasized ? .alternateSelectedControlTextColor
            : muted ? .secondaryLabelColor : .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
        for range in CPUIDLookup.highlights(in: text, query: query) {
            string.addAttributes([.backgroundColor: Self.markColor,
                                  .foregroundColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.10, alpha: 1)],
                                 range: NSRange(range, in: text))
        }
        if let suffix {
            string.append(NSAttributedString(string: suffix, attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor : .secondaryLabelColor
            ]))
        }
        label.attributedStringValue = string
    }
}
