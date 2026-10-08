import Cocoa
import AgentKit
import HelpBook
import HelpUI
import Localization

/// What an agent's client is configured with to reach this copy of the app
/// (`Design/AGENT_PLAN.md`, "The relay"): the relay inside the bundle, by its
/// real path, so a copy of the app moved to another folder hands out its own.
enum AgentClientConfiguration {
    static var relayPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/byteripper-mcp").path
    }

    /// The Terminal command that adds the server to Claude Code for every
    /// project of this user — a technician talks to the app from whatever
    /// folder they are in.
    static func claudeCodeCommand(relay: String = relayPath) -> String {
        "claude mcp add --scope user byteripper -- " + quoted(relay)
    }

    /// The block for Claude Desktop's `claude_desktop_config.json`.
    static func claudeDesktopConfiguration(relay: String = relayPath) -> String {
        let value: JSONValue = ["mcpServers": ["byteripper": ["command": .string(relay)]]]
        return value.jsonText
    }

    /// A path quoted for the shell: `/Applications/ByteRipper.app` has no
    /// space, but a copy in "My Tools" does.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The Agent tab of the Settings window: the switch that opens the agent
/// socket, what it does, whether it is running, and the two configurations a
/// client needs.
final class AgentSettingsViewController: NSViewController {
    /// The service the tab switches. The app's own unless a test hands it
    /// another.
    var service: AgentService? = AgentService.shared {
        didSet { refresh() }
    }

    private let enableCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyCodeButton = NSButton(title: "", target: nil, action: nil)
    private let copyDesktopButton = NSButton(title: "", target: nil, action: nil)
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
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingMiddle

        copyCodeButton.title = L("Copy Command for Claude Code")
        copyCodeButton.bezelStyle = .rounded
        copyCodeButton.target = self
        copyCodeButton.action = #selector(copyClaudeCode)
        ControlHelp.describe(copyCodeButton, L("Copy the Terminal command that connects Claude Code to this copy of ByteRipper"))

        copyDesktopButton.title = L("Copy Configuration for Claude Desktop")
        copyDesktopButton.bezelStyle = .rounded
        copyDesktopButton.target = self
        copyDesktopButton.action = #selector(copyClaudeDesktop)
        ControlHelp.describe(copyDesktopButton, L("Copy the block that goes into Claude Desktop's configuration file"))

        let buttons = NSStackView(views: [copyCodeButton, copyDesktopButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let help = HelpButton.standard(for: .topic(.agent))

        for subview in [titleLabel, enableCheckbox, caption, statusLabel, buttons, help] {
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

            buttons.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            SettingsMetrics.pinnedWidth(of: root),
        ])
        view = root
        observer = NotificationCenter.default.addObserver(
            forName: AgentService.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
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
        statusLabel.stringValue = Self.statusText(of: service)
        statusLabel.textColor = service?.failure == nil ? .secondaryLabelColor : .systemRed
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

    // MARK: - Actions

    /// The switch's state, for tests.
    var isEnabledShown: Bool { enableCheckbox.state == .on }

    @objc private func enableChanged(_ sender: NSButton) {
        service?.isEnabled = sender.state == .on
        refresh()
    }

    @objc private func copyClaudeCode() {
        copy(AgentClientConfiguration.claudeCodeCommand())
    }

    @objc private func copyClaudeDesktop() {
        copy(AgentClientConfiguration.claudeDesktopConfiguration())
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = L("Copied.")
    }

    /// Clicks the switch, for tests.
    func toggleForTesting() {
        enableCheckbox.performClick(nil)
    }
}
