import AppKit

/// A panel's table that knows whether the selection moving now is the
/// reader's click — which is a step in the window's navigation history
/// (`ToolHost.noteNavigationStep`) — or an arrow key, which is not.
///
/// The selection-changed notification says nothing about what changed it, and
/// `NSApp.currentEvent` is not the event a test hands `mouseDown(with:)`, so
/// the table says it of itself.
open class ToolPanelTableView: NSTableView {
    /// True while a mouse down is being handled, which is when a click moves
    /// the selection.
    public private(set) var isHandlingClick = false

    open override func mouseDown(with event: NSEvent) {
        handlingClick { super.mouseDown(with: event) }
    }

    /// Runs `body` as the handling of a click. What `mouseDown` does — and
    /// what a test does, since a test host's window is never key and a
    /// synthetic click there selects nothing.
    public func handlingClick(_ body: () -> Void) {
        isHandlingClick = true
        defer { isHandlingClick = false }
        body()
    }
}

/// `ToolPanelTableView` for a tree.
open class ToolPanelOutlineView: NSOutlineView {
    public private(set) var isHandlingClick = false

    open override func mouseDown(with event: NSEvent) {
        handlingClick { super.mouseDown(with: event) }
    }

    /// Runs `body` as the handling of a click. What `mouseDown` does — and
    /// what a test does, since a test host's window is never key and a
    /// synthetic click there selects nothing.
    public func handlingClick(_ body: () -> Void) {
        isHandlingClick = true
        defer { isHandlingClick = false }
        body()
    }
}
