import Cocoa
import AppPalette
import CodeAnalysis
import CodeView
import GhidraHost
import HelpBook
import HelpUI
import Localization
import ToolModuleKit

/// The Code Analysis tab of the Settings window: where the code analyses are
/// kept — on this Mac, or on an analysis server in the person's network — the
/// server's address and token, and whether it is reached
/// (`Design/SERVER_PLAN.md` §5). What reaches a server's store is what is
/// published through it: nothing from this Mac's store is sent (stage 2.5).
final class CodeAnalysisSettingsViewController: NSViewController {
    /// The location the tab sets. The app's own unless a test hands it
    /// another.
    var location: CodeAnalysisLocation = .shared {
        didSet { refresh() }
    }
    /// The review kit the app's MCP offers, which says whether this server
    /// gives this token the review roles. The app's own unless a test hands
    /// it another.
    var reviewKit: ReviewKitCache = AgentService.reviewKit {
        didSet { refresh() }
    }

    private let thisMacButton = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let serverButton = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let addressField = NSTextField()
    private let tokenField = NSSecureTextField()
    private let connectButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    /// How to start the review pair's sessions: shown while the server is
    /// connected and gives this token the review kit.
    let reviewAgents = NSStackView()
    /// The commands and what each role is, under the block's disclosure
    /// triangle: folded away unless the person opened it before.
    let reviewAgentsBody = NSStackView()
    private let reviewAgentsDisclosure = NSButton(title: "", target: nil, action: nil)
    /// Where the disclosure's state is kept between launches.
    static let reviewAgentsExpandedKey = "CodeAnalysisReviewAgentsExpanded"
    /// Whether the UEFI tree draws how far a module's review has got.
    private let readinessCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// Whether the Code panel marks what a new revision changed as New.
    private let newMarksCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var reviewCheck: Task<Void, Never>?
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
        let caption = small(L("A server is shared: every Mac that names it reads the same analyses."))

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
        let serverCaption = small(L("An empty token field keeps the token already stored."))

        statusLabel.font = .systemFont(ofSize: 11)
        buildReviewAgents()
        let tail = NSStackView(views: [statusLabel, reviewAgents])
        tail.orientation = .vertical
        tail.alignment = .leading
        tail.spacing = 8
        statusLabel.widthAnchor.constraint(equalTo: tail.widthAnchor).isActive = true
        reviewAgents.widthAnchor.constraint(equalTo: tail.widthAnchor).isActive = true

        let help = HelpButton.standard(for: .topic(.codeAnalyses))

        // Both switches are read where they are drawn — the tree's badge and
        // the Code panel's marks — and both are told when they move, so a
        // panel on screen follows at once.
        // help: settings.code-analysis.readiness
        readinessCheckbox.title = L("Show how far a module's review has got")
        readinessCheckbox.target = self
        readinessCheckbox.action = #selector(readinessChanged(_:))
        ControlHelp.describe(readinessCheckbox, L("In the UEFI tree, a circle after an analysed module: empty, half filled or filled as its review progresses"))
        // help: settings.code-analysis.new-marks
        newMarksCheckbox.title = L("Mark what a new revision changed as New")
        newMarksCheckbox.target = self
        newMarksCheckbox.action = #selector(newMarksChanged(_:))
        ControlHelp.describe(newMarksCheckbox, L("The Code panel marks the functions and descriptions a newer revision changed until they are opened"))
        let displayLabel = NSTextField(labelWithString: L("Display"))
        displayLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        for subview in [keptLabel, thisMacButton, serverButton, caption, grid, connectButton, serverCaption,
                        tail, displayLabel, readinessCheckbox, newMarksCheckbox, help] {
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

            grid.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            connectButton.firstBaselineAnchor.constraint(equalTo: tokenField.firstBaselineAnchor),
            connectButton.leadingAnchor.constraint(equalTo: grid.trailingAnchor, constant: 8),
            connectButton.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),

