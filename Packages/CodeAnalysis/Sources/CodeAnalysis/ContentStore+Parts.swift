import Foundation

/// How an object lies on disk, once the store has been told to keep objects
/// parted (`enablePartedObjects`).
///
/// An object is still named by the SHA-256 of its whole bytes, and `object`
/// still returns exactly those bytes; only the file differs. Every object is a
/// gzip file. An artifact is cut along its JSON: each function and each large
/// section is an object of its own, and the file under the artifact's name
/// holds the text between them, the names of the parts, and an index of the
/// functions: each one without its code, and the part that holds it. Two
/// revisions that differ in a few functions then share all the others, and a
/// reader of one function needs its part and the root. Nothing in the JSON is
/// reformatted: the parts put end to end are the original bytes, or the object
/// is not cut at all.
extension ContentStore {
    private var partedMarkerURL: URL { root.appendingPathComponent("parted-objects") }

    /// Whether new objects are written parted. A build that cannot read parts
    /// may still share an existing store, so this is the store's own switch.
    public var writesPartedObjects: Bool {
        FileManager.default.fileExists(atPath: partedMarkerURL.path)
    }

    public func enablePartedObjects() throws {
        try atomicWrite(Data("1\n".utf8), to: partedMarkerURL)
    }

    /// Writes `data`, named `digest`, in the parted form.
    func writeParted(_ data: Data, digest: SHA256Digest) throws {
        try atomicWrite(try packed(data), to: objectURL(digest))
    }

    /// What the file under the object's name is to hold. An artifact's parts
    /// are written here, so the name of the whole never stands before them.
    private func packed(_ data: Data) throws -> Data {
        if let segments = PartedObject.segments(of: data) {
            var names: [PartedObject.Part] = []
            for segment in segments {
                switch segment {
                case .literal(let text):
                    names.append(.literal(text))
                case .part(let bytes), .function(let bytes):
                    let name = SHA256Digest(data: bytes)
                    if !hasObject(name) { try atomicWrite(try Gzip.compress(bytes), to: objectURL(name)) }
                    names.append(.object(name.hex))
                }
            }
            return try Gzip.compress(try PartedObject.encodedRoot(names, functions: PartedObject.index(of: segments)))
        }
        return try Gzip.compress(data)
    }

    /// Brings every object of the store to the parted form and switches the
    /// store to write it. A dry run does the same in a scratch folder, so the
    /// numbers and the check are the real ones and the store is not touched.
    ///
    /// An object's file is replaced only after what will stand there has been
    /// read back as the same bytes, by one atomic rename, so a run that stops
    /// leaves a store that reads, and a second run goes on from there. The
    /// store is switched only when every object came through. Nothing else may
    /// write the store meanwhile, and every build reading it must know parts.
    public func migrateToPartedObjects(dryRun: Bool = true) throws -> PartedMigrationReport {
        var report = PartedMigrationReport(dryRun: dryRun)
        let scratch = dryRun
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("byteripper-cas-migrate-\(UUID().uuidString)", isDirectory: true)
            : nil
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        let target = try scratch.map { try ContentStore(root: $0) } ?? self
        // A dry run writes nothing here, so it keeps no publish waiting.
        func exclusive(_ body: () throws -> Void) throws {
            if dryRun { try body() } else { try withLock(body) }
        }
        try exclusive {
            for url in contents(of: objectsURL) {
                guard let digest = SHA256Digest(hex: url.lastPathComponent) else {
                    report.problems.append("objects/\(url.lastPathComponent): not a SHA-256 name")
                    continue
                }
                guard let stored = try? Data(contentsOf: url) else {
                    report.problems.append("objects/\(digest.hex): cannot be read")
                    continue
                }
                report.objects += 1
                guard SHA256Digest(data: stored) == digest else {
                    // Not plain: parted by an earlier run, or damaged. A root
                    // written before roots held the index of the functions gets it.
                    do {
                        let whole = try unpacked(stored, digest: digest)
                        report.alreadyParted += 1
                        if let inflated = Gzip.decompress(stored), PartedObject.root(of: inflated) != nil,
                           !PartedObject.hasIndex(inflated) {
                            let file = try target.packed(whole)
                            guard try target.unpacked(file, digest: digest) == whole else {
                                throw CodeAnalysisError.objectCorrupt(digest.hex)
                            }
                            try target.atomicWrite(file, to: target.objectURL(digest))
                            report.indexed += 1
                        }
                    } catch {
                        report.problems.append("objects/\(digest.hex): \(error)")
                    }
                    continue
                }
                report.bytesBefore += stored.count
                do {
                    let file = try target.packed(stored)
                    guard try target.unpacked(file, digest: digest) == stored else {
                        throw CodeAnalysisError.objectCorrupt(digest.hex)
                    }
                    try target.atomicWrite(file, to: target.objectURL(digest))
                    report.parted += 1
                    if !target.parts(of: digest).isEmpty { report.cut += 1 }
                } catch {
                    report.problems.append("objects/\(digest.hex): \(error)")
                }
            }
            for url in target.contents(of: target.objectsURL) {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
                report.filesAfter += 1
                report.bytesAfter += values?.fileSize ?? 0
                report.bytesOnDiskAfter += values?.totalFileAllocatedSize ?? 0
            }
            if report.problems.isEmpty, !dryRun {
                try enablePartedObjects()
                report.switched = true
            }
        }
        return report
    }

