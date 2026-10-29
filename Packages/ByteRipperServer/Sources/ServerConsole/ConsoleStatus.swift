import AgentKit
import Darwin
import DumpHost
import Foundation

/// What the Status page shows about the server itself
/// (`Design/SERVER_HEADLESS_PLAN.md` §8). The server fills it at each ask;
/// the console adds what it holds — the documents, the sessions — and the
/// memory, read at the same moment.
public struct ConsoleStatus: Sendable {
    public var version: String
    public var started: Date
    /// `host:port` of each listener, as bound.
    public var addresses: [String]
    public var serverNames: [String]
    public var roles: [String]
    public var store: String
    public var storeID: String?
    /// The Ghidra the role found — `11.2 at /Applications/ghidra_11.2_PUBLIC`
    /// — or why there is none; nil when Ghidra is not a role of this server.
    public var ghidra: String?
    public var socket: String
    public var tokensFile: String

    public init(version: String, started: Date, addresses: [String], serverNames: [String], roles: [String],
                store: String, storeID: String?, ghidra: String?, socket: String, tokensFile: String) {
        self.version = version
        self.started = started
        self.addresses = addresses
        self.serverNames = serverNames
        self.roles = roles
        self.store = store
        self.storeID = storeID
        self.ghidra = ghidra
        self.socket = socket
        self.tokensFile = tokensFile
    }

    /// The resident memory of this process: what the snapshots, their trees
    /// and what those decompressed cost together (decision 11 measures it,
    /// it does not cap it).
    public static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }

    func json(limits: DumpLimits, sessions: Int, documents: (open: Int, missing: Int, bytes: UInt64)) -> JSONValue {
        var members: [String: JSONValue] = [
            "version": .string(version),
            "started": .string(Console.date(started)),
            "uptime": .count(Int(Date().timeIntervalSince(started))),
            "addresses": .array(addresses.map { .string($0) }),
            "server_names": .array(serverNames.map { .string($0) }),
            "roles": .array(roles.map { .string($0) }),
            "store": .string(store),
            "socket": .string(socket),
            "tokens_file": .string(tokensFile),
            "sessions": .count(sessions),
            "pid": .count(Int(ProcessInfo.processInfo.processIdentifier)),
            "limits": [
                "documents": .count(limits.documents),
                "open_bytes": .uint(limits.openBytes),
                "upload_bytes": .uint(limits.uploadBytes)
            ],
            "documents": [
                "open": .count(documents.open),
                "missing": .count(documents.missing),
                "bytes": .uint(documents.bytes)
            ]
        ]
        if let storeID { members["store_id"] = .string(storeID) }
        if let ghidra { members["ghidra"] = .string(ghidra) }
        if let memory = Self.residentBytes() { members["memory"] = .uint(memory) }
        return .object(members)
    }
}
