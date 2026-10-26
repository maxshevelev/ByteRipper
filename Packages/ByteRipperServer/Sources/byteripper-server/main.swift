import ByteRipperServer
import Foundation

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
case .token(let file, let replace):
    do {
        print(try TokenFile.make(at: file, replace: replace))
        FileHandle.standardError.write(Data("written to \(file.path)\n".utf8))
    } catch {
        fail("\(error)")
    }
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
