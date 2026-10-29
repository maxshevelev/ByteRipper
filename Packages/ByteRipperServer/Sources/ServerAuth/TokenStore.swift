import CryptoKit
import Foundation
import HTTPService

/// The server's tokens: one `tokens.json`, holding each token's identity, its
/// rights and the SHA-256 of its secret — never the secret itself
/// (`Design/SERVER_HEADLESS_PLAN.md` §5).
///
/// The file is the truth and this class is its cache. Every write takes a
/// sidecar lock, re-reads the file, applies the change and writes it back, so
/// a `byteripper-server token revoke` run beside a live server is not undone
/// by that server's next `last_used` flush. A read re-checks the file's stamp
/// first, so a revocation takes effect at the next request.
///
/// `last_used` is kept in memory and written at most once a minute, and at
/// stop — never a file write per request, which would be a write per call the
/// agent makes.
public final class TokenStore: @unchecked Sendable {
    public struct Token: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// Lower-case hex of SHA-256 over the secret's bytes.
        public var hash: String
        /// Sorted by the right's name, so the same set is the same file.
        public var rights: [HTTPRight]
        public var created: Date
        public var lastUsed: Date?
        public var revoked: Bool

        public var granted: Set<HTTPRight> { Set(rights) }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case readableByOthers(String)
        case unreadable(String)
        case cannotLock(String)
        case noAdmin(String)
        case duplicateName(String)
        case unknownToken(String)
        case revokedToken(String)
        case emptyName