    /// The bytes named `digest`, from what its file holds, in any form the
    /// store has written. Throws `objectCorrupt` for a file that is none of
    /// them, and `objectMissing` naming a part that is gone.
    func unpacked(_ stored: Data, digest: SHA256Digest) throws -> Data {
        if SHA256Digest(data: stored) == digest { return stored }
        guard let inflated = Gzip.decompress(stored) else {
            throw CodeAnalysisError.objectCorrupt(digest.hex)
        }
        if let parts = PartedObject.root(of: inflated) {
            var whole = Data()
            for part in parts {
                switch part {
                case .literal(let text):
                    whole.append(contentsOf: text.utf8)
                case .object(let hex):
                    guard let name = SHA256Digest(hex: hex),
                          let file = try? Data(contentsOf: objectURL(name)) else {
                        throw CodeAnalysisError.objectMissing(hex)
                    }
                    // Checked once, as a whole, below.
                    // A part can be an object written plain before the store
                    // was switched: the same bytes happened to exist.
                    whole.append(Gzip.decompress(file) ?? file)
                }
            }
            guard SHA256Digest(data: whole) == digest else {
                throw CodeAnalysisError.objectCorrupt(digest.hex)
            }
            return whole
        }
        guard SHA256Digest(data: inflated) == digest else {
            throw CodeAnalysisError.objectCorrupt(digest.hex)
        }
        return inflated
    }

    /// Takes a cut artifact's root from the source, when there is one to take.
    func fetchRoot(_ digest: SHA256Digest) throws -> Bool {
        guard let partSource, let root = try partSource.root(digest) else { return false }
        guard PartedObject.root(of: root) != nil else { throw CodeAnalysisError.objectCorrupt(digest.hex) }
        try atomicWrite(try Gzip.compress(root), to: objectURL(digest))
        return true
    }

    /// Takes these objects from the source and keeps them.
    func fetchParts(_ names: [SHA256Digest]) throws {
        guard let partSource, !names.isEmpty else { return }
        let files = try partSource.files(names)
        for name in names {
            guard let file = files[name] else { throw CodeAnalysisError.objectMissing(name.hex) }
            try atomicWrite(file, to: objectURL(name))
        }
    }

