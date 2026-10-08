import Cocoa
import ByteRipperCore

/// The open documents as the agent service sees them: which there are, what
/// each is called to an agent, and which one the reader is in
/// (`Design/AGENT_PLAN.md`, "The host's own tools").
///
/// Asked, never stored: every answer is read from the windows at the moment of
/// the question, the way `OpenDocumentRegistry` answers, so a file closed a
/// second ago cannot be described as open. The one thing kept is the short id
/// each document is given the first time an agent sees it — held weakly
/// against the document, so it goes when the document does, and a file opened
/// into the same pane later is a new document with a new id.
@MainActor
final class AgentDesk {
    /// Every tab's controller, frontmost first.
    private let controllers: () -> [MainViewController]
    /// The tab the reader is in.
    private let keyController: () -> MainViewController?

    private let ids = NSMapTable<BinaryDocument, NSString>.weakToStrongObjects()
    private var nextID = 1

    init(controllers: @escaping () -> [MainViewController],
         keyController: @escaping () -> MainViewController?) {
        self.controllers = controllers
        self.keyController = keyController
    }

    /// One open document: the pane it is in and the tab that holds the pane.
    struct Place {
        let id: String
        let pane: PaneViewModel
        let controller: MainViewController
        /// "A" or "B" for one of the tab's own panes, "part" for a fragment
        /// panel.
        let slot: String
    }

    // MARK: - Ids

    /// The document's id, minted the first time it is asked for: `d1`, `d2`…
    /// Short, because a model writes it back on every call.
    func id(of document: BinaryDocument) -> String {
        if let id = ids.object(forKey: document) { return id as String }
        let id = "d\(nextID)"
        nextID += 1
        ids.setObject(id as NSString, forKey: document)
        return id
    }

    // MARK: - What is open

    /// Every open document in every tab, the tab the reader is in first.
    func places() -> [Place] {
        var result: [Place] = []
        var seen = Set<ObjectIdentifier>()
        var ordered = controllers()
        if let key = keyController(), let index = ordered.firstIndex(where: { $0 === key }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        for controller in ordered where seen.insert(ObjectIdentifier(controller)).inserted {
            let model = controller.windowModel
            for (pane, slot) in [(model.pane1, "A"), (model.pane2, "B")] {
                if let document = pane.document {
                    result.append(Place(id: id(of: document), pane: pane, controller: controller, slot: slot))
                }
            }
            for panel in controller.fragments.dock.panels {
                if let pane = controller.fragments.pane(panel), let document = pane.document {
                    result.append(Place(id: id(of: document), pane: pane, controller: controller, slot: "part"))
                }
            }
        }
        return result
    }

    /// The document the reader is in: the active pane of the frontmost tab —
    /// a fragment panel when one is up, as every command aimed at "the
    /// active pane" takes it.
    func focused() -> Place? {
        guard let controller = keyController() ?? controllers().first else { return nil }
        let pane = controller.activePane
        guard let document = pane.document else { return nil }
        return places().first { $0.pane === pane && $0.pane.document === document }
    }

    /// The document an agent named, or the focused one when it named none.
    func place(named id: String?) throws -> Place {
        if let id {
            guard let place = places().first(where: { $0.id == id }) else {
                throw AgentDeskError.noSuchDocument(id)
            }
            return place
        }
        guard let place = focused() else { throw AgentDeskError.nothingOpen }
        return place
    }

    // MARK: - Moving the view

    /// Brings the tab holding `place` to the front of its window, and raises
    /// its fragment panel when it is in one — without taking the keyboard
    /// from whatever app the person is typing in. The agent shows; it does
    /// not grab.
    func bringForward(_ place: Place) {
        if let window = place.controller.view.window {
            if let group = window.tabGroup, group.selectedWindow !== window {
                group.selectedWindow = window
            }
            window.orderFront(nil)
        }
        if place.slot == "part", let panel = place.controller.fragments.panel(holding: place.pane),
           place.controller.fragments.expanded != panel {
            place.controller.fragments.expand(panel, animated: false)
        }
    }
}

/// Why a document could not be found, worded for the model reading it.
enum AgentDeskError: Error, CustomStringConvertible {
    case noSuchDocument(String)
    case nothingOpen

    var description: String {
        switch self {
        case .noSuchDocument(let id):
            return "No open document has the id \(id). Call `documents` for the ones that are open."
        case .nothingOpen:
            return "No file is open in ByteRipper."
        }
    }
}
