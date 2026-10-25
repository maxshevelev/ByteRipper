import CodeAnalysis
import Foundation

/// What a fragment panel is, apart from the surface that draws it.
///
/// A panel is not just its pane. A code screen is a pane, its marks, and the
/// analysis that turns the pane into a function list with code. The extra
/// belongs to the panel, not to the dock that happens to hold it: a panel that
/// moves to a tab of its own — or to a tab in another window — must arrive as
/// the screen it was, not as a plain hex dump.
struct PanelContent {
    let pane: PaneViewModel
    let bookmarks: [Bookmark]
    let screen: Screen

    enum Screen {
        /// The part's bytes alone, as every ordinary part opens.
        case bytes
        /// The read-only code screen: the module's bytes and the analysis
        /// stored for them.
        case code(CodeScreen)
    }

    var code: CodeScreen? {
        if case .code(let code) = screen { return code }
        return nil
    }
}

/// The analysis and bytes a code screen is drawn from, and what the reader had
/// chosen in it. The bytes are the module as it was when the panel opened: a
/// snapshot, like the analysis. The choices travel with the panel so a screen
/// that moves container opens where it was left.
struct CodeScreen {
    let manifest: AnalysisManifest
    let artifact: CodeArtifact
    let bytes: Data
    var selectedFunction: Int?
    var selectedInstruction: Int?
    var showsC: Bool = false
}
