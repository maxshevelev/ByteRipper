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
        case .function, .pcode: function
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
    /// Xcode's function colour, kept in the palette: a module's readiness
    /// badge in the firmware panels wears it too.
    static let function = RowMarks.codeReviewed
    static let global = themed(light: 0x0F68A0, dark: 0x41A1C0)
    static let number = themed(light: 0x1C00CF, dark: 0xD0BF69)
    static let string = themed(light: 0xC41A16, dark: 0xFC6A5D)
    static let comment = themed(light: 0x5D6C79, dark: 0x6C7986)

    // A line a revision removed and one it added, as GitHub tints them: the
    // same two greens and reds on both appearances, only deeper in the dark.
    static let diffRemoved = themed(light: 0xFFEBE9, dark: 0x3B191C)
    static let diffAdded = themed(light: 0xE6FFEC, dark: 0x12311C)
    static let diffRemovedMark = themed(light: 0xB31D28, dark: 0xE98A93)
    static let diffAddedMark = themed(light: 0x22863A, dark: 0x6ACC7B)

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
                           links: inout [CodeLink], asTextLinks: Bool,
                           spacedCommas: Bool = false) -> NSAttributedString {
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
        if spacedCommas {
            // Ghidra's printer sets a comma hard against what follows it —
            // `f(a,b)`. A kern of a space's width sets it apart as a space
            // would, and the text keeps the offsets the artifact's spans are
            // measured in. A comma that already has a space after it, in a
            // comment's prose, keeps that one.
            let space = (" " as NSString).size(withAttributes: [.font: font]).width
            let commas = string.string as NSString
            var search = NSRange(location: 0, length: string.length)
            while search.length > 0 {
                let found = commas.range(of: ",", options: [], range: search)
                guard found.location != NSNotFound else { break }
                let next = found.location + found.length
                let spaced = next < string.length
                    && CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(commas.character(at: next)) ?? "x")
                if !spaced { string.addAttribute(.kern, value: space, range: found) }
                search = NSRange(location: next, length: string.length - next)
            }
        }
        return string
    }

    static let linkKey = NSAttributedString.Key("CodeViewLink")

    /// Behind every occurrence of the symbol the reader clicked: Xcode's own
    /// blue-grey (#EEF1F9 in Default (Light)), never the accent a selection
    /// wears, drawn as a rounded box around each name.
    static let symbolHighlight = themed(light: 0xEEF1F9, dark: 0x3A3E4A)

    /// The colour that, laid at `alpha` over `background`, reads as `target`.
    /// A highlight box is filled with it so that, one alpha everywhere, it
    /// looks like the panel's own box over plain code and adds its colour to
    /// a diff row's tint instead of replacing it.
    static func laidOver(_ background: NSColor, alpha: CGFloat, toReadAs target: NSColor) -> NSColor {
        guard alpha > 0, alpha < 1,
              let back = background.usingColorSpace(.sRGB),
              let want = target.usingColorSpace(.sRGB) else { return target }
        func solved(_ b: CGFloat, _ t: CGFloat) -> CGFloat {
            min(1, max(0, (t - (1 - alpha) * b) / alpha))
        }
        return NSColor(srgbRed: solved(back.redComponent, want.redComponent),
                       green: solved(back.greenComponent, want.greenComponent),
                       blue: solved(back.blueComponent, want.blueComponent),
                       alpha: 1)
    }
    static let symbolHighlightRadius: CGFloat = 3

    /// Behind the line the reader is on — the C line last clicked or moved
    /// to, the listing's selected instruction: Xcode's current-line colour
    /// (#E8F2FF in Default (Light), #23252B in Default (Dark)), the whole
    /// width of the code, under everything else drawn there.
    static let currentLine = themed(light: 0xE8F2FF, dark: 0x23252B)

    /// The plate over a function marked New — a yellow notice as macOS draws
    /// one: a pale amber ground, a hairline of a deeper amber, an amber sign.
    static let newMarkBannerBackground = themed(light: 0xFFF8DE, dark: 0x3A331A)
    static let newMarkBannerBorder = themed(light: 0xE9D6A1, dark: 0x5E5226)

    /// Behind code in the module's description: a block and a span.
    static let descriptionCodeBackground = themed(light: 0xF2F3F5, dark: 0x2C2D31)
    /// Behind the header row of a table in the description.
    static let descriptionTableHeader = themed(light: 0xF4F5F7, dark: 0x303136)
}
