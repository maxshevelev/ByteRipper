import Foundation
import HTTPService
import ServerAuth

/// The names the console answers to (`Design/SERVER_HEADLESS_PLAN.md`
/// decision 19): the listen addresses, the names given with `--server-name`,
/// and — for a wildcard listener — this Mac's own addresses.
///
/// A browser sends the name it was pointed at as `Host`, and the page's
/// origin as `Origin`. A name that is not listed is a page that reached this
/// server under a name it does not own — DNS rebinding — and is refused before
/// any route runs, the open sign-in included.
public struct ConsoleNames: Sendable, Equatable {
    public let names: Set<String>

    public init(names: Set<String>) {
        self.names = Set(names.map(Self.normalized))
    }

    /// - Parameters:
    ///   - listens: the hosts of `--listen`, as given.
    ///   - serverNames: `--server-name`, repeatable.
    ///   - interfaces: this Mac's addresses, for a wildcard listener.
    public init(listens: [String], serverNames: [String], interfaces: () -> [String] = ConsoleNames.interfaceAddresses) {
        var names = Set(serverNames)
        for host in listens {
            let host = Self.normalized(host)
            names.insert(host)
            if Self.isWildcard(host) {
                names.formUnion(interfaces())
                names.formUnion(Self.loopback)
                let local = ProcessInfo.processInfo.hostName
                names.insert(local)
                if !local.hasSuffix(".local") { names.insert(local + ".local") }
            } else if Self.loopback.contains(host) {
                names.formUnion(Self.loopback)
            } else if let address = try? HTTPServer.resolve(host) {
                names.insert(address)
            }
        }
        self.init(names: names)
    }

    static let loopback: Set<String> = ["localhost", "127.0.0.1", "::1"]

    public static func isWildcard(_ host: String) -> Bool {
        host == "0.0.0.0" || host == "::" || host == "*" || host.isEmpty
    }

    /// Lower case, no brackets, no trailing dot: `[::1]` is `::1`,
    /// `Mac.local.` is `mac.local`.
    static func normalized(_ host: String) -> String {
        var host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// The host of a `Host` header or of an origin's authority, without its
    /// port: `127.0.0.1:8765` → `127.0.0.1`, `[::1]:8765` → `::1`. The port is
    /// dropped on purpose — it is not what the guard is about: the name is the
    /// thing DNS rebinding takes over, and a name on another port is a server
    /// somebody already reaches by name.
    static func host(ofAuthority authority: String) -> String {
        let authority = authority.trimmingCharacters(in: .whitespaces)
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            return normalized(String(authority[authority.index(after: authority.startIndex)..<close]))
        }
        if authority.filter({ $0 == ":" }).count == 1, let colon = authority.lastIndex(of: ":") {
            return normalized(String(authority[..<colon]))
        }
        return normalized(authority)
    }

    /// The refusal for a console request under a name this server does not
    /// own; nil for every other request, and for one under a listed name.
    public func screen(_ head: HTTPRequest) -> HTTPError? {
        guard ServerAuthorizer.isConsole(head.path) else { return nil }
        guard let host = head.headers["host"], names.contains(Self.host(ofAuthority: host)) else {
            return HTTPError(.forbidden, "the console answers only under this server's own names; "
                + "start it with --server-name <name> to add one")
        }
        if let origin = head.headers["origin"] {
            guard origin != "null", let url = URL(string: origin), let scheme = url.scheme,
                  scheme == "http" || scheme == "https", let originHost = url.host,
                  names.contains(Self.normalized(originHost)) else {
                return HTTPError(.forbidden, "a page of another site cannot use the console")
            }
        }
        // A browser says a request crosses sites even where it sends no
        // Origin, as on a navigation.
        if head.headers["sec-fetch-site"] == "cross-site" {
            return HTTPError(.forbidden, "a page of another site cannot use the console")
        }
        return nil
    }

    /// Every address of this Mac's interfaces, IPv4 and IPv6.
    public static func interfaceAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var found: [String] = []
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            entry = current.pointee.ifa_next
            guard let address = current.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            // `fe80::1%en0`: the scope is not part of what a browser sends.
            let text = String(cString: buffer)
            found.append(String(text.split(separator: "%").first ?? Substring(text)))
        }
        return found
    }
}