    /// A revision's code for one function: that function whole, the others as
    /// the root's index has them, the tables of the analysis as they are. What
    /// `CodeArtifact.decoding(_:function:)` makes of the whole, for that part
    /// and the sections alone. A mirror fetches only what it lacks of those.
    public func artifact(_ digest: SHA256Digest, function entry: CodeAddress) throws -> CodeArtifact {
        guard let (parts, functions) = try indexedRoot(of: digest) else {
            return try CodeArtifact.decoding(try object(digest), function: entry)
        }
        let wanted = Set(functions.filter { CodeAddress(hex: $0.entry) == entry }.map(\.part))
        return try reduced(parts, functions, keeping: wanted, marked: false)
    }

    /// An artifact with every function as its index has it and no code at all:
    /// what a Code panel opens on, to read a function's code when it is shown.
    /// Nil for an artifact with no such index, to be read whole.
    public func skeleton(of digest: SHA256Digest) throws -> CodeArtifact? {
        guard let (parts, functions) = try indexedRoot(of: digest) else { return nil }
        return try reduced(parts, functions, keeping: [], marked: true)
    }

    /// The artifact a Code panel shows for a manifest: the index when there is
    /// one, or else the whole, read as `artifact(for:)` reads it.
    public func artifactToShow(for manifest: AnalysisManifest) throws -> CodeArtifact {
        if let skeleton = try skeleton(of: manifest.artifact.sha256) { return skeleton }
        return try artifact(for: manifest)
    }

    /// Functions of a cut artifact, whole, by their entries, or every one for
    /// nil; a mirror fetches what it lacks of them. Throws when the artifact
    /// has no index, or a part is not to be had.
    public func functions(_ entries: Set<CodeAddress>?, of digest: SHA256Digest) throws -> [CodeArtifact.Function] {
        guard let (_, functions) = try indexedRoot(of: digest) else {
            throw CodeAnalysisError.objectMissing(digest.hex)
        }
        let wanted = functions.filter { entry in
            guard let entries else { return true }
            return CodeAddress(hex: entry.entry).map(entries.contains) ?? false
        }
        let names = Array(Set(wanted.compactMap { SHA256Digest(hex: $0.part) }))
        try fetchParts(names.filter { !hasObject($0) })
        let store = self
        let box = FunctionsBox(count: wanted.count)
        DispatchQueue.concurrentPerform(iterations: wanted.count) { index in
            box.set(index, Result {
                guard let name = SHA256Digest(hex: wanted[index].part),
                      let file = try? Data(contentsOf: store.objectURL(name)) else {
                    throw CodeAnalysisError.objectMissing(wanted[index].part)
                }
                return try JSONDecoder().decode(CodeArtifact.Function.self, from: Gzip.decompress(file) ?? file)
            })
        }
        return try box.results()
    }

    private final class FunctionsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [Result<CodeArtifact.Function, Error>?]

        init(count: Int) { all = Array(repeating: nil, count: count) }

        func set(_ index: Int, _ result: Result<CodeArtifact.Function, Error>) {
            lock.lock()
            all[index] = result
            lock.unlock()
        }

