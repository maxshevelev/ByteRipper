import CryptoKit
import Foundation
import ToolModuleKit
import UEFIContentSource
import UEFIImage

/// One open document: its snapshot, the tree read from it, and what an agent
/// knows it by (`Design/SERVER_HEADLESS_PLAN.md` §6).
///
/// A read host and nothing else — no session, no panel, no edits. The tree
/// lives with the document and is built the first time a tool asks for it;
/// a Reopen replaces snapshot and tree, never the tree under an agent while
/// it reads.
@MainActor
public final class DocumentHost: ToolReadHost, UEFITreeProviding {
    public let id: String
    /// What the console and an agent call it: the file's name, or the name an
    /// upload was given.
    public let name: String
    public let url: URL
    public private(set) var bytes: SnapshotReader
    /// The SHA-256 of the snapshot, in hex.
    public private(set) var sha256: String
    /// Raised by every Reopen, and by a restore that found other bytes: an
    /// agent's node ids from before are not silently read against new ones.
    public private(set) var version: Int
    /// The `stat` taken before the snapshot was read.
    public private(set) var stamp: FileStamp
    private var tree: LazyUEFITree?
    private var openRows: Set<NodeID> = []

    init(id: String, name: String, url: URL, data: Data, stamp: FileStamp, version: Int) {
        self.id = id
        self.name = name
        self.url = url
        self.bytes = SnapshotReader(data)
        self.sha256 = Self.hash(data)
        self.stamp = stamp
        self.version = version
    }

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Takes new bytes under the same id, one version on.
    func replace(data: Data, stamp: FileStamp) {
        bytes = SnapshotReader(data)
        sha256 = Self.hash(data)
        self.stamp = stamp
        version += 1
        tree = nil
        openRows = []
    }

    /// The file against the one read: nil while it is the same, `changed`
    /// when it is another, `gone` when the `stat` fails. A `stat` costs
    /// microseconds, so it is taken on every call that names the document.
    public func diskState() -> DiskState? {
        guard let now = FileStamp.of(url) else { return .gone }
        return now == stamp ? nil : .changed
    }

    // MARK: - ToolReadHost

    public var fileName: String { name }
    public var contentSize: UInt64 { bytes.size }

    public func read(_ range: Range<UInt64>) throws -> [UInt8] {
        try bytes.read(range)
    }

    public func snapshot() throws -> any ToolContentReader { bytes }

    public var contentVersion: AnyHashable? { version }

    // MARK: - UEFITreeProviding

    public func uefiTree() -> LazyUEFITree? {
        if let tree { return tree }
        guard bytes.size > 0 else { return nil }
        let built = LazyUEFITree(ToolContentByteSource(reader: bytes))
        tree = built
        return built
    }

    public func openUEFIRows() -> Set<NodeID> { openRows }
    public func setOpenUEFIRows(_ rows: Set<NodeID>) { openRows = rows }
}
