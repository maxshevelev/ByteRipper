import Cocoa

/// Populates File ▸ Open Recent on display, and stands in as its delegate.
///
/// The menu bar is built once and shared by every window and tab, so the
/// submenu's rows cannot be built at that moment — the list keeps changing as
/// files open. AppKit asks the submenu's delegate to refresh it before each
/// display, and this is that refresh: one row per recent file, most recent
/// first, then **Clear Menu** while there is anything to clear.
///
/// A separate object rather than the app delegate itself, for the same reason
/// the menu bar's submenus are standalone factories: the populate logic can be
/// exercised in a test without a menu bar installed.
@MainActor
final class OpenRecentMenuController: NSObject, NSMenuDelegate {
    /// Rebuilds `menu`'s contents from `RecentFilesStore.recent`.
    ///
    /// A row carries its path in `representedObject` and no target, so the
    /// click travels the responder chain to the key window's
    /// `MainViewController` like every other File-menu command — the same
    /// convention the bar's other rows follow.
    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        for path in RecentFilesStore.recent {
            let item = NSMenuItem(
                title: (path as NSString).lastPathComponent,
                action: #selector(MainViewController.openRecentFile(_:)),
                keyEquivalent: "")
            item.representedObject = path
            // The name is what a row shows; the path is what it stands for,
            // and two names can collide.
            item.toolTip = path
            menu.addItem(item)
        }
        if !RecentFilesStore.recent.isEmpty {
            menu.addItem(
                withTitle: "Clear Menu",
                action: #selector(MainViewController.clearRecentFiles(_:)),
                keyEquivalent: ""
            )
        }
    }

    /// `NSMenuDelegate`: AppKit calls this on the main thread before the menu
    /// is shown, so what it builds is what the user sees.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }
}