        func results() throws -> [CodeArtifact.Function] {
            lock.lock()
            defer { lock.unlock() }
            return try all.compactMap { try $0?.get() }
        }
    }

    /// A cut artifact's root with its index, fetched when a mirror lacks it; nil
    /// for an artifact with no index.
    private func indexedRoot(of digest: SHA256Digest) throws
        -> (parts: [PartedObject.Part], functions: [PartedObject.IndexEntry])? {
        if !hasObject(digest) { _ = try fetchRoot(digest) }
        guard hasObject(digest), let root = try objectRoot(digest),
              let parts = PartedObject.root(of: root),
              let functions = PartedObject.functions(ofRoot: root) else { return nil }
        return (parts, functions)
    }

    /// The artifact's text with the functions outside `wanted` as the index has
    /// them, `marked` saying so to whoever reads it, and the sections in place.
    private func reduced(_ parts: [PartedObject.Part], _ functions: [PartedObject.IndexEntry],
                         keeping wanted: Set<String>, marked: Bool) throws -> CodeArtifact {
        var others: [String: Data] = [:]
        for function in functions where others[function.part] == nil && !wanted.contains(function.part) {
            others[function.part] = try function.json(marked: marked)
        }
        let needed = parts.compactMap { part -> SHA256Digest? in
            guard case .object(let hex) = part, others[hex] == nil else { return nil }
            return SHA256Digest(hex: hex)
        }
        try fetchParts(Array(Set(needed)).filter { !hasObject($0) })
        var reduced = Data()
        for part in parts {
            switch part {
            case .literal(let text):
                reduced.append(contentsOf: text.utf8)
            case .object(let hex):
                if let json = others[hex] {
                    reduced.append(json)
                } else {
                    guard let name = SHA256Digest(hex: hex),
                          let file = try? Data(contentsOf: objectURL(name)) else {
                        throw CodeAnalysisError.objectMissing(hex)
                    }
                    reduced.append(Gzip.decompress(file) ?? file)
                }
            }
        }
        return try JSONDecoder().decode(CodeArtifact.self, from: reduced)
    }

    /// Puts an object in a bundle as this store has it now, fetching nothing.
    /// Whole when it can be; a cut artifact short of parts goes as its root under
    /// `roots/` and the parts it has. A mirror's object it never read stays out.
    func addToBundle(_ digest: SHA256Digest, entries: inout [String: Data]) throws {
        guard hasObject(digest) else {
            if objectSource != nil { return }
            throw CodeAnalysisError.objectMissing(digest.hex)
        }
        let stored = try Data(contentsOf: objectURL(digest))
        if let root = try objectRoot(digest) {
            let names = parts(of: digest)
            if !names.allSatisfy(hasObject) {
                entries["roots/\(digest.hex)"] = root
                for name in names where hasObject(name) {
                    let file = try Data(contentsOf: objectURL(name))
                    entries["objects/\(name.hex)"] = Gzip.decompress(file) ?? file
                }
                return
            }
        }
        entries["objects/\(digest.hex)"] = try unpacked(stored, digest: digest)
    }

    /// Takes a cut artifact from a bundle's `roots/` entry. False when it comes
    /// short of parts and that is not to be accepted, with nothing written.
    func takeRoot(_ root: Data, of digest: SHA256Digest, entries: [String: Data],
                  acceptingPartial: Bool) throws -> Bool {
        guard let parts = PartedObject.root(of: root) else { throw CodeAnalysisError.objectCorrupt(digest.hex) }
        var carried: [SHA256Digest: Data] = [:]
        var complete = true
        var whole = Data()
        for part in parts {
            switch part {
            case .literal(let text):
                whole.append(contentsOf: text.utf8)
            case .object(let hex):
                guard let name = SHA256Digest(hex: hex) else { throw CodeAnalysisError.objectCorrupt(digest.hex) }
                if let bytes = entries["objects/\(hex)"], SHA256Digest(data: bytes) == name {
                    carried[name] = bytes
                    whole.append(bytes)
                } else if complete, let file = try? Data(contentsOf: objectURL(name)) {
                    whole.append(Gzip.decompress(file) ?? file)
                } else {
                    complete = false
                }
            }
        }
        if complete {
            guard SHA256Digest(data: whole) == digest else { throw CodeAnalysisError.objectCorrupt(digest.hex) }
            try putObject(whole)
            return true
        }
        if hasObject(digest), (try? object(digest)) != nil { return true }
        guard acceptingPartial else { return false }
        for (name, bytes) in carried where !hasObject(name) {
            try atomicWrite(try Gzip.compress(bytes), to: objectURL(name))
        }
        if !hasObject(digest) { try atomicWrite(try Gzip.compress(root), to: objectURL(digest)) }
        return true
    }

    /// The file under a cut object's name, inflated: its parts and the index of
    /// its functions, for a reader that wants less than the whole. Nil for an
    /// object that is not cut; throws `objectMissing` for one not here.
    public func objectRoot(_ digest: SHA256Digest) throws -> Data? {
        guard let stored = try? Data(contentsOf: objectURL(digest)) else {
            throw CodeAnalysisError.objectMissing(digest.hex)
        }
        guard let inflated = Gzip.decompress(stored), PartedObject.root(of: inflated) != nil else { return nil }
        return inflated
    }

    /// An object's whole bytes as a gzip file, from its own file when that is
    /// what it holds: what the server sends for a part, compressed only once.
    public func gzippedObject(_ digest: SHA256Digest) throws -> Data {
        guard let stored = try? Data(contentsOf: objectURL(digest)) else {
            throw CodeAnalysisError.objectMissing(digest.hex)
        }
        if let inflated = Gzip.decompress(stored), PartedObject.root(of: inflated) == nil,
           SHA256Digest(data: inflated) == digest {
            return stored
        }
        return try Gzip.compress(try unpacked(stored, digest: digest))
    }

    /// The objects a kept object needs besides itself; nothing for one that is
    /// not cut.
    public func parts(of digest: SHA256Digest) -> [SHA256Digest] {
        guard let stored = try? Data(contentsOf: objectURL(digest)),
              let inflated = Gzip.decompress(stored),
              let parts = PartedObject.root(of: inflated) else { return [] }
        return parts.compactMap {
            if case .object(let hex) = $0 { return SHA256Digest(hex: hex) }
            return nil
        }
    }
}

