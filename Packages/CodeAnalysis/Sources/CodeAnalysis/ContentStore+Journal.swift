import Foundation

/// A publish's journal, in the store's private part: everything one
/// publish will write, put down before the first write, its steps marked
/// as they are done, removed after the last. A publish that stopped part way
/// leaves its journal, and the server finishes it from there.
/// `private/journal/<id>.json`. What a journal says is the host's: the store
/// keeps the bytes.
extension ContentStore {
    var journalURL: URL { privateURL.appendingPathComponent("journal", isDirectory: true) }
    public var publishLockURL: URL { privateURL.appendingPathComponent("publish.lock", isDirectory: false) }

    func journalFile(_ id: String) throws -> URL {
        guard SafeName.isSafe(id) else { throw CodeAnalysisError.invalidName(id) }
        return journalURL.appendingPathComponent("\(id).json", isDirectory: false)
    }

    public func putJournal(id: String, data: Data) throws {
        try atomicWrite(data, to: try journalFile(id))
    }

    /// Every journal the store holds, oldest first by name order of their ids.
    public func journals() throws -> [(id: String, data: Data)] {
        try contents(of: journalURL).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                do {
                    return (url.deletingPathExtension().lastPathComponent, try Data(contentsOf: url))
                } catch {
                    throw CodeAnalysisError.io("\(url.path): \(error)")
                }
            }
    }

    public func deleteJournal(id: String) throws {
        let url = try journalFile(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CodeAnalysisError.io("\(url.path): \(error)")
        }
    }

    /// The lock one publish holds from the registry's decision to its last
    /// step, so two publishes — in this process or another one writing this
    /// store — never interleave their writes. Not the store's own lock: each
    /// step takes that one for itself. Blocks until it is free; the answer is
    /// the descriptor to give `unlockPublishFile`.
    public func lockPublishFile() throws -> Int32 {
        try FileManager.default.createDirectory(at: privateURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(publishLockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw CodeAnalysisError.io("cannot open \(publishLockURL.path): \(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let said = String(cString: strerror(errno))
            close(descriptor)
            throw CodeAnalysisError.io("cannot lock \(publishLockURL.path): \(said)")
        }
        return descriptor
    }

    public func unlockPublishFile(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// The objects an unfinished publish's journal names in its `objects`: a
    /// collection keeps them for the publish to finish with.
    func journalObjects() -> Set<SHA256Digest> {
        struct Named: Decodable { var objects: [SHA256Digest]? }
        let named = ((try? journals()) ?? []).compactMap { try? decoder.decode(Named.self, from: $0.data) }
        return Set(named.flatMap { $0.objects ?? [] })
    }
}
