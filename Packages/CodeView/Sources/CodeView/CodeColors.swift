import AppKit
import AppPalette
import CodeAnalysis
import ToolModuleKit

/// How a token kind is drawn: Xcode's own source editor theme — Default
/// (Light) and Default (Dark), switching with the appearance — with keywords
/// in bold, so the code reads the way a reader of C in Xcode expects.
///
/// The module's own functions and data take Xcode's *project* colours (its
/// function names, its globals); the types and the rest of the language its
/// *other* colours. Locals and parameters are plain text, as in Xcode.
enum CodeColors {
    static func color(for kind: CodeToken.Kind) -> NSColor {
        switch kind {
        case .keyword, .mnemonic: keyword
        case .type: type
        case .function: function
        case .global, .label: global
        case .constant: number
        case .string: string
        case .comment: comment
        case .parameter, .local: .labelColor
        case .address: .secondaryLabelColor
        case .bytes: .tertiaryLabelColor
        case .note: ZoneColors.agent
        case .personNote: ZoneColors.person
        }
    }

    /// Whether a kind is set in bold: the keywords, and an instruction's
    /// mnemonic, which is the listing's keyword.
    static func isBold(_ kind: CodeToken.Kind) -> Bool {
        kind == .keyword || kind == .mnemonic
    }

    // Xcode's Default (Light) and Default (Dark) source colours.
    static let keyword = themed(light: 0x9B2393, dark: 0xFC5FA3)
    static let type = themed(light: 0x3900A0, dark: 0xD0A8FF)
    static let function = themed(light: 0x326D74, dark: 0x67B7A4)
    static let global = themed(light: 0x0F68A0, dark: 0x41A1C0)
    static let number = themed(light: 0x1C00CF, dark: 0xD0BF69)
    static let string = themed(light: 0xC41A16, dark: 0xFC6A5D)
    static let comment = themed(light: 0x5D6C79, dark: 0x6C7986)

    private static func themed(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
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
        let bold = ToolPanelFont.monospaced(size: font.pointSize, bold: true)
        for token in tokens where token.start + token.length <= length {
            let range = NSRange(location: token.start, length: token.length)
            string.addAttribute(.foregroundColor, value: color(for: token.kind), range: range)
            if isBold(token.kind) { string.addAttribute(.font, value: bold, range: range) }
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

    /// Behind every occurrence of the symbol the reader clicked: Xcode's own
    /// blue-grey (#EEF1F9 in Default (Light)), never the accent a selection
    /// wears, drawn as a rounded box around each name.
    static let symbolHighlight = themed(light: 0xEEF1F9, dark: 0x3A3E4A)
    static let symbolHighlightRadius: CGFloat = 3

    /// Behind code in the module's description: a block and a span.
    static let descriptionCodeBackground = themed(light: 0xF2F3F5, dark: 0x2C2D31)
    /// Behind the header row of a table in the description.
    static let descriptionTableHeader = themed(light: 0xF4F5F7, dark: 0x303136)
}
