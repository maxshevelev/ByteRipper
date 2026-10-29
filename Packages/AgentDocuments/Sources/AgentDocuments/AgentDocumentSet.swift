import AgentKit
import ToolModuleKit

/// One open document as a tool reaches it: what an agent names it by, what
/// the person calls it, and a host that reads its bytes.
///
/// The app's is a pane; the server's is a snapshot of a file. A tool here
/// sees only this, so it answers the same about either.
public protocol AgentDocument {
    /// The id an agent names it by: `d1`. Short, because a model writes it
    /// back on every call.
    var id: String { get }
    /// What to call it to the person: the file's name, told apart from
    /// another of the same name. Ids are for tools.
    var label: String { get }
    /// `changed` or `gone` when the file on disk is no longer the one read
    /// (`Design/SERVER_HEADLESS_PLAN.md` decision 9); nil when it is, or when
    /// the host does not say — the app's documents are its panes.
    var disk: String? { get }
    /// A host that reads and nothing else: no session behind it, so a query
    /// draws no zones and puts up no sheets on a panel that is not there.
    @MainActor func readHost() -> any ToolReadHost
}

public extension AgentDocument {
    var disk: String? { nil }

    /// The label with the id, for a sentence the agent reads: it names the
    /// document to the person by the first and to a tool by the second.
    var named: String { label.isEmpty || label == id ? id : "\(label) (\(id))" }
}

/// The documents a host has open, and which one a call means.
@MainActor
public protocol AgentDocumentSet: AnyObject, Sendable {
    /// Every open document, in the order an agent is shown them.
    func documents() -> [any AgentDocument]

    /// The document `document` names, or the one a call may leave unnamed.
    /// Throws an `AgentToolError` worded for the model. The app takes the
    /// one the person is looking at; a host with no screen takes
    /// `AgentDocumentRule`.
    func resolve(_ document: String?) throws -> any AgentDocument
}

/// Which document a call means on a host with no screen and so no focus.
public enum AgentDocumentRule {
    /// An id names its document. Without one, a single open document is
    /// implied; with several the call has to say which, and the refusal lists
    /// them; with none open the host says why in its own words.
    public static func resolve(_ id: String?, in documents: [any AgentDocument],
                               noneOpen: String) throws -> any AgentDocument {
        if let id {
            guard let document = documents.first(where: { $0.id == id }) else {
                throw AgentToolError(unknown(id))
            }
            return document
        }
        switch documents.count {
        case 0:
            throw AgentToolError(noneOpen)
        case 1:
            return documents[0]
        default:
            let list = documents.map(\.named).joined(separator: ", ")
            throw AgentToolError("Several documents are open: \(list). Name one with `document`.")
        }
    }

    /// The refusal of an id no open document has.
    public static func unknown(_ id: String) -> String {
        "No open document has the id \(id). Call `documents` for the ones that are open."
    }
}
