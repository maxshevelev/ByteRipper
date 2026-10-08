//  byteripper-mcp — what an agent's client launches to reach ByteRipper.
//
//  The client speaks MCP over this process's stdin and stdout. The app speaks
//  it on a Unix socket in the user's Library (`AgentEndpoint`). This copies
//  bytes between the two and does nothing else: it parses no message except
//  when there is no app to pass it to, and then only to say so
//  (`Design/AGENT_PLAN.md`, "The relay").
//
//  It lives inside the app's bundle, in `Contents/Helpers`, so it is always the
//  relay of the app beside it — the same build, the same socket path.

import AgentKit
import Foundation

/// How long to wait for the app's socket after launching the app.
let launchWait: TimeInterval = 10

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
func launch(_ app: URL) {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", app.path]
    try? open.run()
    open.waitUntilExit()
}

func connect(to path: String) -> Int32? {
    if let fd = try? UnixSocket.connect(to: path) { return fd }
    guard let app = enclosingApp() else { return nil }
    launch(app)
    let deadline = Date().addingTimeInterval(launchWait)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.25)
        if let fd = try? UnixSocket.connect(to: path) { return fd }
    }
    return nil
}

/// With no app to talk to, every request is answered with the reason, so the
/// client shows the person something they can act on instead of a timeout.
func answerUnavailable() -> Never {
    var framer = LineFramer()
    while let chunk = UnixSocket.readSome(STDIN_FILENO) {
        for case .message(let line) in framer.append(chunk) {
            guard let message = try? JSONValue.parse(line),
                  message["method"] != nil, let id = message["id"], !id.isNull else { continue }
            let answer: JSONValue = [
                "jsonrpc": "2.0", "id": id,
                "error": ["code": .int(MCPProtocol.ErrorCode.internalError),
                          "message": .string(AgentEndpoint.unavailableMessage)]
            ]
            var data = answer.encoded()
            data.append(0x0A)
            UnixSocket.writeAll(STDOUT_FILENO, data)
        }
    }
    exit(0)
}

let path = AgentEndpoint.socketPath()
guard let socket = connect(to: path) else {
    FileHandle.standardError.write(Data((AgentEndpoint.unavailableMessage + "\n").utf8))
    answerUnavailable()
}

// The client's requests to the app. When the client closes stdin it is done
// with this server, and so is the relay.
let upstream = Thread {
    while let chunk = UnixSocket.readSome(STDIN_FILENO) {
        guard UnixSocket.writeAll(socket, chunk) else { break }
    }
    exit(0)
}
upstream.start()

// The app's answers to the client. When the app goes — it quit, or the switch
// was turned off — the relay ends, and the client starts it again when it next
// needs it, as the protocol has it do for a server that exits.
while let chunk = UnixSocket.readSome(socket) {
    guard UnixSocket.writeAll(STDOUT_FILENO, chunk) else { break }
}
exit(0)