/// What `migrateToPartedObjects` did, or in a dry run would do.
public struct PartedMigrationReport: Codable, Equatable, Sendable {
    public var dryRun: Bool
    public var objects = 0
    /// Brought to the parted form by this run.
    public var parted = 0
    /// Roots an earlier run wrote without the index of the functions, given it.
    public var indexed = 0
    /// Of those, the artifacts cut into parts.
    public var cut = 0
    public var alreadyParted = 0
    public var bytesBefore = 0
    public var filesAfter = 0
    /// What the object files hold, and what they take on the disk.
    public var bytesAfter = 0
    public var bytesOnDiskAfter = 0
    public var problems: [String] = []
    /// Whether the store now writes the parted form.
    public var switched = false

    public init(dryRun: Bool) { self.dryRun = dryRun }
}

/// The file under a cut artifact's name, and the cutting.
enum PartedObject {
    enum Part: Equatable {
        case literal(String)
        case object(String)
    }

    enum Segment: Equatable {
        case literal(String)
        case part(Data)
        case function(Data)
    }

    /// What a function holds beyond what the index repeats of it.
    private static let code: Set<String> = ["c", "c_spans", "c_sites", "c_fields", "c_unreachable", "instructions"]

    /// One entry per function: the function without its code, the part that
    /// holds it (`part`), and what the reader compares a function by without
    /// reading it (`fingerprint`). Nil when a function does not read as one, so
    /// that no reader takes a short index for the whole list.
    static func index(of segments: [Segment]) -> [Data]? {
        var entries: [Data] = []
        for segment in segments {
            guard case .function(let bytes) = segment else { continue }
            guard var function = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  function["entry"] is String else {
                return nil
            }
            let name = function["name"] as? String ?? ""
            function["part"] = SHA256Digest(data: bytes).hex
            function["fingerprint"] = CodeArtifact.fingerprint(name: name, signature: function["signature"] as? String,
                                                               c: function["c"] as? String)
            for key in code { function[key] = nil }
            guard let entry = try? JSONSerialization.data(withJSONObject: function, options: [.sortedKeys]) else {
                return nil
            }
            entries.append(entry)
        }
        return entries
    }

