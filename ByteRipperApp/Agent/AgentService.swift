import Cocoa
import AgentKit
import Localization
import ToolModuleKit

/// The agent service: the socket an agent's client reaches the app on, the
/// connections made to it, and the log of what they asked
/// (`Design/AGENT_PLAN.md`).
///
/// A service of the app, not a tool-module: one tool-module is open per tab
/// and it stops when another is picked, while an agent has to keep working
/// whatever the left panel shows. It lives as long as the app, and is off
/// until the person switches it on in Settings.
@MainActor
final class AgentService {
    /// Posted whenever what the Agent window or the status bar shows has
    /// changed: the switch, the socket, a connection, a call.
    static let didChange = Notification.Name("dev.maxik.ByteRipper.agentServiceDidChange")

    /// The app's one service, for the Settings tab and the Agent window to
    /// show. Set at launch; nil in the test host, which never opens the
    /// socket, and in a test that builds a service of its own.
    static weak var shared: AgentService?

    /// Where the switch is kept.
    static let enabledKey = "AgentServiceEnabled"
    /// Where the edit switch is kept: whether an agent may change an open
    /// file. Off after an install, and independent of the service's switch.
    static let editsKey = "AgentEditsAllowed"
    /// How many calls the log keeps.
    static let logLimit = 500

    let desk: AgentDesk
    let socketPath: String
    private let defaults: UserDefaults
    private let hostTools: AgentHostTools
    /// The agent's marks, which the Agent window lists and clears too.
    let markTools: AgentMarkTools
    /// Background documents, surveys and findings; the window lists the
    /// findings.
    let dumpTools: AgentDumpTools
    /// `write`, and the gate every module's edit goes through.
    let editTools: AgentEditTools
    private let moduleTools: AgentModuleTools
    /// `diff`, `compare` and `reveal_diff`.
    let diffTools: AgentDiffTools
    let findTools: AgentFindTools
    let refsTools: AgentRefsTools
    private let modules: [any ToolModule.Type]
    /// Built once: the tools do not change while the app runs.
    private(set) lazy var server = AgentServer(
        info: AgentServerInfo(name: "byteripper", version: Self.appVersion, title: "ByteRipper"),
        instructions: Self.instructions,
        tools: catalogue.map { Self.inEnglish($0.tool) })

    /// Every tool, in the order `tools/list` gives them, with where it comes
    /// from and what it does — what the Agent window's Tools page lists.
    private(set) lazy var catalogue: [AgentToolEntry] = {
        func entries(_ tools: [AgentTool], _ group: AgentToolGroup) -> [AgentToolEntry] {
            tools.map { tool in
                AgentToolEntry(tool: tool, group: group,
                               kind: group.isEdits ? .edit : tool.annotations.readOnly ? .read : .screen)
            }
        }
        var list = entries(hostTools.tools(), .files)
        list += entries(markTools.tools(), .marks)
        list += entries(dumpTools.tools(), .dumps)
        list += entries(diffTools.tools(), .comparison)
        list += entries(findTools.tools() + refsTools.tools(), .search)
        list += entries(editTools.tools(), .edits)
        // A module's tools under the module; its edits are edits.
        let modules = self.modules
        for tool in moduleTools.tools(modules: modules) {
            let module = modules.first { module in
                (module.agentQueries.map(\.name) + module.agentComparisons.map(\.name)
                    + module.agentEdits.map(\.name) + module.agentActions.map(\.name)).contains(tool.name)
            }
            let edits = module?.agentEdits.contains { $0.name == tool.name } ?? false
            list.append(AgentToolEntry(tool: tool, group: module.map { .module($0) } ?? .panels,
                                       kind: edits ? .edit : tool.annotations.readOnly ? .read : .screen))
        }
        return list
    }()

    /// How each tool has been used since the app started, by name. Kept
    /// apart from the log, which keeps only its last calls.
    private(set) var toolStats: [String: AgentToolStats] = [:]

    /// `tool`, answering in English whatever the window speaks: a field label
    /// a module borrows from its panel is built with `L()`, and a model reads
    /// the parsers' language (`Design/AGENT_PLAN.md`, "Language").
    private static func inEnglish(_ tool: AgentTool) -> AgentTool {
        AgentTool(name: tool.name, title: tool.title, description: tool.description,
                  inputSchema: tool.inputSchema, annotations: tool.annotations) { call in
            try await Localization.$override.withValue(.english) { try await tool.run(call) }
        }
    }

