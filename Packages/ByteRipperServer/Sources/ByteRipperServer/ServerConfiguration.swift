import CodeAnalysis
import Foundation

/// What `byteripper-server` was asked to do, read from its arguments.
public enum ServerCommand: Equatable {
    case serve(ServerConfiguration)
    /// Write a new token file and print the token.
    case token(file: URL, replace: Bool)
    case help

    public static let usage = """
        usage: byteripper-server [serve] [--cas] [--listen <host>:<port>]
                                 [--store <dir>] [--token-file <file>]
               byteripper-server token [--token-file <file>] [--replace]

          --cas           serve the code-analysis store (the default role)
          --ghidra        host the Ghidra owners — not built yet
          --listen        the address to listen on, 127.0.0.1:8765 by default;
                          anything but loopback needs a token file
          --store         the store's directory, the app's own by default
          --token-file    the bearer token, a file only its owner may read;
                          used when present, required off loopback

          token           make a token file (0600) and print the token for the
                          app's Settings ▸ Code analysis
        """

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ arguments: [String]) throws -> ServerCommand {
        var rest = arguments[...]
        var verb = "serve"
        if let first = rest.first, !first.hasPrefix("-") {
            verb = first
            rest = rest.dropFirst()
        }
        func value(_ flag: String) throws -> String {
            guard let next = rest.first, !next.hasPrefix("--") else {
                throw Failure(description: "\(flag) needs a value")
            }
            rest = rest.dropFirst()
            return next
        }
        switch verb {
        case "help":
            return .help
        case "token":
            var file = ServerPaths.defaultTokenFile
            var replace = false
            while let flag = rest.popFirst() {
                switch flag {
                case "--token-file": file = URL(fileURLWithPath: try value(flag))
                case "--replace": replace = true
                case "--help", "-h": return .help
                default: throw Failure(description: "token does not take \(flag)")
                }
            }
            return .token(file: file, replace: replace)
        case "serve":
            var configuration = ServerConfiguration()
            var roles: Set<ServerConfiguration.Role> = []
            var tokenFileGiven = false
            while let flag = rest.popFirst() {
                switch flag {
                case "--cas":
                    roles.insert(.cas)
                case "--ghidra":
                    throw Failure(description: "the Ghidra role is not built yet (Design/SERVER_PLAN.md, phase 3)")
                case "--listen":
                    let address = try value(flag)
                    guard let colon = address.lastIndex(of: ":"),
                          let port = UInt16(address[address.index(after: colon)...]) else {
                        throw Failure(description: "--listen takes <host>:<port>, not \(address)")
                    }
                    configuration.host = String(address[..<colon])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    configuration.port = port
                case "--store":
                    configuration.store = URL(fileURLWithPath: try value(flag))
                case "--token-file":
                    configuration.tokenFile = URL(fileURLWithPath: try value(flag))
                    tokenFileGiven = true
                case "--help", "-h":
                    return .help
                default:
                    throw Failure(description: "serve does not take \(flag)")
                }
            }
            configuration.roles = roles.isEmpty ? [.cas] : roles
            configuration.tokenRequired = tokenFileGiven
            return .serve(configuration)
        default:
            throw Failure(description: "\(verb) is not a command of byteripper-server")
        }
    }
}

public struct ServerConfiguration: Equatable, Sendable {
    public enum Role: String, Sendable {
        case cas
    }

    public var roles: Set<Role> = [.cas]
    public var host = "127.0.0.1"
    public var port: UInt16 = 8765
    public var store = CodeAnalysisPaths.defaultRoot
    public var tokenFile = ServerPaths.defaultTokenFile
    /// A token file named on the command line must be there; the default one
    /// is used when it is.
    public var tokenRequired = false

    public init() {}
}

public enum ServerPaths {
    public static var support: URL {
        CodeAnalysisPaths.defaultRoot.deletingLastPathComponent()
            .appendingPathComponent("Server", isDirectory: true)
    }

    public static var defaultTokenFile: URL {
        support.appendingPathComponent("token", isDirectory: false)
    }
}
