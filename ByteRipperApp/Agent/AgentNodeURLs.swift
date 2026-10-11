import AgentKit
import Foundation

/// Links that open a UEFI node in ByteRipper: `byteripper://node?file=…&id=…`.
///
/// A node's id means nothing to the person, and its name alone can be one of
/// many. So every node an answer names on a file on disk carries a `link` —
/// its `label` as a Markdown link — for the agent to write where it names the
/// node. A click, in a client that opens it, brings the file forward or opens
/// it, opens UEFI Structure and chooses the node (`AppDelegate`).
enum AgentNodeURLs {
    static let scheme = "byteripper"

    /// The link that opens node `id` of the file at `file`.
    static func url(file: URL, node id: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "node"
        components.queryItems = [URLQueryItem(name: "file", value: file.path), URLQueryItem(name: "id", value: id)]
        return components.url
    }

    /// The link that brings the file at `file` forward, or opens it:
    /// `byteripper://file?path=…`.
    static func url(file: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.queryItems = [URLQueryItem(name: "path", value: file.path)]
        return components.url
    }

    /// The file and the node a link names — no node for a link to the file
    /// itself — or nil for one that is not ours.
    static func parse(_ url: URL) -> (file: URL, node: String?)? {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        if url.host == "file" {
            guard let path = items.first(where: { $0.name == "path" })?.value, path.hasPrefix("/") else { return nil }
            return (URL(fileURLWithPath: path), nil)
        }
        guard url.host == "node",
              // A path as the system writes it — here an absolute POSIX one;
              // the Windows edition takes `C:\…` (`Design/AGENT_PROTOCOL.md`).
              let path = items.first(where: { $0.name == "file" })?.value, path.hasPrefix("/"),
              let id = items.first(where: { $0.name == "id" })?.value, isNodeID(id) else { return nil }
        return (URL(fileURLWithPath: path), id)
    }

    static func isNodeID(_ text: String) -> Bool {
        !text.isEmpty && text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isASCIIDigit)
        }
    }

    /// `value` with a `link` beside every `label` of a UEFI node — an object
    /// with a node `id` and a `label` — on `file`.
    static func adding(to value: JSONValue, file: URL) -> JSONValue {
        switch value {
        case .object(var members):
            for (key, member) in members { members[key] = adding(to: member, file: file) }
            if case .string(let label)? = members["label"], case .string(let id)? = members["id"], isNodeID(id),
               members["kind"].map({ $0 == "uefi" }) ?? true,
               let url = url(file: file, node: id) {
                members["link"] = .string("[\(markdownText(label))](\(url.absoluteString))")
            }
            return .object(members)
        case .array(let items):
            return .array(items.map { adding(to: $0, file: file) })
        default:
            return value
        }
    }

    /// A label as Markdown link text: its brackets escaped.
    private static func markdownText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