    private var listener: UnixSocketListener?
    private var connections: [ObjectIdentifier: UnixSocketConnection] = [:]
    /// The connections whose client has sent a message. A socket alone is
    /// not an agent: Claude Desktop, starting its servers, launches the relay,
    /// abandons it a second later for a fresh one, and leaves the first
    /// running with its pipes open. That relay connects and never speaks,
    /// and counting it showed two agents where there was one.
    private var clients: Set<ObjectIdentifier> = []

    /// Why the socket could not be opened, when it could not — another copy
    /// of the app holds it, the folder cannot be written. Nil while running
    /// or switched off.
    private(set) var failure: String?
    /// The calls made, oldest first, at most `logLimit` of them.
    private(set) var log: [AgentCallRecord] = []

    init(desk: AgentDesk, defaults: UserDefaults = .standard,
         socketPath: String = AgentEndpoint.socketPath(),
         modules: [any ToolModule.Type] = ToolRegistry.modules) {
        self.desk = desk
        self.defaults = defaults
        self.socketPath = socketPath
        self.modules = modules
        self.hostTools = AgentHostTools(desk: desk)
        self.markTools = AgentMarkTools(desk: desk)
        self.dumpTools = AgentDumpTools(desk: desk)
        self.editTools = AgentEditTools(desk: desk)
        self.diffTools = AgentDiffTools(desk: desk, modules: { modules })
        self.findTools = AgentFindTools(desk: desk, diff: diffTools)
        self.refsTools = AgentRefsTools(desk: desk, diff: diffTools)
        self.moduleTools = AgentModuleTools(desk: desk, edits: editTools, modules: { modules })
        editTools.isAllowed = { [weak self] in self?.editsAllowed ?? false }
        editTools.locate = { [diffTools] host, range in
            await diffTools.locate(host, [range]).first?.map(AgentDiffTools.placeJSON) ?? []
        }
        markTools.onChange = { [weak self] in self?.changed() }
        dumpTools.onChange = { [weak self] in self?.changed() }
        // A survey runs the other tools; it finds them in the finished list.
        dumpTools.toolNamed = { [weak self] name in self?.server.tools.first { $0.name == name } }
    }

