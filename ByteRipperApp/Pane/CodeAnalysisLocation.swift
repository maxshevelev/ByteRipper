import CodeAnalysis
import Foundation
import Localization
import UEFIToolUI

/// Where the app keeps its code analyses: on this Mac, or on a
/// `byteripper-server` in the person's network, read through a mirror on this
/// Mac (`Design/SERVER_PLAN.md` §5). The choice is the Code analysis tab's.
///
/// Everything that reads the store reads `UEFIToolModule.codeAnalysisRoot`;
/// this only points it at the local store or at the mirror, and keeps the
/// mirror current by following the server's change feed. The mirror is
/// readable while the server is out of reach — what it fetched stays — so a
/// lost connection costs the new analyses, never the ones already seen.
@MainActor
final class CodeAnalysisLocation {
    static let shared = CodeAnalysisLocation()

    /// The store on this Mac, the folder of the mirrors and the token file:
    /// the app's own, or a test's.
    let localRoot: URL
    let mirrorsRoot: URL
    let tokenFile: URL

    init(localRoot: URL = CodeAnalysisPaths.defaultRoot,
         mirrorsRoot: URL = CodeAnalysisPaths.mirrorsRoot,
         tokenFile: URL = CodeAnalysisLocation.defaultTokenFile) {
        self.localRoot = localRoot
        self.mirrorsRoot = mirrorsRoot
        self.tokenFile = tokenFile
    }

    /// Posted when `state` changes, for the Settings tab.
    static let didChange = Notification.Name("CodeAnalysisLocationDidChange")

    enum Mode: String {
        case thisMac
        case server
    }

    enum State: Equatable {
        /// The local store.
        case local
        /// Reaching the server; the mirror it last copied, if any, is read.
        case connecting
        /// The mirror follows the server.
        case connected(store: String)
        /// The server answered and will not serve this Mac's token: it does
        /// not know it, or the token lacks a right. The reason names which
        /// (`Design/SERVER_HEADLESS_PLAN.md` decision 4).
        case refused(reason: String)
        /// The server is out of reach; the mirror is read as it is.
        case unreachable(reason: String)
    }

    private static let modeKey = "CodeAnalysisLocation"
    private static let serverKey = "CodeAnalysisServer"
    private static let storeKey = "CodeAnalysisServerStore"

    private(set) var state: State = .local {
        didSet {
            guard state != oldValue else { return }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var mode: Mode {
        Mode(rawValue: AppDefaults.store.string(forKey: Self.modeKey) ?? "") ?? .thisMac
    }

    /// The server, `http://host:port`, as the person typed it.
    var serverAddress: String {
        AppDefaults.store.string(forKey: Self.serverKey) ?? ""
    }

    /// The token is a file, the one `byteripper-cas` and the skill's scripts
    /// read on this Mac too, not a keychain item: one token per Mac for every
    /// client, and a keychain item would ask again after every update of an
    /// app signed ad hoc.
    nonisolated static var defaultTokenFile: URL {
        CodeAnalysisPaths.defaultRoot.deletingLastPathComponent()
            .appendingPathComponent("Server/token", isDirectory: false)
    }

    /// The client of the server, while the analyses are kept there: what a
    /// write — a project's bundle, a project's reference — goes to.
    private(set) var remote: RemoteStore?
    private(set) var mirror: StoreMirror?
    private var following: Task<Void, Never>?

    /// Applies the stored choice; at launch, and after the tab changes it.
    func apply() {
        following?.cancel()
        following = nil
        remote = nil
        mirror = nil
        guard mode == .server, let url = Self.serverURL(serverAddress) else {
            state = .local
            UEFIToolModule.codeAnalysisRoot = localRoot
            return
        }
        let remote = RemoteStore(base: url, token: try? readToken())
        let mirror = StoreMirror(remote: remote, mirrorsRoot: mirrorsRoot)
        self.remote = remote
        self.mirror = mirror
        state = .connecting
        // The mirror of the store this Mac last copied is read at once, so
        // the badges do not wait on the network — or on a server that is off.
        if let storeID = AppDefaults.store.string(forKey: Self.storeKey) {
            UEFIToolModule.codeAnalysisRoot = StoreMirror.root(of: storeID, in: mirrorsRoot)
        }
        // Every address asks for a token, loopback included (decision 3):
        // without one there is nothing to try, and "the server does not
        // accept the token" would send the reader looking for a wrong one.
        guard let token = try? readToken(), !token.isEmpty else {
            state = .refused(reason: L("This Mac keeps no token for the server: enter the one made on the server by byteripper-server token add."))
            return
        }
        following = Task { [weak self] in await self?.follow(mirror) }
    }

    /// Choose where the analyses are kept, and keep the choice.
    func choose(_ mode: Mode, server: String, token: String?) throws {
        if mode == .server {
            guard Self.serverURL(server) != nil else {
                throw RemoteStore.Failure.unexpected(L("The server's address is not of the form http://host:port."))
            }
            if let token, !token.isEmpty { try writeToken(token) }
        }
        AppDefaults.store.set(mode.rawValue, forKey: Self.modeKey)
        AppDefaults.store.set(server.trimmingCharacters(in: .whitespaces), forKey: Self.serverKey)
        apply()
    }

    /// Connect, then follow the feed; on a failure wait, longer each time up
    /// to a minute, and connect again.
    private func follow(_ mirror: StoreMirror) async {
        var pause: UInt64 = 2
        while !Task.isCancelled {
            do {
                let store = try await mirror.connect()
                guard !Task.isCancelled else { return }
                let storeID = store.root.lastPathComponent
                AppDefaults.store.set(storeID, forKey: Self.storeKey)
                UEFIToolModule.codeAnalysisRoot = store.root
                state = .connected(store: storeID)
                try? await mirror.collectGarbage()
                pause = 2
                while !Task.isCancelled {
                    try await mirror.follow(wait: 25)
                }
            } catch {
                guard !Task.isCancelled else { return }
                state = Self.state(for: error)
                try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
                pause = min(pause * 2, 60)
            }
        }
    }

    // MARK: - Writes

    /// A reference name unique to this Mac, so the server's `gc` knows what
    /// every Mac's projects use and two Macs never overwrite each other's.
    nonisolated static func serverRefName(_ name: String) -> String {
        let host = (Host.current().localizedName ?? "mac").unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x2D: return Character(scalar)
            default: return "-"
            }
        }
        return String(host) + "." + name
    }

