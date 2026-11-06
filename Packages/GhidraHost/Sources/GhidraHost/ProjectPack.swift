import CodeAnalysis
import Foundation

/// A module's kept project as one file, for the store's private part: the
/// Ghidra project, `state.json` and the owner's write counts, without what
/// belongs to one owner's run — its record, its logs, Ghidra's locks and
/// temporary files. The EDK2 archive's path in `state.json` becomes its name:
/// a machine finds its own copy by tag (`GhidraHost.typeArchive(for:)`).
enum ProjectPack {
    /// What is never packed: a running owner's, Ghidra's locks, temporaries.
    static func isKept(_ name: String) -> Bool {
        if name == "owner.json" || name.hasSuffix(".log") { return false }
        if name.hasPrefix("\(GhidraProject.name).lock") { return false }
        if name.hasPrefix("tmp"), name.hasSuffix(".ps") { return false }
        return true
    }

    /// The project folder packed into `zip`, through a staging copy in `scratch`.
    static func pack(_ project: GhidraProject, into zip: URL, scratch: URL) throws {
        let manager = FileManager.default
        let staging = scratch.appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let names = try manager.contentsOfDirectory(atPath: project.folder.path).filter(isKept)
        for name in names {
            // APFS clones a copy: the staging costs no space and no time.
            try manager.copyItem(at: project.folder.appendingPathComponent(name),
                                 to: staging.appendingPathComponent(name))
        }
        let stateURL = staging.appendingPathComponent("state.json")
        var state = try JSONDecoder().decode(ProjectState.self, from: Data(contentsOf: stateURL))
        state.archive = state.archive.map { URL(fileURLWithPath: $0).lastPathComponent }
        try GhidraProject.encoded(state).write(to: stateURL, options: .atomic)
        try? manager.removeItem(at: zip)
        try ditto(["-c", "-k", "--norsrc", staging.path, zip.path])
    }

    /// `zip` unpacked into a new folder `folder`, which must not exist.
    static func unpack(_ zip: URL, into folder: URL) throws {
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw GhidraHostError(.project, "\(folder.path) exists: a kept project is never unpacked over another")
        }
        try ditto(["-x", "-k", zip.path, folder.path])
    }

    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let error = Pipe()
        process.standardError = error
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let said = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GhidraHostError(.project, "ditto \(arguments.joined(separator: " ")): "
                                  + (String(data: said, encoding: .utf8) ?? "status \(process.terminationStatus)"))
        }
    }
}
