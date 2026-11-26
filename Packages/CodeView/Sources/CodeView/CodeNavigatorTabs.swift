import AnalysisProfiles
import CodeAnalysis

/// The tabs of the Code panel's navigator switch, in the order the switch
/// draws them, worked out from the module's analysis profile.
///
/// The built-in tabs the profile shows come first, in the order they always
/// had — Functions, Strings, POST, Status, Interfaces, Search — and then a tab
/// for each record the profile adds a section for, in the record's `order`. A
/// module with no profile, and a UEFI module, get exactly the built-in six.
public enum CodeNavigatorTab: Equatable, Sendable {
    /// One of the reader's lists.
    case list(CodeReaderState.List)
    /// What the module installs, looks up and is notified of.
    case interfaces
    /// The search of every function.
    case search
    /// A section of records the profile declares: its id, the profile's
    /// English title (the fallback when the app has no words for the id) and
    /// its SF Symbol.
    case record(id: String, title: String, symbol: String)

    /// The built-in section of the profile the tab is, nil for a record's.
    var builtIn: AnalysisProfile.BuiltInSection? {
        switch self {
        case .list(.functions): .functions
        case .list(.strings): .strings
        case .list(.postCodes): .postCodes
        case .list(.statusCodes): .statusCodes
        case .interfaces: .interfaces
        case .search: .search
        case .record: nil
        }
    }

    /// The built-in tabs, in the switch's order.
    public static let builtInTabs: [CodeNavigatorTab] = [
        .list(.functions), .list(.strings), .list(.postCodes), .list(.statusCodes),
        .interfaces, .search
    ]

    /// The switch's tabs for a module of `profile`; nil is a module the
    /// profiles do not cover, read as today.
    public static func tabs(for profile: AnalysisProfile?) -> [CodeNavigatorTab] {
        guard let profile else { return builtInTabs }
        let shown = builtInTabs.filter { tab in tab.builtIn.map(profile.shows) ?? true }
        let added = profile.addedPanelRecords.compactMap { record -> CodeNavigatorTab? in
            guard let panel = record.panel else { return nil }
            return .record(id: record.id, title: record.title, symbol: panel.symbol)
        }
        // Search stays last, after the profile's own sections.
        let search = shown.filter { $0 == .search }
        return shown.filter { $0 != .search } + added + search
    }
}
