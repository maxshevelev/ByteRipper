import Foundation

/// One version of a shared review-types archive: the Ghidra archive itself and
/// its two sidecars, as one publish or one withdrawal left them.
public struct TypeArchiveVersion: Codable, Equatable, Sendable {
    /// The files of the version by name — `archive.gdt`, `origin.json`,
    /// `withdrawn.json` — with each one's SHA-256.
    public static let fileNames = ["archive.gdt", "origin.json", "withdrawn.json"]

    public var version: Int
    public var files: [String: SHA256Digest]
    public var at: String
    public var by: String?
    /// The module whose publish or withdrawal made it; nil for the first
    /// version, taken from the archive an earlier server kept beside its projects.
    public var module: SHA256Digest?
    /// The revision of `module` the publish recorded, when it was one.
    public var rev: Int?
    /// What changed: types new to the archive, types that gained a member, a
    /// comment or a real name, types an administrator replaced, and names
    /// taken out.
    public var added: [String]
    public var amended: [String]
    public var taken: [String]
    public var withdrawn: [String]
    public var reason: String?

    public init(version: Int, files: [String: SHA256Digest], at: String, by: String?, module: SHA256Digest?,
                rev: Int?, added: [String] = [], amended: [String] = [], taken: [String] = [],
                withdrawn: [String] = [], reason: String? = nil) {
        self.version = version
        self.files = files
        self.at = at
        self.by = by
        self.module = module
        self.rev = rev
        self.added = added
        self.amended = amended
        self.taken = taken
        self.withdrawn = withdrawn
        self.reason = reason
    }
}

/// `private/types/<bits>/index.json`: every version of one archive, the
/// current one last.
public struct TypeArchiveIndex: Codable, Equatable, Sendable {
    public var bits: String
    public var versions: [TypeArchiveVersion]

    public var current: TypeArchiveVersion? { versions.last }

    public init(bits: String, versions: [TypeArchiveVersion]) {
        self.bits = bits
        self.versions = versions
    }
}

/// The shared review-types archives, one per pointer size, kept by the server
/// in versions: a publish that adds or amends a type makes the next one, and
/// a publish that would replace one is refused before it writes anything. A
/// version is never rewritten; the files beside the projects are a copy of
/// the current one, for the owners to read.
extension ContentStore {
    public static let typeArchiveBits = ["Ia32", "X64"]

    var typesURL: URL { privateURL.appendingPathComponent("types", isDirectory: true) }

    func typeArchiveIndexURL(_ bits: String) -> URL {
        typesURL.appendingPathComponent(bits, isDirectory: true).appendingPathComponent("index.json")
    }

    /// The folder holding one version's files.
    public func typeArchiveFolder(bits: String, version: Int) -> URL {
        typesURL.appendingPathComponent(bits, isDirectory: true).appendingPathComponent(String(version), isDirectory: true)
    }

    func checkBits(_ bits: String) throws {
        guard Self.typeArchiveBits.contains(bits) else {
            throw CodeAnalysisError.invalidName("\(bits) is not a type archive's pointer size: Ia32 or X64")
        }
    }

    /// The archive's versions; nil when the store keeps none of that size.
    public func typeArchive(bits: String) throws -> TypeArchiveIndex? {
        try checkBits(bits)
        let url = typeArchiveIndexURL(bits)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(TypeArchiveIndex.self, from: Data(contentsOf: url))
        } catch {
            throw CodeAnalysisError.io("\(url.path): \(error)")
        }
    }

    /// The version `version` of the archive, its files given as objects of this
    /// store. The files are copied first, the index names them last. Putting the
    /// same version with the same files again changes nothing — a publish
    /// finished from its journal does that — and a version that is not the
    /// next one, or the current one again with other files, is refused.
    @discardableResult
    public func putTypeArchive(bits: String, version: TypeArchiveVersion) throws -> TypeArchiveVersion {
        try checkBits(bits)
        guard Set(version.files.keys) == Set(TypeArchiveVersion.fileNames) else {
            throw CodeAnalysisError.analysisMismatch("a type archive version names "
                + TypeArchiveVersion.fileNames.joined(separator: ", ") + ", and only these")
        }
        var contents: [String: Data] = [:]
        for (name, digest) in version.files {
            contents[name] = try object(digest)
        }
        return try withLock {
            var index = try typeArchive(bits: bits) ?? TypeArchiveIndex(bits: bits, versions: [])
            if let current = index.current {
                if current.version == version.version {
                    guard current.files == version.files else {
                        throw CodeAnalysisError.analysisMismatch(
                            "\(bits) types version \(version.version) is kept already, with other files")
                    }
                    return current
                }
                guard version.version == current.version + 1 else {
                    throw CodeAnalysisError.analysisMismatch(
                        "\(bits) types are at version \(current.version): the next is \(current.version + 1), "
                        + "not \(version.version)")
                }
            } else if version.version != 1 {
                throw CodeAnalysisError.analysisMismatch("the first \(bits) types version is 1, not \(version.version)")
            }
            let folder = typeArchiveFolder(bits: bits, version: version.version)
            for (name, data) in contents {
                try atomicWrite(data, to: folder.appendingPathComponent(name))
            }
            index.versions.append(version)
            try atomicWrite(try encoder.encode(index), to: typeArchiveIndexURL(bits))
            return version
        }
    }

    /// What is wrong with the kept archives: an index that cannot be read,
    /// versions out of order, a file missing or not the one the index names.
    func verifyTypeArchives() -> [String] {
        var problems: [String] = []
        for bits in Self.typeArchiveBits {
            let name = "private/types/\(bits)"
            let index: TypeArchiveIndex?
            do {
                index = try typeArchive(bits: bits)
            } catch {
                problems.append("\(name): index.json cannot be read")
                continue
            }
            guard let index else { continue }
            for (place, version) in index.versions.enumerated() {
                if version.version != place + 1 {
                    problems.append("\(name): version \(version.version) stands at place \(place + 1)")
                }
                let folder = typeArchiveFolder(bits: bits, version: version.version)
                for (file, digest) in version.files.sorted(by: { $0.key < $1.key }) {
                    guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else {
                        problems.append("\(name)/\(version.version)/\(file): cannot be read")
                        continue
                    }
                    if SHA256Digest(data: data) != digest {
                        problems.append("\(name)/\(version.version)/\(file): not the file index.json names")
                    }
                }
            }
        }
        return problems
    }
}
