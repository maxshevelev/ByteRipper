import Foundation

/// The two tables that say which processors stand behind a CPUID: the models
/// (`ProcessorNames`) and the microcode updates that serve several CPUIDs
/// (`MicrocodeSignatures`).
///
/// They are not part of the app. They live in the public repository
/// `github.com/maxshevelev/IntelCPUID`, which the FIT panel reads at run time,
/// so a correction there reaches every bench without a new build; this target
/// has no network, so FITToolUI fetches the files and installs what it read
/// here. Until something is installed — a first run with no network and no
/// copy kept from an earlier one — both are empty, and every CPUID is one the
/// table does not know.
public struct ProcessorTables: Sendable {
    /// The one format this build reads. A file of a newer one is refused, not
    /// guessed at, and the tables in hand are kept.
    public static let formatVersion = 1

    public var families: [ProcessorFamily]
    public var microcode: MicrocodeSignatures

    public init(families: [ProcessorFamily], microcode: MicrocodeSignatures) {
        self.families = families
        self.microcode = microcode
    }

    public static let empty = ProcessorTables(families: [], microcode: MicrocodeSignatures(updates: []))

    public enum DecodeError: Error, Equatable {
        /// The file says it is of a format this build does not read.
        case unsupportedFormat(file: String, version: Int)
        /// The file is not the JSON this build reads.
        case malformed(file: String)
    }

    /// `IntelCPUIDBrandNames.json` and `IntelMicrocodeSignatures.json`, read
    /// together: one that fails is a reason to keep both as they are.
    public static func decode(brandNames: Data, signatures: Data) throws -> ProcessorTables {
        struct Names: Decodable { var formatVersion: Int?; var entries: [ProcessorFamily] }
        struct Signatures: Decodable { var formatVersion: Int?; var updates: [MicrocodeSignatures.Update] }
        let decoder = JSONDecoder()
        guard let names = try? decoder.decode(Names.self, from: brandNames) else {
            throw DecodeError.malformed(file: "IntelCPUIDBrandNames.json")
        }
        guard let shared = try? decoder.decode(Signatures.self, from: signatures) else {
            throw DecodeError.malformed(file: "IntelMicrocodeSignatures.json")
        }
        for (file, version) in [("IntelCPUIDBrandNames.json", names.formatVersion),
                                ("IntelMicrocodeSignatures.json", shared.formatVersion)] {
            guard let version, version <= formatVersion else {
                throw DecodeError.unsupportedFormat(file: file, version: version ?? 0)
            }
        }
        return ProcessorTables(families: names.entries, microcode: MicrocodeSignatures(updates: shared.updates))
    }

    // MARK: - The tables this process uses

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var tables = ProcessorTables.empty
    }
    private static let store = Store()

    /// What the table says now: the last tables installed, or nothing.
    public static var current: ProcessorTables {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.tables
    }

    /// Posted on the main queue after `install`, so a panel showing processor
    /// names can show them again.
    public static let didChange = Notification.Name("ProcessorTablesDidChange")

    /// Makes `tables` the ones every lookup reads from now on.
    public static func install(_ tables: ProcessorTables) {
        store.lock.lock()
        store.tables = tables
        store.lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
