import AppKit
import CodeAnalysis
import Localization
import ToolModuleKit

/// The C of a function against the same function in an earlier revision, as
/// GitHub shows a file's diff: the old line number, the new one, a mark and
/// the line — what only the old review had on red, what only this one has on
/// green, the lines both share as they are. The text is the panel's code
/// font at its zoom; nothing here is a link, and nothing is edited.
@MainActor final class CodeDiffView: NSView {
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")

    /// What the view shows now, for a test; nil while it shows a message.
    private(set) var shownDiff: LineDiff?
    /// How many lines the new text adds and the old one loses, for a test.
    var counts: (added: Int, removed: Int)? {
        shownDiff.map { ($0.added, $0.removed) }
    }

    init() {
        super.init(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.textContainerInset = NSSize(width: 8, height: 12)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        placeholder.font = ToolPanelFont.body()
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The diff to show, in the code's font and at the code's line pitch.
    func show(_ diff: LineDiff, font: NSFont, lineHeight: CGFloat, padding: CGFloat) {
        shownDiff = diff
        placeholder.isHidden = true
        scroll.isHidden = false
        let origin = scroll.contentView.bounds.origin
        let shown = NSMutableAttributedString()
        let oldWidth = max(1, String(diff.rows.reduce(0) { max($0, oldNumber($1) ?? 0) }).count)
        let newWidth = max(1, String(diff.rows.reduce(0) { max($0, newNumber($1) ?? 0) }).count)
        let blankOld = String(repeating: " ", count: oldWidth)
        let blankNew = String(repeating: " ", count: newWidth)
        func number(_ value: Int?, width: Int) -> String {
            let shown = value.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, width - shown.count)) + shown
        }
        for row in diff.rows {
            let line: String
            var mark: String
            switch row {
            case let .same(old, new, text):
                line = " \(number(old, width: oldWidth))  \(number(new, width: newWidth))   \(text)\n"
                mark = ""
            case let .removed(old, text):
                line = " \(number(old, width: oldWidth))  \(blankNew) - \(text)\n"
                mark = "-"
            case let .added(new, text):
                line = " \(blankOld)  \(number(new, width: newWidth)) + \(text)\n"
                mark = "+"
            }
            let start = shown.length
            shown.append(NSAttributedString(string: line, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor
            ]))
            let range = NSRange(location: start, length: line.utf16.count)
            // The numbers read quieter than the code under them.
            let gutter = 1 + oldWidth + 2 + newWidth
            shown.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                               range: NSRange(location: start, length: min(gutter, range.length)))
            switch row {
            case .same: break
            case .removed:
                shown.addAttribute(.backgroundColor, value: CodeColors.diffRemoved, range: range)
                if mark == "-" {
                    shown.addAttribute(.foregroundColor, value: CodeColors.diffRemovedMark,
                                       range: NSRange(location: start + gutter + 1, length: 1))
                }
            case .added:
                shown.addAttribute(.backgroundColor, value: CodeColors.diffAdded, range: range)
                if mark == "+" {
                    shown.addAttribute(.foregroundColor, value: CodeColors.diffAddedMark,
                                       range: NSRange(location: start + gutter + 1, length: 1))
                }
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        shown.addAttribute(.paragraphStyle, value: paragraph,
                           range: NSRange(location: 0, length: shown.length))
        shown.addAttribute(.baselineOffset, value: padding,
                           range: NSRange(location: 0, length: shown.length))
        text.textStorage?.setAttributedString(shown)
        if let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            text.sizeToFit()
        }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Says why there is nothing to compare, in the panel's grey.
    func showMessage(_ message: String) {
        shownDiff = nil
        text.textStorage?.setAttributedString(NSAttributedString(string: ""))
        placeholder.stringValue = message
        placeholder.isHidden = false
        scroll.isHidden = true
    }

    private func oldNumber(_ row: LineDiff.Row) -> Int? {
        switch row {
        case let .same(old, _, _), let .removed(old, _): old
        case .added: nil
        }
    }

    private func newNumber(_ row: LineDiff.Row) -> Int? {
        switch row {
        case let .same(_, new, _), let .added(new, _): new
        case .removed: nil
        }
    }

    /// Gives the diff the keyboard, as a click in it would.
    func focus() { window?.makeFirstResponder(text) }

    /// The diff's text as drawn, for a test.
    var shownText: String { text.string }
    var shownAttributedText: NSAttributedString {
        text.textStorage.map { NSAttributedString(attributedString: $0) } ?? NSAttributedString()
    }
    /// The background a row is drawn on, for a test: the colour of the first
    /// character of the row holding `line`.
    func background(ofLineContaining line: String) -> NSColor? {
        guard let storage = text.textStorage else { return nil }
        let range = (storage.string as NSString).range(of: line)
        guard range.location != NSNotFound, range.location < storage.length else { return nil }
        return storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }
    var placeholderText: String? { placeholder.isHidden ? nil : placeholder.stringValue }
    var scrollOrigin: NSPoint { scroll.contentView.bounds.origin }
    func scroll(to origin: NSPoint) {
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
