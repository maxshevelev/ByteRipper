import Cocoa
import IntelCPUID
import Localization

/// Window ▸ Intel CPUID Lookup: the processor tables of
/// `github.com/maxshevelev/IntelCPUID`, searched by CPUID, model, S-SPEC,
/// code name or stepping — what the repository's lookup page does, at the
/// bench and without a browser.
///
/// The window reads the one copy of the tables the app holds
/// (`ProcessorTables.current`), filled by the one repository the FIT panel
/// reads too: opening either asks it to check for a newer table (at most once
/// a day), and a table that lands is shown by both. With no network the copy
/// kept from the last good read is searched.
///
/// It belongs to no document: one window, made the first time it is asked
/// for, closed and opened again like the Agent window.
// help: window.cpuid-lookup
@MainActor
final class CPUIDLookupWindowController: NSWindowController, NSWindowDelegate {
    let lookupController = CPUIDLookupViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        window.title = L("Intel CPUID Lookup")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 380)
        window.tabbingMode = .disallowed
        window.contentViewController = lookupController
        window.setContentSize(NSSize(width: 920, height: 640))
        window.center()
        window.setFrameAutosaveName("CPUIDLookupWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Brings the window up with the search field ready for typing, and asks
    /// the repository whether the table changed.
    func present(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        lookupController.focusSearch()
        lookupController.refreshTables()
    }

    func windowDidResignKey(_ notification: Notification) {
        lookupController.closeSuggestions()
    }

    func windowWillClose(_ notification: Notification) {
        lookupController.closeSuggestions()
        lookupController.rememberQuery()
    }
}
