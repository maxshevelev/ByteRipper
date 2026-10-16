//  byteripper-mcp — what an agent's client launches to reach ByteRipper.
//
//  The client speaks MCP over this process's stdin and stdout. The app speaks
//  it on a Unix socket in the user's Library (`AgentEndpoint`). This copies
//  bytes between the two and does nothing else: it parses no message except
//  when there is no app to pass it to, and then only to say so
//  (`Design/AGENT_PLAN.md`, "The relay").
//
//  **It outlives the app.** A client starts this process once and keeps it for
//  the whole conversation, and the app may be quit and opened again in the
//  middle of one — an Xcode run does exactly that. So when the app goes the
//  relay does not: it answers the client with the reason, waits, and attaches
//  to the app again when it comes back. A client that does not restart a server
//  which exited inside a session — Claude Code does not — then never loses it,
//  and the person never registers the server a second time.
//
//  The path a client's configuration names is the *installed* copy of it, beside
//  the socket, which the app writes at every launch (`AgentRelayInstall`): this
//  bundle's own path changes with the folder the app was built in, and a
//  configuration is meant to be made once.

import AgentKit
import Foundation

/// How long to wait for the app's socket after starting the app.
let launchWait: TimeInterval = 10

/// How often to look for a socket that is not there yet.
let lookEvery: TimeInterval = 0.25

/// The app bundle this relay was shipped in: `ByteRipper.app` when run from
/// `ByteRipper.app/Contents/Helpers/byteripper-mcp`, nil when run from anywhere
/// else — a build folder, a test.
func enclosingApp() -> URL? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}

/// Starts the app in the background, so a client launched before the app
/// still finds it. Whether its agent service is switched on is the app's
/// setting; if it is off, the socket never appears and the client is told.
/// Only under `BYTERIPPER_LAUNCH` (`AgentEndpoint.launchKey`), which the
/// person asks for in Settings ▸ Agent: a client restarts its server as soon
/// as the app quits, and the person who quit it saw it come straight back.
func launch(_ app: URL) {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", app.path]
    try? open.run()
    open.waitUntilExit()
}

let path = AgentEndpoint.socketPath()
let launches = AgentEndpoint.launchesApp()

/// why there is nothing to talk to: the service is off — or, from a relay
/// that does not start the app, the app may simply not be open.
let unavailableMessage = launches ? AgentEndpoint.unavailableMessage : AgentEndpoint.notStartedMessage

/// The app's end of the conversation, nil while there is no app to talk to.
/// Both threads look at it and either may clear it, so every look goes through
/// the lock. Only the thread below closes it.
let stateLock = NSLock()
var upstream: Int32?

func currentUpstream() -> Int32? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return upstream
}

func setUpstream(_ socket: Int32?) {
    stateLock.lock()
    upstream = socket
    stateLock.unlock()
}

/// Whether this relay has started the app already. The app is started **once**
/// in the relay's life: the promise the launch switch makes is "open ByteRipper
/// when an agent connects", and a person who quits ByteRipper does not want the
/// server that is still running to open it again a moment later.
var hasLaunched = false

/// Waits for the app's socket and attaches to it; nil when it is not there.
/// The first look is the one that may start the app, and the only one that
/// waits for it to come up.
func attach() -> Int32? {
    if let socket = try? UnixSocket.connect(to: path) { return socket }
    guard launches, !hasLaunched, let app = enclosingApp() else { return nil }
    hasLaunched = true
    launch(app)
    let deadline = Date().addingTimeInterval(launchWait)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: lookEvery)
        if let socket = try? UnixSocket.connect(to: path) { return socket }
    }
    return nil
}

/// The answer to one request when there is no app to pass it to: the reason,
/// so the client shows the person something they can act on instead of a
/// timeout.
func answerUnavailable(_ line: Data) {
    guard let message = try? JSONValue.parse(line),
          message["method"] != nil, let id = message["id"], !id.isNull else { return }
    let answer: JSONValue = [
        "jsonrpc": "2.0", "id": id,
        "error": ["code": .int(MCPProtocol.ErrorCode.internalError),
                  "message": .string(unavailableMessage)]
    ]
    var data = answer.encoded()
    data.append(0x0A)
    UnixSocket.writeAll(STDOUT_FILENO, data)
}

/// The app's side: read its answers while it is there, and when it goes, wait
/// for it to come back — for as long as the client keeps this relay.
func follow() -> Never {
    while true {
        guard let socket = currentUpstream() else {
            setUpstream(attach())
            if currentUpstream() == nil { Thread.sleep(forTimeInterval: lookEvery) }
            continue
        }
        while let chunk = UnixSocket.readSome(socket) {
            guard UnixSocket.writeAll(STDOUT_FILENO, chunk) else { exit(0) }
        }
        // The app quit, or was switched off. The client is still there.
        setUpstream(nil)
        close(socket)
    }
}

// The first look happens before the client's first request is read: an
// `initialize` answered with an error is a server a client may not come back
// to, and an app that is merely starting is worth the wait.
setUpstream(attach())
if currentUpstream() == nil {
    FileHandle.standardError.write(Data((unavailableMessage + "\n").utf8))
}
Thread { follow() }.start()

// The client's requests. Attached, they go to the app as they are; detached,
// the client is told why.
var framer = LineFramer()
while let chunk = UnixSocket.readSome(STDIN_FILENO) {
    for case .message(let line) in framer.append(chunk) {
        guard let socket = currentUpstream() else {
            answerUnavailable(line)
            continue
        }
        var request = line
        request.append(0x0A)
        if !UnixSocket.writeAll(socket, request) {
            // It went between the look and the write. The thread above finds
            // the same broken socket and clears it.
            answerUnavailable(line)
        }
    }
}

// The client is done with this server, and so is the relay.
exit(0)
