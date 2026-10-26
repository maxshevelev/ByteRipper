import Foundation

/// What `GhidraHost` refuses, in the words the client shows.
public struct GhidraHostError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// No Ghidra, no JDK, or a build that failed.
        case install
        /// No project, or the module's bytes do not match.
        case project
        /// The owner did not start, or does not answer.
        case owner
        /// The owner refused a call; `status` is its HTTP status.
        case refused
    }

    public let kind: Kind
    public let status: Int
    public let message: String

    public init(_ kind: Kind, _ message: String, status: Int = 0) {
        self.kind = kind
        self.message = message
        self.status = status
    }

    public var description: String { message }
}

/// A Ghidra installation and the JDK that runs it — what
/// `ghidra_import.find_ghidra` and `ghidra_owner.java_home` find in Python.
public struct GhidraInstall: Equatable, Sendable {
    public let home: URL
    public let version: String
    public let jdk: URL

    public var analyzeHeadless: URL { home.appendingPathComponent("support/analyzeHeadless") }
    public var java: URL { jdk.appendingPathComponent("bin/java") }

    /// The install named, else `GHIDRA_HOME`, else the newest `ghidra_*` in
    /// the usual places; and a JDK 21 or newer.
    public static func find(home explicit: URL? = nil,
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> GhidraInstall {
        let home = try findHome(explicit, environment: environment)
        return GhidraInstall(home: home, version: version(of: home), jdk: try findJDK(environment: environment))
    }

    static func isGhidra(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("support/analyzeHeadless").path)
    }

    static func findHome(_ explicit: URL?, environment: [String: String]) throws -> URL {
        if let explicit {
            guard isGhidra(explicit) else {
                throw GhidraHostError(.install, "\(explicit.path): no support/analyzeHeadless there")
            }
            return explicit
        }
        if let named = environment["GHIDRA_HOME"].map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }),
           isGhidra(named) {
            return named
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [home.appendingPathComponent("Projects/ghidra"), home.appendingPathComponent("ghidra"),
                     URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/opt")]
        var candidates: [URL] = []
        for root in roots {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
            candidates += entries.filter { $0.lastPathComponent.hasPrefix("ghidra_") && isGhidra($0) }
        }
        // The newest by the numbers in the folder's name.
        func numbers(_ url: URL) -> [Int] {
            url.lastPathComponent.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        guard let newest = candidates.max(by: { numbers($0).lexicographicallyPrecedes(numbers($1)) }) else {
            throw GhidraHostError(.install, "no Ghidra found: name its folder, or set GHIDRA_HOME to the folder "
                                  + "that holds support/analyzeHeadless")
        }
        return newest
    }

    static func version(of home: URL) -> String {
        let properties = (try? String(contentsOf: home.appendingPathComponent("Ghidra/application.properties"),
                                      encoding: .utf8)) ?? ""
        for line in properties.split(separator: "\n") where line.hasPrefix("application.version=") {
            return String(line.dropFirst("application.version=".count)).trimmingCharacters(in: .whitespaces)
        }
        return "unknown"
    }

    static func findJDK(environment: [String: String]) throws -> URL {
        if let named = environment["JAVA_HOME"], !named.isEmpty {
            return URL(fileURLWithPath: named)
        }
        let finder = Process()
        finder.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        finder.arguments = ["-v", "21+"]
        let output = Pipe()
        finder.standardOutput = output
        finder.standardError = FileHandle.nullDevice
        do {
            try finder.run()
        } catch {
            throw GhidraHostError(.install, "no JDK 21 or newer: install one, or set JAVA_HOME")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        finder.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard finder.terminationStatus == 0, !path.isEmpty else {
            throw GhidraHostError(.install, "no JDK 21 or newer: install one, or set JAVA_HOME")
        }
        return URL(fileURLWithPath: path)
    }

    /// Every jar of the install, which is the owner's classpath.
    public func classpath() -> [String] {
        let root = home.appendingPathComponent("Ghidra")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var jars: [String] = []
        for case let url as URL in walker
        where url.pathExtension == "jar" && url.deletingLastPathComponent().lastPathComponent == "lib" {
            jars.append(url.path)
        }
        return jars.sorted()
    }
}
