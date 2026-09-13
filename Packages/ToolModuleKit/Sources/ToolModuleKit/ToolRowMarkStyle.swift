import AppKit
import AppPalette

/// How each mark is drawn (`Design/ROW_MARKS.md` §3, §4) — the one place the
/// symbol names and the palette meanings are chosen, read by the cells, the
/// row view and the legend alike.
public extension ToolRowMark {
    /// The SF Symbol an icon mark is drawn with; nil for the background and the
    /// rail, which are paint.
    var symbol: String? {
        switch self {
        case .protectedIBB, .protectedFirmware, .decompressed: return nil
        case .error: return "exclamationmark.octagon.fill"
        case .caution: return "exclamationmark.circle.fill"
        case .compressed, .compressedUndecoded: return "zipper.page"
        case .holdsChecks: return "lock.shield"
        case .partlyProtected: return "shield.lefthalf.filled"
        }
    }

    var tint: NSColor {
        switch self {
        case .protectedIBB: return RowMarks.protectedIBB
        case .protectedFirmware: return RowMarks.protectedFirmware
        case .decompressed, .compressed: return RowMarks.decompressed
        case .error: return SemanticColors.bad
        case .caution: return SemanticColors.caution
        case .compressedUndecoded, .holdsChecks, .partlyProtected: return .secondaryLabelColor
        }
    }
}

extension ToolRowMarks.Role {
    var mark: ToolRowMark {
        switch self {
        case .compressed(_, let decoded): return decoded ? .compressed : .compressedUndecoded
        case .holdsChecks: return .holdsChecks
        case .partlyProtected: return .partlyProtected
        }
    }

    /// What the pointer reads on the badge.
    var toolTip: String {
        switch self {
        case .compressed(let algorithm, let decoded):
            return decoded
                ? "\(algorithm) compressed data that opens here"
                : "\(algorithm) compressed data that does not open here"
        case .holdsChecks(let words): return words
        case .partlyProtected: return ToolRowMark.partlyProtected.meaning
        }
    }
}

extension ToolRowMarks.Protection {
    var mark: ToolRowMark {
        switch self {
        case .ibb: return .protectedIBB
        case .firmware: return .protectedFirmware
        }
    }
}
