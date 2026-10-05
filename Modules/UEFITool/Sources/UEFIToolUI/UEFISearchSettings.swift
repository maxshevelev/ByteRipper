import Foundation
import ToolModuleKit
import UEFITool

/// What the tree's search asks for, kept for the app rather than for a panel:
/// the same query in both panes, through a reparse and through a change of file.
/// A panel on screen is told when it moves, and shows the new one.
///
/// In the panel settings' defaults (`ToolPanelFont.defaults`) like the tree's
/// other choices, as codes and text — no word of the interface, so a change of
/// language leaves the query as it was.
@MainActor enum UEFISearchSettings {
    static let textKey = "UEFIStructure.Search.Text"
    static let typeKey = "UEFIStructure.Search.Type"
    static let subtypeKey = "UEFIStructure.Search.Subtype"
    static let isOpenKey = "UEFIStructure.Search.IsOpen"

    /// Posted when the query or whether the bar is open changed.
    static let didChange = Notification.Name("UEFIStructureSearchDidChange")

    private static var defaults: UserDefaults { ToolPanelFont.defaults }

    static var query: UEFITreeQuery {
        get {
            UEFITreeQuery(
                text: defaults.string(forKey: textKey) ?? "",
                type: code(forKey: typeKey),
                subtype: code(forKey: subtypeKey)
            )
        }
        set {
            guard newValue != query else { return }
            defaults.set(newValue.text, forKey: textKey)
            store(newValue.type, forKey: typeKey)
            store(newValue.subtype, forKey: subtypeKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Whether the bar is open: the reader opens it from the tree's header, and
    /// it stays as they left it.
    static var isOpen: Bool {
        get { defaults.bool(forKey: isOpenKey) }
        set {
            guard newValue != isOpen else { return }
            defaults.set(newValue, forKey: isOpenKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// A code is stored as a number, and "none" as no number at all.
    private static func code(forKey key: String) -> UInt8? {
        (defaults.object(forKey: key) as? Int).flatMap { UInt8(exactly: $0) }
    }

    private static func store(_ code: UInt8?, forKey key: String) {
        if let code { defaults.set(Int(code), forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