            serverCaption.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            serverCaption.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            serverCaption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            tail.topAnchor.constraint(equalTo: serverCaption.bottomAnchor, constant: 8),
            tail.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            tail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            displayLabel.topAnchor.constraint(equalTo: tail.bottomAnchor, constant: 16),
            displayLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            readinessCheckbox.topAnchor.constraint(equalTo: displayLabel.bottomAnchor, constant: 8),
            readinessCheckbox.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            readinessCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            newMarksCheckbox.topAnchor.constraint(equalTo: readinessCheckbox.bottomAnchor, constant: 6),
            newMarksCheckbox.leadingAnchor.constraint(equalTo: thisMacButton.leadingAnchor),
            newMarksCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            newMarksCheckbox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

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
        reviewCheck?.cancel()
    }

    /// The two commands that start the review pair, and what each session
    /// is, under a disclosure triangle. What the roles are for, what they
    /// need, why a session is named at the start and why its command is typed
    /// in it is the help page's to say.
    // help: settings.code-analysis.review-agents
    private func buildReviewAgents() {
        reviewAgentsDisclosure.bezelStyle = .disclosure
        reviewAgentsDisclosure.setButtonType(.pushOnPushOff)
        reviewAgentsDisclosure.title = ""
        reviewAgentsDisclosure.target = self
        reviewAgentsDisclosure.action = #selector(reviewAgentsToggled(_:))
        ControlHelp.describe(reviewAgentsDisclosure, L("Show or hide how to start the review agents"))
        let title = NSTextField(labelWithString: L("Review agents"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(reviewAgentsTitleClicked)))
        let header = NSStackView(views: [reviewAgentsDisclosure, title])
        header.orientation = .horizontal
        header.spacing = 4
        func copyable(_ text: String) -> CopyableTextView {
            CopyableTextView(text: text, copyHelp: L("Copy to the clipboard"))
        }
        func command(_ text: String, _ role: String) -> NSView {
            let what = small(role)
            let column = NSStackView(views: [copyable(text), what])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            for view in column.arrangedSubviews {
                view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
            return column
        }
        let start = small(L("1. Start Claude Code in Terminal, one window for each role, under the role's name:"))
        let mac = AgentService.macName
        let claude = copyable(Self.startCommand(role: "Reviewer", mac: mac))
        let claudeVerifier = copyable(Self.startCommand(role: "Verifier", mac: mac))
        let then = small(L("2. In each session, type the command of its role:"))
        let reviewer = command(Self.reviewerCommand, L("Reviewer: reviews modules and publishes them."))
        let verifier = command(Self.verifierCommand,
                               L("Verifier: checks the Reviewer's results and changes nothing."))
        let body = [start, claude, claudeVerifier, then, reviewer, verifier]
        for view in body {
            reviewAgentsBody.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: reviewAgentsBody.widthAnchor).isActive = true
        }
        reviewAgentsBody.orientation = .vertical
        reviewAgentsBody.alignment = .leading
        reviewAgentsBody.spacing = 6
        reviewAgents.addArrangedSubview(header)
        reviewAgents.addArrangedSubview(reviewAgentsBody)
        reviewAgentsBody.widthAnchor.constraint(equalTo: reviewAgents.widthAnchor).isActive = true
        reviewAgents.orientation = .vertical
        reviewAgents.alignment = .leading
        reviewAgents.spacing = 8
        reviewAgents.isHidden = true
        let expanded = AppDefaults.store.bool(forKey: Self.reviewAgentsExpandedKey)
        reviewAgentsDisclosure.state = expanded ? .on : .off
        reviewAgentsBody.isHidden = !expanded
    }

    /// Whether the commands are shown under the block's title.
    var reviewAgentsExpanded: Bool { !reviewAgentsBody.isHidden }

    /// Opens or folds the commands, as a click on the triangle does.
    func toggleReviewAgentsForTesting() { reviewAgentsDisclosure.performClick(nil) }

    @objc private func reviewAgentsTitleClicked() { reviewAgentsDisclosure.performClick(nil) }

    @objc private func reviewAgentsToggled(_ sender: NSButton) {
        let expanded = sender.state == .on
        AppDefaults.store.set(expanded, forKey: Self.reviewAgentsExpandedKey)
        reviewAgentsBody.isHidden = !expanded
        (view.window?.windowController as? SettingsWindowController)?.fitToCurrentTab()
    }

    /// Started in Terminal under the role's session name; the role's prompt
    /// is then typed in its session. Claude Code knows an MCP server's prompts
    /// only after connecting to it, so `claude "/mcp__…"` at the start answers
    /// "Unknown command". The name is how the pair finds each other with
    /// `ListAgents` and `SendMessage`, and a session cannot set it itself: the
    /// roles name their peer as `Verifier · <Mac>` and `Reviewer · <Mac>`.
    static func startCommand(role: String, mac: String) -> String {
        "claude -n '" + "\(role) · \(mac)".replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    /// The role's prompt, which the app's MCP gives from the server's kit.
    static let reviewerCommand = "/mcp__byteripper__reviewer"
    static let verifierCommand = "/mcp__byteripper__verifier"

    /// Whether the review pair can be started: the server is connected, and
    /// the last fetch of its kit took it — a token without `ghidra.use` is
    /// refused it.
    static func showsReviewAgents(state: CodeAnalysisLocation.State, kitFetched: Bool?, hasKit: Bool) -> Bool {
        guard case .connected = state else { return false }
        return kitFetched == true && hasKit
    }

    /// Asks the server for its kit again and shows or hides the commands.
    private func checkReviewAgents() {
        reviewCheck?.cancel()
        let state = location.state
        guard case .connected = state else {
            if !reviewAgents.isHidden {
                reviewAgents.isHidden = true
                (view.window?.windowController as? SettingsWindowController)?.fitToCurrentTab()
            }
            return
        }
        let kit = reviewKit
        reviewCheck = Task { [weak self] in
            let current = await kit.current(force: true)
            let fetched = await kit.fetched
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let hidden = !Self.showsReviewAgents(state: self.location.state, kitFetched: fetched,
                                                     hasKit: current != nil)
                guard self.reviewAgents.isHidden != hidden else { return }
                self.reviewAgents.isHidden = hidden
                // The block's height comes and goes with it: the window follows.
                (self.view.window?.windowController as? SettingsWindowController)?.fitToCurrentTab()
            }
        }
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
        readinessCheckbox.state = CodeReadinessDisplay.showsReadiness ? .on : .off
        newMarksCheckbox.state = CodeRevisionSeen.tracksNewMarks ? .on : .off
        tokenField.placeholderString = (try? location.readToken()) != nil
            ? L("Kept on this Mac") : L("None")
        statusLabel.stringValue = Self.statusText(of: location.state)
        switch location.state {
        case .unreachable, .refused:
            statusLabel.textColor = SemanticColors.bad
        default:
            statusLabel.textColor = .secondaryLabelColor
        }
        checkReviewAgents()
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

    @objc private func readinessChanged(_ sender: NSButton) {
        CodeReadinessDisplay.set(showsReadiness: sender.state == .on)
    }

    @objc private func newMarksChanged(_ sender: NSButton) {
        CodeRevisionSeen.set(tracksNewMarks: sender.state == .on)
    }

    /// The two display switches, and a click on each, for a test.
    var showsReadinessShown: Bool { readinessCheckbox.state == .on }
    var tracksNewMarksShown: Bool { newMarksCheckbox.state == .on }
    func toggleReadinessForTesting() { readinessCheckbox.performClick(nil) }
    func toggleNewMarksForTesting() { newMarksCheckbox.performClick(nil) }

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
}
