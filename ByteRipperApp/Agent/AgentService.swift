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
    /// How many calls the log keeps.
    static let logLimit = 500

    let desk: AgentDesk
    let socketPath: String
    private let defaults: UserDefaults
    private let hostTools: AgentHostTools
    private let moduleTools: AgentModuleTools
    private let modules: [any ToolModule.Type]
    /// Built once: the tools do not change while the app runs.
    private(set) lazy var server = AgentServer(
        info: AgentServerInfo(name: "byteripper", version: Self.appVersion, title: "ByteRipper"),
        instructions: Self.instructions,
        tools: (hostTools.tools() + moduleTools.tools(modules: modules)).map(Self.inEnglish))

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
        self.moduleTools = AgentModuleTools(desk: desk, modules: { modules })
    }

    // MARK: - The switch

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            apply()
        }
    }

    var isRunning: Bool { listener != nil }
    var connectionCount: Int { connections.count }

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
        let connection = connect(send: { socket.write($0) })
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
                self?.changed()
            }
        })
        changed()
    }

    /// A connection to the service over whatever carries the bytes — the
    /// socket, or a test's own pipe.
    func connect(send: @escaping @Sendable (Data) -> Void) -> AgentConnection {
        AgentConnection(server: server, send: send, observer: { [weak self] record in
            Task { @MainActor in self?.record(record) }
        })
    }

    private func record(_ record: AgentCallRecord) {
        log.append(record)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        changed()
    }

    func clearLog() {
        log.removeAll()
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
        back the same way. Ranges are half-open: `end` is the first byte after the range. Use `reveal` \
        to point at what you are talking about; the person's Back undoes it. Nothing here saves a file. \
        The `uefi_` tools read a firmware image's structure and work whether or not its panel is open; \
        `uefi_select` and `uefi_selection` act on the open UEFI Structure panel, which `open_panel` opens.
        """
}
