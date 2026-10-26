import Foundation

/// The bearer token the server and its clients share, kept in a file only
/// its owner may read.
public enum TokenFile {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case exists(String)
        case readableByOthers(String)
        case empty(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .exists(let path):
                return "\(path) already holds a token; pass --replace to make a new one"
            case .readableByOthers(let path):
                return "\(path) may be read by others; chmod 600 it"
            case .empty(let path):
                return "\(path) holds no token"
            case .unreadable(let path):
                return "cannot read \(path)"
            }
        }
    }

    /// A new token — 32 random bytes, base64url — written 0600.
    @discardableResult
    public static func make(at url: URL, replace: Bool = false) throws -> String {
        if !replace, FileManager.default.fileExists(atPath: url.path) {
            throw Failure.exists(url.path)
        }
        // The system generator is the platform's cryptographic source
        // (arc4random on Darwin, getrandom on Linux, BCryptGenRandom on Windows).
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Created 0600 before the token is in it, so it is never readable by
        // others even for a moment.
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Data((token + "\n").utf8).write(to: url)
        return token
    }

    /// The token, or nil when there is no file. A file group or others may
    /// read is refused: a token anyone on the machine can read guards nothing.
    public static func read(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard mode & 0o077 == 0 else { throw Failure.readableByOthers(url.path) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.unreadable(url.path)
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw Failure.empty(url.path) }
        return token
    }
}
