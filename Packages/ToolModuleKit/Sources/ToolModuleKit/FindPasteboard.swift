import AppKit

/// The system's find pasteboard (`NSPasteboard.Name.find`): the one search
/// string the Mac keeps for every app, and the one every search in ByteRipper
/// reads and writes — the dump's Find bar, and a tool-module's search such as
/// the UEFI tree's.
///
/// The convention it follows is the one every Mac app follows. **Use Selection
/// for Find** and a search that is run put their string here. A search field
/// that is opened, or a **Find Next** that is pressed, takes the string from
/// here when it has changed since that field last saw it — changed by another
/// field in the app, or by another app. A string that has not changed is left
/// alone, so a field keeps what the reader typed in it.
///
/// "Last saw" belongs to the field, not to this type: one field's search is
/// something every other field has not seen yet, and a single shared mark
/// would let the first field to look take it from all the rest.
@MainActor public enum FindPasteboard {
    /// The pasteboard itself. A seam for the tests, which must not write into
    /// the find string of the Mac they run on.
    public static var pasteboard = NSPasteboard(name: .find)

    /// How often the pasteboard has been written to — what a field remembers
    /// to tell a new string from one it has already seen.
    public static var changeCount: Int { pasteboard.changeCount }

    /// The search string, or nil for none.
    public static var string: String? {
        pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Puts `text` on the pasteboard and returns its change count, for the
    /// writer to remember as seen — its own string is not news to it. Leaves an
    /// empty string, and one that is already there, as they are.
    @discardableResult
    public static func write(_ text: String) -> Int {
        guard !text.isEmpty, text != string else { return changeCount }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return changeCount
    }

    /// The search string, if it has changed since `seen`; nil if it has not or
    /// there is none. Marks it seen either way.
    public static func take(ifChangedSince seen: inout Int) -> String? {
        let now = changeCount
        guard now != seen else { return nil }
        seen = now
        return string
    }
}
