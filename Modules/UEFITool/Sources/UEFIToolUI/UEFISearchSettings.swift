import Foundation
import ToolModuleKit
import UEFITool

/// The names the tree's search is kept under, and the shapes of what it asks
/// for. Kept as codes and text — no word of the interface, so a change of
/// language leaves the query as it was. What a panel holds is its
/// `UEFISearchState`.
@MainActor enum UEFISearchSettings {
    static let textKey = "UEFIStructure.Search.Text"
    static let typeKey = "UEFIStructure.Search.Type"
    static let subtypeKey = "UEFIStructure.Search.Subtype"
    static let isOpenKey = "UEFIStructure.Search.IsOpen"
    static let modeKey = "UEFIStructure.Search.Mode"
    static let contentTextKey = "UEFIStructure.Search.ContentText"
    static let contentFromSelectionKey = "UEFIStructure.Search.ContentFromSelection"

    /// Posted when a panel's query or whether its bar is open changed; the
    /// object is that panel's `UEFISearchState`.
    static let didChange = Notification.Name("UEFIStructureSearchDidChange")

    /// What the bar looks for: a node by what it is called, or a pattern in
    /// what the nodes hold.
    enum Mode: String {
        case names, contents
    }

    /// What the Contents search asks for: the text in its field — how it is
    /// read is the pattern controls' to say, as in the dump's Find bar — and
    /// whether in the whole tree or in the node selected when it starts.
    struct Content: Equatable {
        var text = ""
        var wholeTree = true
    }

}

/// One panel's search: whether its bar is open, what it asks for and where.
///
/// Every UEFI Structure panel — a window's, a part panel's — has its own, and
/// no panel follows another's; only the pattern goes from one to the next,
/// through the find pasteboard (`FindPasteboard`), as it does between Find
/// bars. A window's panel starts from what the last one left in the panel
/// settings' defaults (`ToolPanelFont.defaults`) and leaves its own there for
/// the next; a part panel starts shut and keeps what it changes to itself.
@MainActor final class UEFISearchState {
    /// A window's panel's search.
    static func forWindow() -> UEFISearchState {
        UEFISearchState(stored: true)
    }

    /// A part panel's search: shut, and starting from what was last asked
    /// for, so the reader does not type it again.
    static func forPart() -> UEFISearchState {
        let state = UEFISearchState(stored: false)
        state.memory[UEFISearchSettings.isOpenKey] = false
        return state
    }

    /// What this search holds now, read from the defaults when it was made.
    private var memory: [String: Any] = [:]
    /// Whether a change goes back to the defaults too, for the next window.
    let isStored: Bool

    private init(stored: Bool) {
        isStored = stored
        for key in Self.keys {
            if let value = ToolPanelFont.defaults.object(forKey: key) { memory[key] = value }
        }
    }

    private static let keys = [
        UEFISearchSettings.textKey, UEFISearchSettings.typeKey, UEFISearchSettings.subtypeKey,
        UEFISearchSettings.isOpenKey, UEFISearchSettings.modeKey, UEFISearchSettings.contentTextKey,
        UEFISearchSettings.contentFromSelectionKey
    ]

    var query: UEFITreeQuery {
        get {
            UEFITreeQuery(
                text: value(UEFISearchSettings.textKey) as? String ?? "",
                type: code(forKey: UEFISearchSettings.typeKey),
                subtype: code(forKey: UEFISearchSettings.subtypeKey)
            )
        }
        set {
            guard newValue != query else { return }
            set(newValue.text, UEFISearchSettings.textKey)
            store(newValue.type, forKey: UEFISearchSettings.typeKey)
            store(newValue.subtype, forKey: UEFISearchSettings.subtypeKey)
            changed()
        }
    }

    /// Whether the bar is open: the reader opens it from the tree's header, and
    /// it stays as they left it.
    var isOpen: Bool {
        get { value(UEFISearchSettings.isOpenKey) as? Bool ?? false }
        set {
            guard newValue != isOpen else { return }
            set(newValue, UEFISearchSettings.isOpenKey)
            changed()
        }
    }

    var mode: UEFISearchSettings.Mode {
        get { (value(UEFISearchSettings.modeKey) as? String).flatMap(UEFISearchSettings.Mode.init) ?? .names }
        set {
            guard newValue != mode else { return }
            set(newValue.rawValue, UEFISearchSettings.modeKey)
            changed()
        }
    }

    var content: UEFISearchSettings.Content {
        get {
            // Stored as "from the selection", so a bench that never touched
            // the box searches the whole tree.
            UEFISearchSettings.Content(
                text: value(UEFISearchSettings.contentTextKey) as? String ?? "",
                wholeTree: !(value(UEFISearchSettings.contentFromSelectionKey) as? Bool ?? false))
        }
        set {
            guard newValue != content else { return }
            set(newValue.text, UEFISearchSettings.contentTextKey)
            set(!newValue.wholeTree, UEFISearchSettings.contentFromSelectionKey)
            changed()
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: UEFISearchSettings.didChange, object: self)
    }

    private func value(_ key: String) -> Any? { memory[key] }

    private func set(_ value: Any?, _ key: String) {
        memory[key] = value
        guard isStored else { return }
        if let value {
            ToolPanelFont.defaults.set(value, forKey: key)
        } else {
            ToolPanelFont.defaults.removeObject(forKey: key)
        }
    }

    /// A code is stored as a number, and "none" as no number at all.
    private func code(forKey key: String) -> UInt8? {
        (value(key) as? Int).flatMap { UInt8(exactly: $0) }
    }

    private func store(_ code: UInt8?, forKey key: String) {
        set(code.map { Int($0) }, key)
    }
}
