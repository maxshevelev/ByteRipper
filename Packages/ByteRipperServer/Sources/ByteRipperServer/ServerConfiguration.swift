import CodeAnalysis
import Foundation
import GhidraHost

/// What `byteripper-server` was asked to do, read from its arguments.
public enum ServerCommand: Equatable {
    case serve(ServerConfiguration)
    /// Write a new token file and print the token.
    case token(file: URL, replace: Bool)
    case help

    public static let usage = """
        usage: byteripper-server [serve] [--cas] [--ghidra] [--listen <host>:<port>]
                                 [--store <dir>] [--token-file <file>]
                                 [--cas-url <url>] [--ghidra-home <dir>] [--projects <dir>] [--idle <s>]
               byteripper-server token [--token-file <file>] [--replace]

          --cas           serve the code-analysis store
          --ghidra        host the Ghidra owners; publishes into this server's
                          store, or into --cas-url's
                          (with neither named, both roles are on)
          --listen        the address to listen on, 127.0.0.1:8765 by default;
                          anything but loopback needs a token file
          --store         the store's directory, the app's own by default
          --token-file    the bearer token, a file only its owner may read;
                          used when present, required off loopback
          --cas-url       the served store the Ghidra role publishes into,
                          when this server does not serve one; same token
          --ghidra-home   the Ghidra install; GHIDRA_HOME or the newest found
          --projects      the modules' kept projects, the app's folder by default
          --idle          seconds an owner waits for a call before it saves and
                          exits, 1800 by default

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
                    roles.insert(.ghidra)
                case "--cas-url":
                    let text = try value(flag)
                    guard let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else {
                        throw Failure(description: "--cas-url takes http://<host>:<port>, not \(text)")
                    }
                    configuration.casURL = url
                case "--ghidra-home":
                    configuration.ghidraHome = URL(fileURLWithPath: try value(flag))
                case "--projects":
                    configuration.projects = URL(fileURLWithPath: try value(flag))
                case "--idle":
                    let text = try value(flag)
                    guard let idle = Int(text), idle >= 0 else { throw Failure(description: "--idle takes seconds") }
                    configuration.idle = idle
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
            configuration.roles = roles.isEmpty ? [.cas, .ghidra] : roles
            if configuration.roles.contains(.ghidra), !configuration.roles.contains(.cas), configuration.casURL == nil {
                throw Failure(description: "the Ghidra role publishes into a store: add --cas, or name --cas-url")
            }
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
        case ghidra
    }

    public var roles: Set<Role> = [.cas, .ghidra]
    public var casURL: URL?
    public var ghidraHome: URL?
    public var projects = GhidraHost.defaultProjectsRoot
    public var idle = 1800
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
