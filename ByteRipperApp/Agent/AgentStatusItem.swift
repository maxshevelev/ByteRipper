import Cocoa
import Localization

/// The agent service's mark in the menu bar: there while the service is
/// switched on, filled while an agent is connected (`Design/AGENT_PLAN.md`).
///
/// In the menu bar rather than in a window, because the person talking to an
/// agent is typing in another app — a terminal, Claude Desktop — and
/// ByteRipper's windows are behind it. The menu bar is the one place they can
/// see, from there, that the app is listening and whether anything is
/// connected.
// help: menubar.agent
@MainActor
final class AgentStatusItem: NSObject {
    private let service: AgentService
    private let showWindow: () -> Void
    private let showSettings: () -> Void
    private var item: NSStatusItem?
    private var observer: NSObjectProtocol?

    init(service: AgentService, showWindow: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.service = service
        self.showWindow = showWindow
        self.showSettings = showSettings
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: AgentService.didChange, object: service, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func refresh() {
        guard service.isRunning else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        let connected = service.connectionCount > 0
        let symbol = connected ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted"
        let status = AgentSettingsViewController.statusText(of: service)
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L("ByteRipper agent service"))
        item.button?.toolTip = L("ByteRipper agent service") + " — " + status
        item.menu = menu(status: status)
    }

    private func menu(status: String) -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for (title, action) in [(L("Show Agent Window"), #selector(openWindow)),
                                (L("Agent Settings…"), #selector(openSettings)),
                                (L("Switch Off Agent Service"), #selector(switchOff))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        showSettings()
    }

    @objc private func switchOff() {
        service.isEnabled = false
    }

    /// Whether the mark is in the menu bar, for tests.
    var isShown: Bool { item != nil }
}
