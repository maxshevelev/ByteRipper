import Darwin
import Foundation

/// Where the owner's Java comes from, and where it is built.
public struct OwnerSources: Equatable, Sendable {
    /// `Owner.java`, `Harvest.java`, `TypeText.java` and `ExportCode.java`.
    public let files: [URL]
    /// The folder of the Ghidra scripts `analyzeHeadless` runs —
    /// `ApplyUefi.java`, `ExportCode.java`, `BuildUefiTypes.java`.
    public let scripts: URL

    public init(files: [URL], scripts: URL) {
        self.files = files
        self.scripts = scripts
    }

    /// The skill in a checkout of the repository: `Skills/ghidra-uefi`.
    public static func skill(at root: URL) -> OwnerSources {
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        let owner = root.appendingPathComponent("owner", isDirectory: true)
        return OwnerSources(files: [owner.appendingPathComponent("Owner.java"),
                                    owner.appendingPathComponent("Harvest.java"),
                                    owner.appendingPathComponent("TypeText.java"),
                                    scripts.appendingPathComponent("ExportCode.java")],
                            scripts: scripts)
    }

    /// The skill of the checkout this package was built from — a server built
    /// from the repository on the machine that runs it.
    public static var checkout: OwnerSources {
        skill(at: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GhidraHost
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // GhidraHost package
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // the repository
            .appendingPathComponent("Skills/ghidra-uefi", isDirectory: true))
    }
}

/// The owner compiled for one Ghidra: a jar built with `javac` against the
/// install's jars, again whenever a source is newer than it. A jar built for
/// one Ghidra does not load in another, so each install has its own; the
/// folder is shared by every owner, and an existing build is reused.
enum OwnerBuild {
    static func cache(for install: GhidraInstall) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ByteRipper/ghidra-owner", isDirectory: true)
            .appendingPathComponent(install.home.lastPathComponent, isDirectory: true)
    }

    /// The build an owner reports in its `hello`: the jar's modification
    /// time in whole seconds, after building it again if a source is newer.
    static func build(for install: GhidraInstall, sources: OwnerSources) throws -> Int {
        let jar = try jar(for: install, sources: sources)
        return Int((modified(jar) ?? .distantPast).timeIntervalSince1970)
    }

    static func jar(for install: GhidraInstall, sources: OwnerSources) throws -> URL {
        let folder = cache(for: install)
        let jar = folder.appendingPathComponent("owner.jar")
        let newest = sources.files.compactMap(modified).max() ?? .distantFuture
        if let built = modified(jar), built >= newest { return jar }
        for file in sources.files where !FileManager.default.fileExists(atPath: file.path) {
            throw GhidraHostError(.install, "\(file.path): the owner's source is missing")
        }
        let classes = folder.appendingPathComponent("classes", isDirectory: true)
        try? FileManager.default.removeItem(at: classes)
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("build.log")
        let javac = install.jdk.appendingPathComponent("bin/javac")
        let status = try Subprocess.run(javac, ["-proc:none", "-nowarn", "-encoding", "UTF-8",
                                                "-d", classes.path,
                                                "-cp", install.classpath().joined(separator: ":")]
                                        + sources.files.map(\.path), log: log, timeout: 600)
        guard status == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw GhidraHostError(.install, "javac failed:\n" + String(text.suffix(3000)))
        }
        let archive = try Subprocess.run(install.jdk.appendingPathComponent("bin/jar"),
                                         ["cf", jar.path, "-C", classes.path, "."], log: log, timeout: 120)
        guard archive == 0 else { throw GhidraHostError(.install, "jar failed; log: \(log.path)") }
        return jar
    }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Starting a program with its output in a log file.
enum Subprocess {
    /// Whether a process is still running. An owner this host started and
    /// that has exited — on its idle timeout — stays a zombie until reaped,
    /// and a zombie answers `kill(pid, 0)` as if it lived: it is reaped here
    /// first, so it reads as gone and not as an owner too busy to answer.
    static func isAlive(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        return kill(pid, 0) == 0
    }

    /// Runs to the end, or is killed after `timeout`; the exit status.
    static func run(_ executable: URL, _ arguments: [String], log: URL, timeout: TimeInterval,
                    environment: [String: String]? = nil) throws -> Int32 {
        let process = try spawn(executable, arguments, log: log, environment: environment, ownSession: false)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw GhidraHostError(.install, "\(executable.lastPathComponent) did not finish within "
                                      + "\(Int(timeout)) s; log: \(log.path)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return process.status
    }

    /// A running program. With `ownSession` it is the leader of a session of
    /// its own, so the server's Ctrl-C or its exit does not reach it: an
    /// owner saves and exits on its own terms.
    static func spawn(_ executable: URL, _ arguments: [String], log: URL,
                      environment: [String: String]? = nil, ownSession: Bool) throws -> Spawned {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        if ownSession {
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let variables = (environment ?? ProcessInfo.processInfo.environment)
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { variables.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, variables)
        guard result == 0 else {
            throw GhidraHostError(.install, "cannot start \(executable.path): \(String(cString: strerror(result)))")
        }
        return Spawned(pid: pid)
    }
}

/// A process `Subprocess.spawn` started.
final class Spawned: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var exitStatus: Int32?

    init(pid: pid_t) { self.pid = pid }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        if exitStatus != nil { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            exitStatus = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            return false
        }
        return result == 0
    }

    var status: Int32 {
        _ = isRunning
        lock.lock()
        defer { lock.unlock() }
        return exitStatus ?? -1
    }

    func terminate() { kill(pid, SIGTERM) }
}
