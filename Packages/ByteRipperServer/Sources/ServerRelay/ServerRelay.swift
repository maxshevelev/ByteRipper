import AgentKit
import Foundation

/// `byteripper-server relay`: what an agent's client launches to reach the
/// server's local MCP (`Design/SERVER_HEADLESS_PLAN.md` §7, decision 13).
///
/// The client speaks MCP over this process's stdin and stdout; the server
/// speaks it on `<Server>/mcp.sock`. This copies bytes between the two and
/// does nothing else. It imports `AgentKit` and no role of the server, which
/// is what keeps the mode from starting a listener, a store or a Ghidra host.
public enum ServerRelay {
    /// What the client is told when there is no socket to talk to: the
    /// server is not running, or listens elsewhere.
    public static let unavailable = "No byteripper-server answers on the MCP socket: start it, or pass "
        + "--mcp-socket the path it listens on."

    /// Copies until either end goes, and answers the path's exit code.
    public static func run(path: String, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) -> Int32 {
        guard let socket = try? UnixSocket.connect(to: path) else {
            return unavailable(path, input: input, output: output)
        }
        // The client's requests to the server. When the client closes its
        // stdin it is done with this server; the half-close tells the server.
        let upstream = Thread {
            while let chunk = UnixSocket.readSome(input) {
                guard UnixSocket.writeAll(socket, chunk) else { break }
            }
            shutdown(socket, SHUT_WR)
        }
        upstream.name = "byteripper-server relay"
        upstream.start()

        // The server's answers to the client. When the server goes — it was
        // stopped — the relay ends, and the client starts it again when it
        // next needs it.
        while let chunk = UnixSocket.readSome(socket) {
            guard UnixSocket.writeAll(output, chunk) else { break }
        }
        shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
        return 0
    }

    /// With no server to talk to, every request is answered with the reason,
    /// so the client shows the person something they can act on instead of a
    /// timeout.
    static func unavailable(_ path: String, input: Int32, output: Int32) -> Int32 {
        FileHandle.standardError.write(Data(("\(unavailable) (\(path))\n").utf8))
        var framer = LineFramer()
        while let chunk = UnixSocket.readSome(input) {
            for case .message(let line) in framer.append(chunk) {
                guard let message = try? JSONValue.parse(line),
                      message["method"] != nil, let id = message["id"], !id.isNull else { continue }
                let answer: JSONValue = [
                    "jsonrpc": "2.0", "id": id,
                    "error": ["code": .int(MCPProtocol.ErrorCode.internalError), "message": .string(unavailable)]
                ]
                var data = answer.encoded()
                data.append(0x0A)
                UnixSocket.writeAll(output, data)
            }
        }
        return 1
    }
}
