import AppKit
import HelpBook
import LenovoDMI
import LenovoDMITool
import Localization
import ToolModuleKit

/// The identity store of Lenovo's InsydeH2O firmware, read: where it is, which
/// of its two blocks the firmware uses, and what the entries in each say —
/// decrypted, with the known ones by name.
///
/// What it is for: a serial number searched for in a Lenovo dump is not
/// found, because the store is XORed, and a technician carrying a board's
/// identity over from a donor has nothing to compare by eye. This panel is the
/// readable side of those bytes.
public enum LenovoDMIToolModule: ToolModule {
    // help: panel.lenovo-dmi
    public static let identifier = "dev.maxik.tool.lenovodmi"
    public static let title = L("Lenovo DMI")
    public static let helpTopic: HelpTopicID? = .toolLenovoDMI
    /// Two columns — a name and a value as long as a model name.
    public static let preferredPanelWidth: CGFloat = 420

    @MainActor public static func makeSession(host: any ToolHost) -> any ToolSession {
        LenovoDMIToolSession(host: host)
    }
}

/// What a parked session hands back: the row the user was on. The store is a
/// few kilobytes found in a few milliseconds, so the reading is done again.
struct LenovoDMIParkedState: ToolSessionState {
    var focus: String?
}

/// The running instrument: read the image off the main actor, show what came
/// back, publish the zones, and keep the outline where the user put it.
@MainActor public final class LenovoDMIToolSession: ToolSession {
    private let host: any ToolHost
    private let controller = LenovoDMIToolViewController()
    /// What the panel is showing. Readable from outside so the app's tests can
    /// assert on it without reaching into a view.
    public private(set) var display = LenovoDMIDisplay.empty
    /// Called on the main actor once a reading has landed and been shown.
    public var onDisplay: ((LenovoDMIDisplay) -> Void)?
    private var focus: String?
    /// Which reading is the current one: an edit during a read starts another,
    /// and only the newest may land.
    private var generation = 0

    /// Where a copy goes. Swappable so the app's tests do not walk off with
    /// whatever the person running them had on their clipboard.
    public static var pasteboard: NSPasteboard = .general

    public init(host: any ToolHost) {
        self.host = host
        controller.onSelect = { [weak self] id in self?.select(id) }
        controller.onGoTo = { [weak self] id in self?.goTo(id) }
        controller.onCopyValue = { [weak self] id in self?.copyValue(of: id) }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        controller.say(L("Reading…"))
        reparse()
    }

    /// Any change is a reason to read again: the area is 16 KiB, found by one
    /// scan of the image, and what the panel shows has to be what the file
    /// holds — after an edit in the dump as much as after a reload.
    public func contentChanged(_ change: ToolContentChange) {
        if change == .reloaded {
            focus = nil
        }
        reparse()
    }

    public func stop() {}

    public var parkedState: (any ToolSessionState)? { LenovoDMIParkedState(focus: focus) }

    public func restore(_ state: any ToolSessionState) {
        guard let state = state as? LenovoDMIParkedState else { return }
        focus = state.focus
    }

    /// The user picked one of our zones in the dump: bring its row forward.
    public func zoneSelected(_ id: Zone.ID) {
        select(id)
    }

    private func reparse() {
        generation += 1
        let generation = self.generation
        guard let snapshot = try? host.snapshot() else {
            show(.empty)
            controller.say(L("Could not read the file."), asProblem: true)
            return
        }
        Task { [weak self] in
            let display = await Task.detached(priority: .userInitiated) {
                let bytes = (try? snapshot.read(at: 0, length: Int(snapshot.size))) ?? []
                return LenovoDMIPresenter.display(LenovoDMI.locate(in: bytes))
            }.value
            guard let self, self.generation == generation else { return }
            // A row the new reading does not have is not one to hold on to.
            if let focus = self.focus, display.row(focus) == nil {
                self.focus = nil
            }
            self.show(display)
            self.controller.say("")
            self.onDisplay?(display)
        }
    }

    private func show(_ display: LenovoDMIDisplay) {
        self.display = display
        controller.show(display, focus: focus)
        host.publish(display.zones(focus: focus))
    }

    // MARK: - What the panel asks for

    /// Public because a click in a table cannot be simulated — `clickedRow` is
    /// -1 unless a real mouse put it there — so this is the level the app's
    /// tests drive.
    public func select(_ id: String?) {
        focus = id
        show(display)
    }

    /// The row's bytes, selected in the dump.
    public func goTo(_ id: String) {
        guard let row = display.row(id) else { return }
        select(id)
        host.reveal(row.range, select: true)
    }

    /// The value as the panel reads it — what a bench writes on a work order
    /// or pastes into a search.
    public func copyValue(of id: String) {
        guard let row = display.row(id), !row.value.isEmpty else { return }
        LenovoDMIToolSession.pasteboard.clearContents()
        LenovoDMIToolSession.pasteboard.setString(row.value, forType: .string)
        controller.say(L("Copied: %1$@", row.value))
    }
}
