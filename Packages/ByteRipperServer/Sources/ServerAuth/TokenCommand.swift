import Foundation
import HTTPService

/// `byteripper-server token …`: the only way a secret is made, and the only
/// time it is shown (`Design/SERVER_HEADLESS_PLAN.md` §5).
public enum TokenCommand: Equatable, Sendable {
    case add(name: String, rights: Set<HTTPRight>, file: URL)
    case list(file: URL)
    case rotate(id: String, file: URL)
    case revoke(id: String, file: URL)

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    public static let usage = """
        usage: byteripper-server token add --name <name> [--rights <right,…> | --preset <reader|app|admin>] [--tokens <file>]
               byteripper-server token list [--tokens <file>]
               byteripper-server token rotate <id|name> [--tokens <file>]
               byteripper-server token revoke <id|name> [--tokens <file>]

          add             make a token and print its secret, once; every token
                          carries cas.read
          list            what the file holds, never a secret or a hash
          rotate          replace a token's secret; the old one stops working
          revoke          refuse a token from then on

          --rights        cas.read, cas.write, ghidra.use, admin
          --preset        reader (cas.read), app (cas.read, cas.write,
                          ghidra.use), admin (all)
          --tokens        the file, this server's own by default
        """

    /// `arguments` follows the `token` verb.
    public static func parse(_ arguments: [String], defaultFile: URL) throws -> TokenCommand {
        var rest = arguments[...]
        guard let verb = rest.popFirst() else {
            throw Failure("token takes add, list, rotate or revoke")
        }
        var file = defaultFile
        var name: String?
        var rights: Set<HTTPRight>?
        var preset: TokenPreset?
        var positionals: [String] = []
        while let flag = rest.popFirst() {
            func value() throws -> String {
                guard let next = rest.popFirst(), !next.hasPrefix("--") else {
                    throw Failure("\(flag) needs a value")
                }
                return next
            }
            switch flag {
            case "--tokens":
                file = URL(fileURLWithPath: try value())
            case "--config":
                _ = try value()   // read by ServerCommand before this
            case "--support":
                _ = try value()   // read by ServerCommand before this
            case "--no-config":
                break
            case "--name":
                name = try value()
            case "--rights":
                rights = try Self.rights(try value())
            case "--preset":
                let text = try value()
                guard let found = TokenPreset(rawValue: text) else {
                    throw Failure("--preset takes \(TokenPreset.allCases.map(\.rawValue).joined(separator: ", ")), not \(text)")
                }
                preset = found
            case "--help", "-h":
                throw Failure(usage)
            default:
                guard !flag.hasPrefix("-") else { throw Failure("token \(verb) does not take \(flag)") }
                positionals.append(flag)
            }
        }
        switch verb {
        case "add":
            guard let name else { throw Failure("add needs --name") }
            guard rights == nil || preset == nil else {
                throw Failure("--rights and --preset say the same thing: use one")
            }
            return .add(name: name, rights: preset?.rights ?? rights ?? [.casRead], file: file)
        case "list":
            guard positionals.isEmpty else { throw Failure("list takes no arguments") }
            return .list(file: file)
        case "rotate", "revoke":
            guard positionals.count == 1 else { throw Failure("\(verb) takes one token id or name") }
            return verb == "rotate" ? .rotate(id: positionals[0], file: file)
                : .revoke(id: positionals[0], file: file)
        default:
            throw Failure("token \(verb) is not a command of byteripper-server")
        }
    }

    /// What the command prints. A secret is in it once — for `add` and
    /// `rotate` — and never for `list`.
    public func run() throws -> String {
        switch self {
        case .add(let name, let rights, let file):
            let store = try TokenStore.open(at: file)
            let (token, secret) = try store.add(name: name, rights: rights)
            return """
                \(secret)

                token \(token.id) "\(token.name)", rights \(Self.names(token.rights)), in \(file.path)
                The secret is shown once and kept nowhere. Paste it into the app's
                Settings ▸ Code Analysis: the app writes it to the file the skill's
                scripts read on that Mac.
                """
        case .list(let file):
            let tokens = try TokenStore.open(at: file).all()
            guard !tokens.isEmpty else { return "no tokens in \(file.path)" }
            return Self.table(tokens)
        case .rotate(let id, let file):
            let store = try TokenStore.open(at: file)
            let secret = try store.rotate(id)
            return """
                \(secret)

                rotation done: the old secret of \(id) stopped working
                """
        case .revoke(let id, let file):
            try TokenStore.open(at: file).revoke(id)
            return "revoked \(id)"
        }
    }

    static func rights(_ text: String) throws -> Set<HTTPRight> {
        var rights: Set<HTTPRight> = []
        for name in text.split(separator: ",") {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard let right = HTTPRight(rawValue: trimmed) else {
                throw Failure("\(trimmed) is not a right: \(TokenPreset.rightNames)")
            }
            rights.insert(right)
        }
        guard !rights.isEmpty else { throw Failure("--rights needs a right: \(TokenPreset.rightNames)") }
        return rights
    }

    static func names(_ rights: [HTTPRight]) -> String {
        rights.map(\.rawValue).joined(separator: ", ")
    }

    static func table(_ tokens: [TokenStore.Token]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        func when(_ date: Date?) -> String { date.map(formatter.string) ?? "-" }
        let rows = tokens.map { token in
            [token.id, token.name, names(token.rights), when(token.created),
             when(token.lastUsed), token.revoked ? "yes" : "-"]
        }
        let headers = ["id", "name", "rights", "created", "last used", "revoked"]
        let widths = headers.indices.map { column in
            max(headers[column].count, rows.map { $0[column].count }.max() ?? 0)
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated()
                .map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }
        return ([line(headers)] + rows.map(line)).joined(separator: "\n")
    }
}
