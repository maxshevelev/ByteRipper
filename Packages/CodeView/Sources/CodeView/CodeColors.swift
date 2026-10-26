import AppKit
import AppPalette
import CodeAnalysis

/// The colours a token kind is drawn in. System colours, so light and dark
/// appearance and the accessibility contrast settings come with them.
enum CodeColors {
    static func color(for kind: CodeToken.Kind) -> NSColor {
        switch kind {
        case .keyword, .mnemonic: .systemPink
        case .type: .systemPurple
        case .function: .linkColor
        case .global: .systemTeal
        case .label: .systemTeal
        case .constant: .systemOrange
        case .string: .systemRed
        case .comment: .systemGreen
        case .parameter: .systemBrown
        case .local: .labelColor
        case .address: .secondaryLabelColor
        case .bytes: .tertiaryLabelColor
        case .note: ZoneColors.agent
        case .personNote: ZoneColors.person
        }
    }

    /// `text` with its tokens coloured. A token with a link carries it under
    /// `linkKey` as its index in `links`, and — in a text view — as `.link`,
    /// which is what makes the text view report a click on it.
    static func attributed(_ text: String, tokens: [CodeToken], font: NSFont,
                           links: inout [CodeLink], asTextLinks: Bool) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor
        ])
        let length = string.length
        for token in tokens where token.start + token.length <= length {
            let range = NSRange(location: token.start, length: token.length)
            string.addAttribute(.foregroundColor, value: color(for: token.kind), range: range)
            guard let link = token.link else { continue }
            string.addAttribute(linkKey, value: links.count, range: range)
            if asTextLinks {
                string.addAttribute(.link, value: "code:\(links.count)", range: range)
            }
            links.append(link)
        }
        return string
    }

    static let linkKey = NSAttributedString.Key("CodeViewLink")
}
