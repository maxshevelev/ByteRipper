import Foundation

/// The folder a workspace lives in: `Workspace.json`, and beside it the bytes
/// of the untitled documents it names.
///
/// Writes only what changed. The app snapshots its windows every few seconds,
/// and almost every snapshot is the one before it; comparing the encoded bytes
/// with the last ones written keeps the disk quiet.
public final class WorkspaceFolder {
    public let url: URL
    private let fileManager: FileManager
    /// What was last written or read, so an identical snapshot is not written
    /// again.
    private var lastWritten: Data?

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public var fileURL: URL { url.appendingPathComponent("Workspace.json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Sorted and indented: the file is small, and a person reading it
        // after a restore went wrong should be able to.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The workspace written last, or nil when there is none, it does not
    /// read, or it is of another version.
    public func read() -> Workspace? {
        guard let data = try? Data(contentsOf: fileURL),
              let workspace = try? Self.decoder.decode(Workspace.self, from: data),
              workspace.version == Workspace.currentVersion else { return nil }
        lastWritten = data
        return workspace
    }

    /// Writes `workspace` unless it is what the file already holds. Returns
    /// whether anything was written.
    @discardableResult
    public func write(_ workspace: Workspace) throws -> Bool {
        let data = try Self.encoder.encode(workspace)
        guard data != lastWritten else { return false }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        lastWritten = data
        return true
    }

    /// Deletes the folder and everything in it: the switch was turned off, and
    /// a workspace from months ago must not come back when it is turned on
    /// again.
    public func remove() {
        try? fileManager.removeItem(at: url)
        lastWritten = nil
    }
}