    // MARK: - The switch

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            apply()
        }
    }

    /// Whether an agent may write into an open file (`AgentEditTools`).
    var editsAllowed: Bool {
        get { defaults.bool(forKey: Self.editsKey) }
        set {
            defaults.set(newValue, forKey: Self.editsKey)
            changed()
        }
    }

    var isRunning: Bool { listener != nil }
    /// The agents connected: the connections whose client has spoken.
    var connectionCount: Int { clients.count }

    /// The service's picture: a plug, hollow while no agent is connected and
    /// filled while one is. One name for every place that shows the service —
    /// the menu bar, the window's toolbar, the Settings tab — so they cannot
    /// disagree about it. The plug is macOS 15's; macOS 14 has no such symbol
    /// and keeps the three joined points it had before.
    static func symbolName(connected: Bool) -> String {
        if #available(macOS 15, *) {
            return connected ? "powerplug.portrait.fill" : "powerplug.portrait"
        }
        return connected ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted"
    }

    /// Opens or closes the socket to match the switch.
    func apply() {
        if isEnabled { start() } else { stop() }
    }

    private func start() {
        guard listener == nil else { return }
        let listener = UnixSocketListener(path: socketPath)
        do {
            try listener.start { [weak self] socket in
                Task { @MainActor in self?.adopt(socket) }
            }
            self.listener = listener
            failure = nil
        } catch {
            failure = "\(error)"
        }
        changed()
    }

    /// Closes the socket and every connection on it. A client finds the relay
    /// gone and starts it again when it next needs it.
    func stop() {
        listener?.stop()
        listener = nil
        for socket in connections.values { socket.close() }
        connections.removeAll()
        clients.removeAll()
        // Nobody is left to ask about them, and each holds a parsed image.
        desk.background.closeAll()
        failure = nil
        changed()
    }

    // MARK: - Connections

    private func adopt(_ socket: UnixSocketConnection) {
        guard isRunning else {
            socket.close()
            return
        }
        let key = ObjectIdentifier(socket)
        connections[key] = socket
        let connection = connect(send: { socket.write($0) }, onFirstMessage: { [weak self] in
            Task { @MainActor in
                guard let self, self.connections[key] != nil else { return }
                self.clients.insert(key)
                self.changed()
            }
        })
        // One consumer, in order: the chunks of a stream must reach the
        // framer in the order they were read.
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        Task {
            for await chunk in chunks { await connection.receive(chunk) }
            await connection.close()
        }
        socket.startReading(onData: { feed.yield($0) }, onClose: { [weak self] in
            feed.finish()
            Task { @MainActor in
                self?.connections[key] = nil
                self?.clients.remove(key)
                self?.changed()
            }
        })
        changed()
    }

    /// A connection to the service over whatever carries the bytes — the
    /// socket, or a test's own pipe.
    func connect(send: @escaping @Sendable (Data) -> Void,
                 onFirstMessage: @escaping @Sendable () -> Void = {}) -> AgentConnection {
        AgentConnection(server: server, send: send, observer: { [weak self] record in
            Task { @MainActor in self?.record(record) }
        }, onFirstMessage: onFirstMessage, onCallStarted: { [weak self] record in
            Task { @MainActor in self?.record(record) }
        })
    }

    /// A call into the log: a running one at the bottom, and a finished one
    /// in the place of its running record, so a request the tool is still
    /// working on is in the log from the moment it arrives and its row does
    /// not move when it ends. A running record that arrives after its call
    /// has finished — the two hop to this actor separately — is dropped.
    private func record(_ record: AgentCallRecord) {
        if let index = log.firstIndex(where: { $0.id == record.id }) {
            guard !record.isRunning else { return }
            log[index] = record
        } else {
            log.append(record)
        }
        if !record.isRunning {
            toolStats[record.tool, default: AgentToolStats()].add(record)
        }
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        changed()
    }

    /// A record handed straight to the log, for tests that need a call in a
    /// state a real one passes through too quickly to catch.
    func recordForTesting(_ call: AgentCallRecord) { record(call) }

    func clearLog() {
        log.removeAll()
        changed()
    }

    func resetToolStats() {
        toolStats.removeAll()
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - What the server says about itself

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Read by the model once, before it uses any tool.
    static let instructions = """
        ByteRipper is a hex editor for firmware dumps, open on the person's Mac. These tools read the \
        files open in it and show places in them to the person. Call `documents` for what is open and \
        `focus` for what the person is looking at; when they say "this" or "here", `focus` is what they \
        mean. Addresses and sizes are hex strings such as "0x7F3000" in every answer and may be given \
        back the same way. Ranges are half-open: `end` is the first byte after the range. A tool refuses an \
        argument it does not take and names the ones it does — to see whether a client passes arguments on, \
        call a reading tool such as `documents` with one it does not take; do not try it on `open_part`, which \
        opens a panel when it is let through. A list comes in \
        pages: `limit` is a ceiling, a page also stops before the answer passes the size bound and says \
        `truncated: "size"`, and `next`, passed back as `after`, goes on until it is null. Use `reveal` \
        to point at what you are talking about; the person's Back undoes it. `open_dump` reads a file by \
        path without putting it on screen, `survey` asks one tool's question of a whole folder of dumps, and \
        `finding` records each thing found for the person to check with a click. `find_bytes` searches the \
        bytes for a text or a pattern — inside a compressed section with `node` — `uefi_node_data` reads a \
        node's bytes, and `open_part` opens a stretch or a node — a compressed one too, or a Lenovo LENV block \
        decoded with `part: "decoded"` — as a part of its own, in a panel over the same window; prefer it to a \
        new tab, which is for changing context or comparing two parts. Asking again for a part that is open \
        raises its panel (`reused: true`); a new part takes the focus, and its tree has ids of its own, so name the \
        `document` a node id was listed on. \
        A part is a document to every tool, and `update_in_parent` puts its bytes back. `diff` lists where two \
        documents differ byte by byte and in which part of the firmware; `compare` shows the two side by \
        side and `reveal_diff` walks the person through the differences. `mark` labels bytes for the \
        person while you explain them, and `related_to` says how two marks hang together. Nothing here \
        saves a file; `write`, `update_in_parent`, the `_fix_checksum` tools and the microcode tools — `microcode_catalogue` \
        lists what github.com/platomav/CPUMicrocodes offers, `fit_add_microcode`, `fit_replace_microcode` and \
        `fit_remove_microcode` change the FIT — change an open file, one undo step each, and only if the \
        person allows edits. \
        The `uefi_` tools read a firmware image's structure and work whether or not its panel is open; \
        `uefi_select` and `uefi_selection` act on the open UEFI Structure panel, which `open_panel` opens.
        """
}