    /// Send a project's bundle to the server, then copy what it now holds of
    /// the bundle's modules; the answer is the server's report.
    func sendBundle(at url: URL) async throws -> BundleImport? {
        guard let remote, let mirror else { return nil }
        let data = try Data(contentsOf: url)
        let report = try await remote.importBundle(data)
        let modules = (report.imported + report.unchanged).map(\.module.sha256)
            + (report.skipped + report.conflicts).compactMap { AnalysisKey($0.key)?.module }
        try await mirror.refresh(modules)
        return report
    }

    /// What the tab says about a failed connection: a token the server
    /// refuses is not a server out of reach, and a 403 names the right the
    /// token lacks (`Design/SERVER_HEADLESS_PLAN.md` decision 4).
    nonisolated static func state(for error: Error) -> State {
        if case .refused(let status, _, _)? = error as? RemoteStore.Failure, status == 401 || status == 403 {
            return .refused(reason: describe(error))
        }
        return .unreachable(reason: describe(error))
    }

    /// Why the server did not serve this Mac, in the words of the tab.
    nonisolated static func describe(_ error: Error) -> String {
        switch error as? RemoteStore.Failure {
        case .refused(status: 401, _, _):
            return L("The server does not accept the token.")
        case .refused(status: 403, _, let rights) where rights.count == 1:
            return L("The token lacks the %1$@ right.", rights[0])
        case .refused(status: 403, _, let rights) where rights.count > 1:
            return L("The token lacks the rights %1$@.", rights.joined(separator: ", "))
        case .refused(_, let message, _):
            return message
        case .unreachable(let reason):
            // The system's own words say which: the name did not resolve,
            // nothing listens there, the connection timed out, or the app's
            // transport security refused plain HTTP to that host.
            return L("The server does not answer: %1$@", reason)
        case .unexpected:
            return L("The server is not an analysis server of this version.")
        case nil:
            return error.localizedDescription
        }
    }

    // MARK: - The address and the token

    nonisolated static func serverURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func readToken() throws -> String? {
        guard FileManager.default.fileExists(atPath: tokenFile.path) else { return nil }
        return try String(contentsOf: tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Written 0600 in a folder only this user may enter.
    func writeToken(_ token: String) throws {
        let folder = tokenFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: tokenFile.path) {
            FileManager.default.createFile(atPath: tokenFile.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        try Data((token.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8).write(to: tokenFile)
    }
}
