import Cocoa
import AppPalette
import CodeAnalysis
import HelpBook
import HelpUI
import Localization

/// The Code Analysis tab of the Settings window: where the code analyses are
/// kept — on this Mac, or on an analysis server in the person's network — the
/// server's address and token, whether it is reached, and sending this Mac's
/// analyses to it (`Design/SERVER_PLAN.md` §5).
final class CodeAnalysisSettingsViewController: NSViewController {
    /// The location the tab sets. The app's own unless a test hands it
    /// another.
    var location: CodeAnalysisLocation = .shared {
        didSet { refresh() }
    }

    private let thisMacButton = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let serverButton = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let addressField = NSTextField()
    private let tokenField = NSSecureTextField()
    private let connectButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "", target: nil, action: nil)
    private let sendStatus = NSTextField(wrappingLabelWithString: "")
    private var observer: NSObjectProtocol?

    override func loadView() {
        let root = NSView()

        // help: settings.code-analysis
        let keptLabel = NSTextField(labelWithString: L("Code analyses are kept:"))
        thisMacButton.title = L("On this Mac")
        thisMacButton.target = self
        thisMacButton.action = #selector(modeChanged(_:))
        serverButton.title = L("On an analysis server")
        serverButton.target = self
        serverButton.action = #selector(modeChanged(_:))
        let caption = small(L("On this Mac, the analyses the Ghidra skill makes are read from this Mac's own folder. On an analysis server — byteripper-server on a machine in your network — every Mac that names the server reads the same analyses, and a module analysed once is there for all of them. What this Mac has read stays readable when the server cannot be reached."))

        // help: settings.code-analysis.server
        let addressLabel = NSTextField(labelWithString: L("Server:"))
        addressField.placeholderString = "http://100.64.0.7:8765"
        ControlHelp.describe(addressField, L("The analysis server's address, as http://host:port"))
        let tokenLabel = NSTextField(labelWithString: L("Token:"))
        ControlHelp.describe(tokenField, L("The token made on the server by byteripper-server token add"))
        connectButton.title = L("Connect")
        connectButton.bezelStyle = .rounded
        connectButton.target = self
        connectButton.action = #selector(connect)
        ControlHelp.describe(connectButton, L("Keep the analyses on this server and read them from it"))
        let grid = NSGridView(views: [[addressLabel, addressField], [tokenLabel, tokenField]])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        tokenField.widthAnchor.constraint(equalTo: addressField.widthAnchor).isActive = true
        let serverCaption = small(L("The token is kept in a file only you may read, the same file the Ghidra skill's scripts read on this Mac. Leave the field empty to keep the token already there."))

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        // help: settings.code-analysis.send
        sendButton.title = L("Send This Mac's Analyses to the Server")
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendLocal)
        ControlHelp.describe(sendButton, L("Copy the analyses kept on this Mac to the analysis server"))
        let sendCaption = small(L("The server takes each analysis by the same rules as a project's: a later reading replaces an earlier one, and another project's reading of a module is kept aside rather than replacing the one there."))
        sendStatus.font = .systemFont(ofSize: 11)
        sendStatus.textColor = .secondaryLabelColor

        let help = HelpButton.standard(for: .topic(.codeAnalyses))

        for subview in [keptLabel, thisMacButton, serverButton, caption, grid, connectButton, serverCaption,
                        statusLabel, sendButton, sendCaption, sendStatus, help] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            help.centerYAnchor.constraint(equalTo: keptLabel.centerYAnchor),
            help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            keptLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            keptLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            thisMacButton.topAnchor.constraint(equalTo: keptLabel.bottomAnchor, constant: 8),
            thisMacButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 38),
            serverButton.topAnchor.constraint(equalTo: thisMacButton.bottomAnchor, constant: 6),
            serverButton.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),

            caption.topAnchor.constraint(equalTo: serverButton.bottomAnchor, constant: 8),
            caption.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            grid.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            connectButton.firstBaselineAnchor.constraint(equalTo: tokenField.firstBaselineAnchor),
            connectButton.leadingAnchor.constraint(equalTo: grid.trailingAnchor, constant: 8),
            connectButton.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),

            serverCaption.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            serverCaption.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            serverCaption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: serverCaption.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            sendButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            sendButton.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            sendCaption.topAnchor.constraint(equalTo: sendButton.bottomAnchor, constant: 8),
            sendCaption.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            sendCaption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            sendStatus.topAnchor.constraint(equalTo: sendCaption.bottomAnchor, constant: 8),
            sendStatus.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            sendStatus.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            sendStatus.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            SettingsMetrics.pinnedWidth(of: root),
        ])
        view = root
        observer = NotificationCenter.default.addObserver(
            forName: CodeAnalysisLocation.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        addressField.stringValue = location.serverAddress
        refresh()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func small(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Reads the choice and the connection into the tab.
    func refresh() {
        guard isViewLoaded else { return }
        let server = selectedMode == .server
        thisMacButton.state = server ? .off : .on
        serverButton.state = server ? .on : .off
        addressField.isEnabled = server
        tokenField.isEnabled = server
        connectButton.isEnabled = server
        tokenField.placeholderString = (try? location.readToken()) != nil
            ? L("Kept on this Mac") : L("None")
        statusLabel.stringValue = Self.statusText(of: location.state)
        switch location.state {
        case .unreachable, .refused:
            statusLabel.textColor = SemanticColors.bad
        default:
            statusLabel.textColor = .secondaryLabelColor
        }
        let connected: Bool
        if case .connected = location.state { connected = true } else { connected = false }
        sendButton.isEnabled = connected
    }

    /// The radio buttons show the choice being made; until Connect is clicked
    /// for a server, the stored choice is still the one in force.
    private var pendingMode: CodeAnalysisLocation.Mode?
    private var selectedMode: CodeAnalysisLocation.Mode { pendingMode ?? location.mode }

    /// One line on where the analyses are read from now.
    static func statusText(of state: CodeAnalysisLocation.State) -> String {
        switch state {
        case .local:
            return L("Analyses are read from this Mac.")
        case .connecting:
            return L("Connecting to the analysis server…")
        case .connected:
            return L("Connected. Analyses are read from the server and follow it.")
        case .refused(let reason):
            // The reason is the whole story — no token kept, a token the
            // server does not know, a right it lacks — so it leads the line.
            return L("%1$@ What this Mac has read is shown.", reason)
        case .unreachable(let reason):
            return L("The server cannot be reached; what this Mac has read is shown. %1$@", reason)
        }
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: NSButton) {
        if sender === thisMacButton {
            pendingMode = nil
            try? location.choose(.thisMac, server: addressField.stringValue, token: nil)
        } else {
            pendingMode = .server
        }
        refresh()
    }

    @objc private func connect() {
        do {
            try location.choose(.server, server: addressField.stringValue, token: tokenField.stringValue)
            pendingMode = nil
            tokenField.stringValue = ""
        } catch {
            statusLabel.stringValue = "\(error)"
            statusLabel.textColor = SemanticColors.bad
            return
        }
        refresh()
    }

    /// Every analysis kept on this Mac, as one bundle, to the server.
    @objc private func sendLocal() {
        guard let remote = location.remote else { return }
        let localRoot = location.localRoot
        sendButton.isEnabled = false
        sendStatus.stringValue = L("Sending…")
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<BundleImport?, Error> in
                do {
                    let store = try ContentStore(root: localRoot, create: false)
                    let keys = store.analyses().compactMap(\.key)
                    guard !keys.isEmpty else { return .success(nil) }
                    let url = store.tmpURL.appendingPathComponent("send-\(UUID().uuidString).zip")
                    defer { try? FileManager.default.removeItem(at: url) }
                    try store.exportBundle(keys, to: url)
                    let data = try Data(contentsOf: url)
                    return .success(try await remote.importBundle(data))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(nil):
                self.sendStatus.stringValue = L("This Mac keeps no analyses to send.")
            case .success(let report?):
                self.sendStatus.stringValue = L("Sent: %1$@ new, %2$@ already there, %3$@ not taken, %4$@ kept aside.",
                                                String(report.imported.count), String(report.unchanged.count),
                                                String(report.skipped.count), String(report.conflicts.count))
            case .failure(let error):
                self.sendStatus.stringValue = CodeAnalysisLocation.describe(error)
            }
            self.refresh()
        }
    }
}
