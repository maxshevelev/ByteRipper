import Foundation

/// Owners of this host's projects that no `owner.json` names: one a host
/// started in the seconds before it was stopped, before the owner said it
/// was ready, outlives the host (owners run in their own session) and keeps
/// Ghidra's lock on the project, so every later open fails with
/// `LockException` and nothing shows it as running (issues f9bb8693,
/// d3b03c04). Found by their command line, stopped through their own port.
enum OwnerOrphans {
    struct Orphan: Equatable, Sendable {
        let pid: pid_t
        let module: String
    }

    /// The owners whose `--project-dir` is a project of `projectsRoot`,
    /// read from `ps`, less the ones their project's `owner.json` names.
    static func find(projectsRoot: URL, module: String? = nil) -> [Orphan] {
        let lines = output("/bin/ps", ["-axo", "pid=,command="]) ?? ""
        return parse(lines, projectsRoot: projectsRoot).filter { orphan in
            if let module, orphan.module != module { return false }
            let record = projectsRoot.appendingPathComponent(orphan.module).appendingPathComponent("owner.json")
            guard let data = try? Data(contentsOf: record),
                  let named = try? JSONDecoder().decode(OwnerRecord.self, from: data) else { return true }
            return named.pid != orphan.pid
        }
    }

    /// The owner processes in `ps` lines: `<pid> <command>` with ` Owner `
    /// and `--project-dir <root>/<64 hex>`. The root holds spaces
    /// ("Application Support"), so it is matched as text, not split.
    static func parse(_ lines: String, projectsRoot: URL) -> [Orphan] {
        let marker = "--project-dir " + projectsRoot.standardizedFileURL.path + "/"
        var found: [Orphan] = []
        for line in lines.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.contains(" Owner "), let range = text.range(of: marker),
                  let space = text.firstIndex(of: " "), let pid = pid_t(text[..<space]) else { continue }
            let module = String(text[range.upperBound...].prefix(64))
            guard module.count == 64, module.allSatisfy(\.isHexDigit) else { continue }
            found.append(Orphan(pid: pid, module: module.lowercased()))
        }
        return found
    }

    /// The loopback port the process listens on, from `lsof`.
    static func port(of pid: pid_t) -> Int? {
        let text = output("/usr/sbin/lsof", ["-a", "-nP", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]) ?? ""
        return parsePort(text)
    }

    /// `n127.0.0.1:59255` among `lsof -Fn`'s lines.
    static func parsePort(_ text: String) -> Int? {
        for line in text.split(separator: "\n") where line.hasPrefix("n") {
            if let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) { return port }
        }
        return nil
    }

    /// The processes that have the file open, from `lsof -t`.
    static func holders(of file: URL) -> [pid_t] {
        (output("/usr/sbin/lsof", ["-t", file.path]) ?? "").split(separator: "\n").compactMap { pid_t($0) }
    }

    /// One process's command line, for a message.
    static func command(of pid: pid_t) -> String? {
        output("/bin/ps", ["-p", String(pid), "-o", "command="])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func output(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

extension GhidraHost {
    /// Stops every owner of this host's projects that no `owner.json` names:
    /// asked through its own port to save and stop, killed if it is still
    /// there after `wait` seconds. Answers what was stopped, for the log.
    /// Nothing reached such an owner — no host knew its port — so nothing is
    /// lost with it.
    @discardableResult
    public func stopOrphanOwners(module: String? = nil, wait: TimeInterval = 30) async -> [String] {
        var said: [String] = []
        for orphan in OwnerOrphans.find(projectsRoot: configuration.projectsRoot, module: module) {
            var how = "killed"
            if let port = OwnerOrphans.port(of: orphan.pid),
               (try? await Self.call(port, "POST", "/v1/stop", timeout: 30)) != nil {
                how = "stopped"
            }
            let deadline = Date().addingTimeInterval(wait)
            while Subprocess.isAlive(orphan.pid), Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if Subprocess.isAlive(orphan.pid) {
                kill(orphan.pid, SIGKILL)
                how = "killed"
            }
            said.append("\(how) an owner no record named: pid \(orphan.pid), module \(orphan.module)")
        }
        return said
    }

    /// Why an owner could not take its project's lock, in words: who has
    /// the lock file open, or that nobody does.
    func lockHolders(_ project: GhidraProject) -> String {
        let pids = Set(["module.lock", "module.lock~"].flatMap {
            OwnerOrphans.holders(of: project.folder.appendingPathComponent($0))
        }).sorted()
        guard !pids.isEmpty else {
            return "no process has the lock file open now; try again, and report it if it stays"
        }
        return pids.map { pid in
            "pid \(pid)" + (OwnerOrphans.command(of: pid).map { ": " + String($0.prefix(160)) } ?? "")
        }.joined(separator: "; ")
    }
}