    /// A root's index: each function's entry, its part, and its own text. Nil
    /// for a root with no usable index.
    static func functions(ofRoot root: Data) -> [IndexEntry]? {
        guard let object = try? JSONSerialization.jsonObject(with: root) as? [String: Any],
              let list = object["functions"] as? [[String: Any]] else { return nil }
        var functions: [IndexEntry] = []
        functions.reserveCapacity(list.count)
        for function in list {
            guard let entry = function["entry"] as? String, let part = function["part"] as? String else {
                return nil
            }
            functions.append(IndexEntry(entry: entry, part: part, fields: function))
        }
        return functions
    }

    /// One function of a root's index.
    struct IndexEntry {
        let entry: String
        let part: String
        let fields: [String: Any]

        /// The entry as the function's text. Unmarked, it reads as a function
        /// cut down by `CodeArtifact.decoding(_:function:)`; marked, it says
        /// its code has yet to come.
        func json(marked: Bool) throws -> Data {
            var fields = fields
            if !marked { fields["fingerprint"] = nil }
            fields["part"] = nil
            return try JSONSerialization.data(withJSONObject: fields)
        }
    }

    /// Whether a root says anything of an index, even that it has none.
    static func hasIndex(_ root: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: root) as? [String: Any])?["functions"] != nil
    }

    /// What a root starts with. An artifact's own JSON cannot start so.
    private static let rootPrefix = Data(#"{"byteripper_parted":1,"parts":["#.utf8)

    /// A section smaller than this stays in the root: its own file would cost
    /// more than repeating it.
    private static let smallestSection = 1024

    /// `functions`, nil for an artifact with no usable index, comes after
    /// `parts`, as a key a reader of parts alone does not look at.
    static func encodedRoot(_ parts: [Part], functions: [Data]?) throws -> Data {
        var root = rootPrefix
        for (index, part) in parts.enumerated() {
            if index > 0 { root.append(UInt8(ascii: ",")) }
            switch part {
            case .literal(let text):
                root.append(try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]))
            case .object(let hex):
                root.append(Data(#"{"sha256":""#.utf8) + Data(hex.utf8) + Data(#""}"#.utf8))
            }
        }
        root.append(Data(#"],"functions":"#.utf8))
        if let functions {
            root.append(UInt8(ascii: "["))
            for (index, entry) in functions.enumerated() {
                if index > 0 { root.append(UInt8(ascii: ",")) }
                root.append(entry)
            }
            root.append(UInt8(ascii: "]"))
        } else {
            root.append(Data("null".utf8))
        }
        root.append(UInt8(ascii: "}"))
        return root
    }

    /// The parts a root names; nil for bytes that are not a root.
    static func root(of data: Data) -> [Part]? {
        guard data.starts(with: rootPrefix),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["parts"] as? [Any] else { return nil }
        var parts: [Part] = []
        parts.reserveCapacity(list.count)
        for item in list {
            if let text = item as? String {
                parts.append(.literal(text))
            } else if let named = item as? [String: String], let hex = named["sha256"] {
                parts.append(.object(hex))
            } else {
                return nil
            }
        }
        return parts
    }

    /// An artifact cut along its JSON; nil for anything else, or when the cut
    /// would not put back the same bytes.
    static func segments(of data: Data) -> [Segment]? {
        let bytes = [UInt8](data)
        var scanner = Scanner(bytes: bytes)
        guard let spans = scanner.artifactSpans(smallestSection: smallestSection) else { return nil }
        var segments: [Segment] = []
        segments.reserveCapacity(spans.count * 2 + 1)
        var cursor = 0
        for span in spans {
            if span.lowerBound > cursor {
                guard let text = String(bytes: bytes[cursor..<span.lowerBound], encoding: .utf8) else { return nil }
                segments.append(.literal(text))
            }
            let part = Data(bytes[span])
            segments.append(scanner.functionSpans.contains(span.lowerBound) ? .function(part) : .part(part))
            cursor = span.upperBound
        }
        if cursor < bytes.count {
            guard let text = String(bytes: bytes[cursor...], encoding: .utf8) else { return nil }
            segments.append(.literal(text))
        }
        var whole = Data()
        whole.reserveCapacity(data.count)
        for segment in segments {
            switch segment {
            case .literal(let text): whole.append(contentsOf: text.utf8)
            case .part(let part), .function(let part): whole.append(part)
            }
        }
        return whole == data ? segments : nil
    }

    /// Walks JSON by its structure alone, without building it.
    private struct Scanner {
        let bytes: [UInt8]
        var at = 0
        /// Where the spans `artifactSpans` found for functions start.
        var functionSpans: Set<Int> = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
        }

        mutating func skipSpace() {
            while at < bytes.count, Self.isSpace(bytes[at]) { at += 1 }
        }

        mutating func skipString() -> Bool {
            guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { return false }
            at += 1
            while at < bytes.count {
                switch bytes[at] {
                case UInt8(ascii: "\\"): at += 2
                case UInt8(ascii: "\""): at += 1; return true
                default: at += 1
                }
            }
            return false
        }

        mutating func skipValue() -> Bool {
            skipSpace()
            guard at < bytes.count else { return false }
            switch bytes[at] {
            case UInt8(ascii: "\""):
                return skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while at < bytes.count {
                    switch bytes[at] {
                    case UInt8(ascii: "\""):
                        guard skipString() else { return false }
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { at += 1; return true }
                    default:
                        break
                    }
                    at += 1
                }
                return false
            default:
                while at < bytes.count, !Self.isSpace(bytes[at]), bytes[at] != UInt8(ascii: ","),
                      bytes[at] != UInt8(ascii: "}"), bytes[at] != UInt8(ascii: "]") { at += 1 }
                return true
            }
        }

        /// Where each function and each large section lies; nil unless this is
        /// an object holding `script_version` and a `functions` list.
        mutating func artifactSpans(smallestSection: Int) -> [Range<Int>]? {
            skipSpace()
            guard at < bytes.count, bytes[at] == UInt8(ascii: "{") else { return nil }
            at += 1
            var spans: [Range<Int>] = []
            var isArtifact = false, hasFunctions = false
            while true {
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: "}") { break }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                let keyStart = at
                guard skipString() else { return nil }
                let key = String(decoding: bytes[(keyStart + 1)..<(at - 1)], as: UTF8.self)
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
                at += 1
                skipSpace()
                if key == "script_version" { isArtifact = true }
                if key == "functions" {
                    guard at < bytes.count, bytes[at] == UInt8(ascii: "[") else { return nil }
                    hasFunctions = true
                    at += 1
                    while true {
                        skipSpace()
                        guard at < bytes.count else { return nil }
                        if bytes[at] == UInt8(ascii: "]") { at += 1; break }
                        if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                        let start = at
                        guard skipValue() else { return nil }
                        spans.append(start..<at)
                        functionSpans.insert(start)
                    }
                } else {
                    let start = at
                    guard skipValue() else { return nil }
                    if at - start >= smallestSection { spans.append(start..<at) }
                }
            }
            return isArtifact && hasFunctions ? spans : nil
        }
    }
}

/// gzip files, with what Foundation has: its `zlib` algorithm is raw DEFLATE,
/// which a gzip file wraps in a header and a trailer. `gzip -d` reads them.
enum Gzip {
    private static let header = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF])

    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var file = header
        file.reserveCapacity(deflated.count + 18)
        file.append(deflated)
        append(crc32(data), to: &file)
        append(UInt32(truncatingIfNeeded: data.count), to: &file)
        return file
    }

    /// The bytes of a gzip file this store wrote; nil for anything else.
    static func decompress(_ file: Data) -> Data? {
        guard file.count >= 18, file.starts(with: header) else { return nil }
        let body = file.subdata(in: (file.startIndex + 10)..<(file.endIndex - 8))
        guard let inflated = try? (body as NSData).decompressed(using: .zlib) as Data else { return nil }
        return inflated
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        crcTable.withUnsafeBufferPointer { table in
            for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