        public var description: String {
            switch self {
            case .readableByOthers(let path):
                return "\(path) may be read by others; chmod 600 it"
            case .unreadable(let path):
                return "cannot read \(path)"
            case .cannotLock(let path):
                return "cannot lock \(path); another byteripper-server may be stuck"
            case .noAdmin(let path):
                return "\(path) holds no admin token: make one with "
                    + "`byteripper-server token add --name admin --rights admin`"
            case .duplicateName(let name):
                return "a token named \(name) is already there"
            case .unknownToken(let id):
                return "no token \(id)"
            case .revokedToken(let id):
                return "token \(id) is revoked"
            case .emptyName:
                return "a token needs a --name"
            }
        }
    }

    private struct Contents: Codable {
        var version: Int
        var tokens: [Token]
    }

    private struct Stamp: Equatable {
        var modified: Date?
        var size: Int
        var inode: UInt64
    }

    /// How often `last_used` may reach the file while the server runs.
    public static let lastUsedInterval: TimeInterval = 60

    public let url: URL
    private let lock = NSLock()
    private var contents = Contents(version: 1, tokens: [])
    private var stamp: Stamp?
    /// A use seen since the last flush, by token id.
    private var pending: [String: Date] = [:]
    private var lastFlush = Date()

    private init(url: URL) {
        self.url = url
    }

    /// Reads the file, or starts an empty store when there is none yet — an
    /// empty store has no admin token, and `Server` refuses to start on it.
    public static func open(at url: URL) throws -> TokenStore {
        let store = TokenStore(url: url)
        try store.load()
        return store
    }

    // MARK: - Reading

    public func all() -> [Token] {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedLocked()
        return contents.tokens
    }

    public var hasAdmin: Bool {
        all().contains { !$0.revoked && $0.granted.contains(.admin) }
    }

    /// The token a secret belongs to, marking it used — the one call every
    /// HTTP request goes through. nil when no live token has that secret.
    public func principal(for secret: String) -> HTTPPrincipal? {
        guard !secret.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedLocked()
        let digest = Self.hash(secret)
        guard let token = contents.tokens.first(where: { !$0.revoked && Self.equal($0.hash, digest) }) else {
            return nil
        }
        pending[token.id] = Date()
        if Date().timeIntervalSince(lastFlush) >= Self.lastUsedInterval {
            try? flushLocked()
        }
        return HTTPPrincipal(id: token.id, name: token.name, rights: token.granted)
    }

    /// Writes what `last_used` has collected. `Server` calls it at stop; the
    /// interval covers a server that runs for days.
    public func flush() throws {
        lock.lock()
        defer { lock.unlock() }
        try flushLocked()
    }

    // MARK: - Changing

    /// A new token and its secret, which is the only time the secret exists
    /// outside the caller. Every token carries `cas.read`
    /// (`Design/SERVER_HEADLESS_PLAN.md` decision 4).
    @discardableResult
    public func add(name: String, rights: Set<HTTPRight>) throws -> (token: Token, secret: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.emptyName }
        let secret = Self.makeSecret()
        var made: Token?
        lock.lock()
        defer { lock.unlock() }
        try writeLocked { tokens in
            guard !tokens.contains(where: { $0.name == name && !$0.revoked }) else {
                throw Failure.duplicateName(name)
            }
            let token = Token(id: Self.makeID(), name: name,
                              hash: Self.hash(secret), rights: Self.sorted(rights.union([.casRead])),
                              created: Date(), lastUsed: nil, revoked: false)
            tokens.append(token)
            made = token
        }
        guard let made else { throw Failure.unreadable(url.path) }
        return (made, secret)
    }

    /// A new secret for a live token; the old one stops working at once.
    @discardableResult
    public func rotate(_ idOrName: String) throws -> String {
        let secret = Self.makeSecret()
        lock.lock()
        defer { lock.unlock() }
        try writeLocked { tokens in
            let index = try Self.index(of: idOrName, in: tokens)
            guard !tokens[index].revoked else { throw Failure.revokedToken(idOrName) }
            tokens[index].hash = Self.hash(secret)
        }
        return secret
    }

    public func revoke(_ idOrName: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try writeLocked { tokens in
            let index = try Self.index(of: idOrName, in: tokens)
            tokens[index].revoked = true
        }
    }

    // MARK: - The file

    private func load() throws {
        lock.lock()
        defer { lock.unlock() }
        try loadLocked()
    }

    private func loadLocked() throws {
        contents = try read()
        stamp = Self.stampOf(url)
    }

    /// A change another process made must reach this one: the stamp is a
    /// modification date, a size and an inode, which a rename or a write
    /// always changes.
    private func reloadIfChangedLocked() {
        guard let current = stamp else {
            if FileManager.default.fileExists(atPath: url.path) { try? loadLocked() }
            return
        }
        guard let now = Self.stampOf(url) else {
            // Deleted under us: an empty store is the honest answer, and the
            // next `Server` start refuses it.
            contents = Contents(version: 1, tokens: [])
            stamp = nil
            return
        }
        if now != current { try? loadLocked() }
    }

    private func read() throws -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Contents(version: 1, tokens: [])
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard mode & 0o077 == 0 else { throw Failure.readableByOthers(url.path) }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url.path) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(Contents.self, from: data) else {
            throw Failure.unreadable(url.path)
        }
        return file
    }

    /// Applies a change to what is on disk now, under the file lock, and
    /// makes this cache the file again. The caller holds `lock`.
    private func writeLocked(_ change: (inout [Token]) throws -> Void) throws {
        let descriptor = try lockFile()
        defer { unlockFile(descriptor) }
        var file = try read()
        try change(&file.tokens)
        try save(file)
        contents = file
        stamp = Self.stampOf(url)
    }

    private func flushLocked() throws {
        guard !pending.isEmpty else { return }
        let times = pending
        pending.removeAll()
        do {
            try writeLocked { tokens in
                for index in tokens.indices {
                    if let used = times[tokens[index].id] { tokens[index].lastUsed = used }
                }
            }
            lastFlush = Date()
        } catch {
            for (id, date) in times { pending[id] = max(date, pending[id] ?? date) }
            throw error
        }
    }

    private func save(_ file: Contents) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The sidecar a rename cannot replace, so two processes lock the same
    /// thing.
    private func lockFile() throws -> Int32 {
        let path = url.path + ".lock"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw Failure.cannotLock(path) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw Failure.cannotLock(path)
        }
        return descriptor
    }

    private func unlockFile(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private static func stampOf(_ url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Stamp(modified: attributes[.modificationDate] as? Date,
                     size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                     inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    // MARK: - Values

    private static func index(of idOrName: String, in tokens: [Token]) throws -> Int {
        if let index = tokens.firstIndex(where: { $0.id == idOrName }) { return index }
        let named = tokens.indices.filter { tokens[$0].name == idOrName && !tokens[$0].revoked }
        guard let index = named.first, named.count == 1 else { throw Failure.unknownToken(idOrName) }
        return index
    }

    private static func sorted(_ rights: Set<HTTPRight>) -> [HTTPRight] {
        rights.sorted { $0.rawValue < $1.rawValue }
    }

    /// 32 random bytes, base64url — the platform's cryptographic generator.
    static func makeSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func makeID() -> String {
        UUID().uuidString.lowercased()
    }

    /// The secret is 32 random bytes, so a slow hash buys nothing; what the
    /// hash buys is that a copied file does not hand over the secrets.
    static func hash(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func equal(_ a: String, _ b: String) -> Bool {
        HTTPBearer.equal(a, b)
    }
}
