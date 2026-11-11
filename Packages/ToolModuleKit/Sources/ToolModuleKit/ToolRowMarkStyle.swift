import AppKit
import CodeAnalysis
import AppPalette
import Localization

/// How each mark is drawn (`Design/ROW_MARKS.md` §3, §4) — the one place the
/// symbol names and the palette meanings are chosen, read by the cells, the
/// row view and the legend alike.
public extension ToolRowMark {
    /// The SF Symbol an icon mark is drawn with; nil for the background and the
    /// rail, which are paint.
    var symbol: String? {
        switch self {
        case .protectedIBB, .protectedFirmware, .decompressed: return nil
        // The verdicts: outline shapes, so none of them is ever a problem's —
        // no exclamation mark, which is the problems' (ROW_MARKS.md §4).
        case .newest: return "checkmark.seal.fill"
        // Down: a newer revision is there to be brought down into the image.
        case .newerListed: return "arrow.down.circle"
        case .newerMaybe: return "questionmark.circle"
        case .error: return "exclamationmark.octagon.fill"
        case .caution: return "exclamationmark.circle.fill"
        // Half filled: the legend shows the middle of the three.
        case .codeAnalysis: return ToolRowMarks.CodeReadiness.partial.symbol
        case .compressed, .compressedUndecoded: return "zipper.page"
        case .holdsChecks: return "lock.shield"
        case .partlyProtected: return "shield.lefthalf.filled"
        case .encoded: return "lock"
        case .decoded: return "lock.open"
        }
    }

    var tint: NSColor {
        switch self {
        case .protectedIBB: return RowMarks.protectedIBB
        case .protectedFirmware: return RowMarks.protectedFirmware
        case .decompressed, .compressed: return RowMarks.decompressed
        case .newest: return SemanticColors.good
        // Both say "not confirmed newest", and differ in how sure of it we
        // are, not in what kind of thing it is: one colour.
        case .newerListed, .newerMaybe: return SemanticColors.caution
        case .error: return SemanticColors.bad
        case .caution: return SemanticColors.caution
        case .codeAnalysis: return RowMarks.codeReviewed
        case .compressedUndecoded, .holdsChecks, .partlyProtected,
             .encoded, .decoded:
            return .secondaryLabelColor
        }
    }
}

extension ToolRowMarks.Role {
    /// Drawn in the badge after the name rather than in the leading slots.
    var isCode: Bool { codeReadiness != nil }

    /// How far the module's review has got, for a code badge; nil for any other.
    var codeReadiness: ToolRowMarks.CodeReadiness? {
        switch self {
        case .codeAnalysis(let readiness), .codeAnalysisInside(let readiness): return readiness
        default: return nil
        }
    }

    var mark: ToolRowMark {
        switch self {
        case .codeAnalysis, .codeAnalysisInside: return .codeAnalysis
        case .compressed(_, let decoded): return decoded ? .compressed : .compressedUndecoded
        case .holdsChecks: return .holdsChecks
        case .partlyProtected: return .partlyProtected
        case .encoded(_, let decoded): return decoded ? .decoded : .encoded
        }
    }

    /// What the pointer reads on the badge.
    var toolTip: String {
        switch self {
        case .codeAnalysis(let readiness):
            switch readiness {
            case .mechanical: return L("Code analysis stored: Ghidra's analysis only, not reviewed. Open with Code opens it")
            case .partial: return L("Code analysis stored: the review is not finished. Open with Code opens it")
            case .complete: return L("Code analysis stored: every function reviewed and the module described. Open with Code opens it")
            }
        case .codeAnalysisInside(let readiness):
            switch readiness {
            case .mechanical: return L("A module inside has a stored code analysis, not reviewed; open the row to reach it")
            case .partial: return L("A module inside has a stored code analysis, its review not finished; open the row to reach it")
            case .complete: return L("A module inside has a fully reviewed code analysis; open the row to reach it")
            }
        case .compressed(let algorithm, let decoded):
            return decoded
                ? L("%1$@ compressed data that opens here", algorithm)
                : L("%1$@ compressed data that does not open here", algorithm)
        case .holdsChecks(let words): return words
        case .partlyProtected: return ToolRowMark.partlyProtected.meaning
        case .encoded(let words, _): return words
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

public extension ToolRowMarks.CodeReadiness {
    /// How far a module's review has got, as its manifest says it.
    init(_ progress: ReviewProgress) {
        switch progress {
        case .mechanical: self = .mechanical
        case .partial: self = .partial
        case .complete: self = .complete
        }
    }

    /// The SF Symbol drawn in the readiness colour at `pointSize`: the tree's
    /// badge and the Code panel's title wear the same circle.
    func image(pointSize: CGFloat) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: words)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// What the circle says, where the module is already open.
    var words: String {
        switch self {
        case .mechanical: return L("Ghidra's analysis only: the module is not reviewed")
        case .partial: return L("The review is not finished")
        case .complete: return L("Every function reviewed and the module described")
        }
    }
}
