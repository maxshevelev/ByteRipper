import Cocoa
import AgentKit
import AppPalette
import HelpBook
import HelpUI
import Localization

/// What an agent's client is configured with to reach this copy of the app
/// (`Design/AGENT_PLAN.md`, "The relay"): the relay inside the bundle, by its
/// real path, so a copy of the app moved to another folder hands out its own.
///
/// Every client is told the same three things — a name, the stdio transport,
/// the relay's path — and each wants them in its own form: a command, a JSON
/// block for a file, or fields in a settings screen.
enum AgentClientConfiguration {
    /// The name the server is registered under in every client.
    static let serverName = "byteripper"

    static var relayPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/byteripper-mcp").path
    }

    enum Client: CaseIterable {
        case claudeCode
        case claudeDesktop
        case cursor
        /// Any other MCP client: the parameters as a list, for a settings
        /// screen that asks for them one by one.
        case other

        /// The name in the client menu. Product names, except the last.
        var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .claudeDesktop: return "Claude Desktop"
            case .cursor: return "Cursor"
            case .other: return L("Other Client")
            }
        }

        /// Where the text goes, said above the preview.
        var destination: String {
            switch self {
            case .claudeCode:
                return L("Run this command once in Terminal. It adds ByteRipper to Claude Code for every folder.")
            case .claudeDesktop:
                return L("Add this to Claude Desktop's configuration file, %1$@, and restart Claude Desktop.",
                         "~/Library/Application Support/Claude/claude_desktop_config.json")
            case .cursor:
                return L("Add this to Cursor's configuration file, %1$@, for every project — or to %2$@ in one project.",
                         "~/.cursor/mcp.json", ".cursor/mcp.json")
            case .other:
                return L("Enter these parameters in the client's MCP server settings.")
            }
        }
    }

    /// The text for `client`, naming `relay`.
    static func text(for client: Client, relay: String = relayPath) -> String {
        switch client {
        case .claudeCode:
            // User scope: a technician talks to the app from whatever folder
            // they are in.
            return "claude mcp add --scope user \(serverName) -- " + quoted(relay)
        case .claudeDesktop, .cursor:
            // The two read the same block. A file that already lists servers
            // takes the inner entry beside them.
            let value: JSONValue = .object(["mcpServers": .object([serverName: ["command": .string(relay)]])])
            return value.prettyText
        case .other:
            let rows: [(String, String)] = [
                (L("Name"), serverName),
                (L("Transport"), "stdio"),
                (L("Command"), relay),
                (L("Arguments"), L("none")),
                (L("Environment"), L("none"))
            ]
            let width = rows.map(\.0.count).max() ?? 0
            return rows.map { $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }
                .joined(separator: "\n")
        }
    }

    /// A path quoted for the shell: `/Applications/ByteRipper.app` has no
    /// space, but a copy in "My Tools" does.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The Agent tab of the Settings window: the switch that opens the agent
/// socket, what it does, whether it is running, and what each kind of client
/// is configured with — shown in full before it is copied, so the person sees
/// the form the text is in and where it goes.
final class AgentSettingsViewController: NSViewController {
    /// The service the tab switches. The app's own unless a test hands it
    /// another.
    var service: AgentService? = AgentService.shared {
        didSet { refresh() }
    }

