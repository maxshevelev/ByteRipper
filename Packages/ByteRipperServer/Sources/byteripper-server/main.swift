import ByteRipperServer
import CodeAnalysis
import Foundation
import GhidraHost
import ServerRelay

// `byteripper-server`: the arguments to a command, and the server run until a
// signal stops it. Everything else is in the ByteRipperServer library.

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("byteripper-server: \(message)\n".utf8))
    exit(status)
}

let command: ServerCommand
do {
    command = try ServerCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)\n\n\(ServerCommand.usage)", status: 2)
}

switch command {
case .help:
    print(ServerCommand.usage)
case .token(let command):
    do {
        print(try command.run())
    } catch {
        fail("\(error)")
    }
case .packProjects(let configuration, let apply):
    // The store and the projects this server is configured with; the folders
    // are read, never changed. Run with the server and its owners stopped.
    do {
        let store = try ContentStore(root: configuration.store)
        let host = GhidraHost(configuration: .init(projectsRoot: configuration.projects,
                                                   ghidraHome: configuration.ghidraHome,
                                                   sources: OwnerSources.resolved(explicit: configuration.ghidraScripts),
                                                   idle: configuration.idle),
                              writer: store)
        let answer = try await host.packProjects(apply: apply)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(answer), as: UTF8.self))
    } catch {
        fail("\(error)")
    }
case .relay(let path):
    // Before any `Server` exists: this mode copies bytes between stdin and
    // the local MCP's socket and starts no role at all.
    exit(ServerRelay.run(path: path))
case .serve(let configuration):
    let server = Server(configuration: configuration)
    do {
        try await server.start()
    } catch {
        fail("\(error)")
    }
    // Stop cleanly on Ctrl-C and on launchd's SIGTERM.
    var sources: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            server.stop()
            exit(0)
        }
        source.resume()
        sources.append(source)
    }
    // The main queue keeps running the store watcher and the signals.
    while true {
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}
