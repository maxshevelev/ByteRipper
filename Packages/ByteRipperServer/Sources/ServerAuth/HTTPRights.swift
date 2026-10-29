import Foundation
import HTTPService

/// The three kinds of token the console and `token add --preset` offer
/// (`Design/SERVER_HEADLESS_PLAN.md` §8): a reader of the store, an app that
/// also writes and publishes, and the operator.
public enum TokenPreset: String, CaseIterable, Sendable {
    case reader
    case app
    case admin

    public var rights: Set<HTTPRight> {
        switch self {
        case .reader:
            return [.casRead]
        case .app:
            return [.casRead, .casWrite, .ghidraUse]
        case .admin:
            return Set(HTTPRight.allCases)
        }
    }

    /// What `--rights` on the command line answers to, and the words the
    /// error message shows.
    public static var rightNames: String {
        HTTPRight.allCases.map(\.rawValue).joined(separator: ", ")
    }
}