    private let enableCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let editsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let clientMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let destinationLabel = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView()
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private var observer: NSObjectProtocol?

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: L("Agent"))
        titleLabel.font = .boldSystemFont(ofSize: 15)

        enableCheckbox.title = L("Let agents connect to ByteRipper")
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enableChanged(_:))

        let caption = NSTextField(wrappingLabelWithString:
            L("An agent — Claude Code, Claude Desktop or another MCP client on this Mac — can then list the files open here, read their bytes and show places in them. It cannot save a file. The connection is local, but what the agent reads, its program passes to the model behind it."))

        // help: settings.agent.edits
        editsCheckbox.title = L("Let agents edit open files")
        editsCheckbox.target = self
        editsCheckbox.action = #selector(editsChanged(_:))
        let editsCaption = NSTextField(wrappingLabelWithString:
            L("An agent's edit goes into the open file as one step of its undo and shows red until the file is saved, like an edit made by hand. Saving stays with you. A file opened read-only is never changed."))
        editsCaption.font = .systemFont(ofSize: 11)
        editsCaption.textColor = .secondaryLabelColor
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let clientLabel = NSTextField(labelWithString: L("Configuration for:"))
        clientMenu.addItems(withTitles: AgentClientConfiguration.Client.allCases.map(\.title))
        clientMenu.target = self
        clientMenu.action = #selector(clientChanged)
        ControlHelp.describe(clientMenu, L("The program the agent runs in, whose configuration is shown below"))

        destinationLabel.font = .systemFont(ofSize: 11)
        destinationLabel.textColor = .secondaryLabelColor

        // Read-only and selectable: the text is to be looked at and copied,
        // and a person who wants only part of it can select that part.
        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.textContainerInset = NSSize(width: 6, height: 6)
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = false
        preview.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                      height: CGFloat.greatestFiniteMagnitude)
        preview.setAccessibilityLabel(L("Configuration text"))
        let previewScroll = NSScrollView()
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.borderType = .bezelBorder

        copyButton.title = L("Copy")
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyConfiguration)
        ControlHelp.describe(copyButton, L("Copy the text above to the clipboard"))

        let help = HelpButton.standard(for: .topic(.agent))

        for subview in [titleLabel, enableCheckbox, caption, statusLabel, editsCheckbox, editsCaption,
                        clientLabel, clientMenu,
                        destinationLabel, previewScroll, copyButton, help] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            help.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            enableCheckbox.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            enableCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            caption.topAnchor.constraint(equalTo: enableCheckbox.bottomAnchor, constant: 8),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 38),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            clientLabel.firstBaselineAnchor.constraint(equalTo: clientMenu.firstBaselineAnchor),
            clientLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            editsCheckbox.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            editsCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            editsCaption.topAnchor.constraint(equalTo: editsCheckbox.bottomAnchor, constant: 8),
            editsCaption.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            editsCaption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            clientMenu.topAnchor.constraint(equalTo: editsCaption.bottomAnchor, constant: 20),
            clientMenu.leadingAnchor.constraint(equalTo: clientLabel.trailingAnchor, constant: 8),

            destinationLabel.topAnchor.constraint(equalTo: clientMenu.bottomAnchor, constant: 8),
            destinationLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            destinationLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            previewScroll.topAnchor.constraint(equalTo: destinationLabel.bottomAnchor, constant: 8),
            previewScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            previewScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            previewScroll.heightAnchor.constraint(equalToConstant: 104),

            copyButton.topAnchor.constraint(equalTo: previewScroll.bottomAnchor, constant: 10),
            copyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            SettingsMetrics.pinnedWidth(of: root),
        ])
        view = root
        observer = NotificationCenter.default.addObserver(
            forName: AgentService.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        showClient()
        refresh()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    /// Reads the switch and the socket's state into the tab.
    func refresh() {
        guard isViewLoaded else { return }
        enableCheckbox.state = service?.isEnabled == true ? .on : .off
        enableCheckbox.isEnabled = service != nil
        editsCheckbox.state = service?.editsAllowed == true ? .on : .off
        editsCheckbox.isEnabled = service != nil
        statusLabel.stringValue = Self.statusText(of: service)
        statusLabel.textColor = service?.failure == nil ? .secondaryLabelColor : SemanticColors.bad
    }

    /// One line on what the service is doing — the same words the Agent
    /// window and the menu bar use.
    static func statusText(of service: AgentService?) -> String {
        guard let service else { return L("The agent service is not available in this copy of the app.") }
        if let failure = service.failure { return L("Could not start: %1$@", failure) }
        guard service.isRunning else { return L("Switched off.") }
        switch service.connectionCount {
        case 0: return L("Waiting for an agent.")
        case 1: return L("One agent connected.")
        default: return L("Agents connected: %1$@.", service.connectionCount)
        }
    }

    // MARK: - The client's configuration

    private var client: AgentClientConfiguration.Client {
        let all = AgentClientConfiguration.Client.allCases
        let index = clientMenu.indexOfSelectedItem
        return all.indices.contains(index) ? all[index] : .claudeCode
    }

    private func showClient() {
        destinationLabel.stringValue = client.destination
        preview.string = AgentClientConfiguration.text(for: client)
    }

    @objc private func clientChanged() {
        showClient()
    }

    @objc private func copyConfiguration() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentClientConfiguration.text(for: client), forType: .string)
        statusLabel.stringValue = L("Copied.")
    }

    @objc private func editsChanged(_ sender: NSButton) {
        service?.editsAllowed = sender.state == .on
        refresh()
    }

    @objc private func enableChanged(_ sender: NSButton) {
        service?.isEnabled = sender.state == .on
        refresh()
    }

    // MARK: - For tests

    /// The switch's state.
    var isEnabledShown: Bool { enableCheckbox.state == .on }

    /// Clicks the switch.
    func toggleForTesting() {
        enableCheckbox.performClick(nil)
    }

    /// The edit switch's state, and a click on it.
    var editsAllowedShown: Bool { editsCheckbox.state == .on }

    func toggleEditsForTesting() {
        editsCheckbox.performClick(nil)
    }

    /// Picks `client` in the menu, as a click would.
    func choose(_ client: AgentClientConfiguration.Client) {
        clientMenu.selectItem(at: AgentClientConfiguration.Client.allCases.firstIndex(of: client) ?? 0)
        clientChanged()
    }

    /// What the preview shows, and the line above it.
    var previewText: String { preview.string }
    var destinationText: String { destinationLabel.stringValue }
}
