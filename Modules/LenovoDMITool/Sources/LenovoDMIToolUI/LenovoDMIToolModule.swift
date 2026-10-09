import AppKit
import HelpBook
import LenovoDMI
import LenovoDMITool
import Localization
import ToolModuleKit

/// The identity store of Lenovo's InsydeH2O firmware, read: where it is, which
/// of its two blocks the firmware uses, and what the entries in each say —
/// decoded, with the known ones by name.
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
    /// Called once the drivers that ask for each entry have been named — the
    /// pass that runs behind the store.
    public var onReadersNamed: (() -> Void)?
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
        controller.onOpenDecoded = { [weak self] id in self?.openDecodedBlock(from: id) }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        reparse()
    }

    /// Any change is a reason to read again: the area is 16 KiB, found by one
    /// scan of the image, and what the panel shows has to be what the file
    /// holds — after an edit in the dump as much as after a reload.
    ///
    /// A reload is another file, or this one replaced: the tree, the row
    /// picked in it and the outline in the dump describe what is gone, so the
    /// panel lets go of them at once — as the ME Analyzer does — rather than
    /// showing the old file's serial number over the new file's bytes until
    /// the reading lands. An edit keeps them: it is the same file.
    public func contentChanged(_ change: ToolContentChange) {
        if change == .reloaded {
            focus = nil
            show(.empty)
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
            controller.endBusy()
            controller.say(L("Could not read the file."), asProblem: true)
            return
        }
        controller.say(L("Reading…"))
        controller.showBusy()
        Task { [weak self] in
            let (reading, display) = await Task.detached(priority: .userInitiated) {
                let bytes = (try? snapshot.read(at: 0, length: Int(snapshot.size))) ?? []
                let reading = LenovoDMI.read(bytes)
                return (reading, LenovoDMIPresenter.display(reading))
            }.value
            guard let self, self.generation == generation else { return }
            // A row the new reading does not have is not one to hold on to.
            if let focus = self.focus, display.row(focus) == nil {
                self.focus = nil
            }
            self.show(display)
            self.controller.endBusy()
            self.controller.say("")
            self.onDisplay?(display)
            self.nameReaders(of: reading, in: snapshot, generation: generation)
        }
    }

    /// Searches the image's drivers for the entries they ask for and shows
    /// the store again with them named — behind the store rather than in
    /// front of it: it parses the whole image, compressed volumes included,
    /// and the store is worth reading before that is done.
    ///
    /// Only for a store in a firmware image: a block on its own — a fragment —
    /// has no drivers around it, and "no driver names it" would be a claim
    /// about firmware that is not there.
    private func nameReaders(of reading: LenovoDMIReading, in snapshot: any ToolContentReader,
                             generation: Int) {
        guard !reading.areas.isEmpty else { return }
        let namespaces = Array(Set(reading.areas.flatMap { $0.blocks.flatMap { $0.entries.map(\.key.namespace) } }))
        Task { [weak self] in
            let display = await Task.detached(priority: .utility) {
                let bytes = (try? snapshot.read(at: 0, length: Int(snapshot.size))) ?? []
                let readers = LenovoDMIFirmwareReaders.scan(bytes, namespaces: namespaces)
                return LenovoDMIPresenter.display(reading, readers: readers)
            }.value
            guard let self, self.generation == generation else { return }
            self.show(display)
            self.onReadersNamed?()
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

    /// The block a row belongs to, decoded, in a fragment panel over the
    /// dump: the serial number reads as text there and can be typed over.
    /// Update in Parent puts it back through the same codec — encoded again
    /// with the key in its header, its checksum recomputed — and the codec
    /// travels with the panel, so that works after this session has ended.
    public func openDecodedBlock(from id: String) {
        guard let part = display.decodedPart(from: id) else { return }
        host.openPart(named: part.name, linkedTo: part.source, codec: part.codec)
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
