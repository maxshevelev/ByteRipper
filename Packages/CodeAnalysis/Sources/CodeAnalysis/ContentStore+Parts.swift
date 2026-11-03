import Foundation

/// How an object lies on disk, once the store has been told to keep objects
/// parted (`enablePartedObjects`).
///
/// An object is still named by the SHA-256 of its whole bytes, and `object`
/// still returns exactly those bytes; only the file differs. Every object is a
/// gzip file. An artifact is cut along its JSON: each function and each large
/// section is an object of its own, and the file under the artifact's name
/// holds the text between them and the names of the parts. Two revisions that
/// differ in a few functions then share all the others. Nothing in the JSON is
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
        if let segments = PartedObject.segments(of: data) {
            var names: [PartedObject.Part] = []
            for segment in segments {
                switch segment {
                case .literal(let text):
                    names.append(.literal(text))
                case .part(let bytes):
                    let name = SHA256Digest(data: bytes)
                    if !hasObject(name) { try atomicWrite(try Gzip.compress(bytes), to: objectURL(name)) }
                    names.append(.object(name.hex))
                }
            }
            // Last, so the name of the whole never stands before its parts.
            let root = try PartedObject.encodedRoot(names)
            try atomicWrite(try Gzip.compress(root), to: objectURL(digest))
            return
        }
        try atomicWrite(try Gzip.compress(data), to: objectURL(digest))
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
                    guard let bytes = Gzip.decompress(file) else {
                        throw CodeAnalysisError.objectCorrupt(hex)
                    }
                    whole.append(bytes)
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

    /// The objects a kept object needs besides itself; nothing for one that is
    /// not cut.
    func parts(of digest: SHA256Digest) -> [SHA256Digest] {
        guard let stored = try? Data(contentsOf: objectURL(digest)),
              let inflated = Gzip.decompress(stored),
              let parts = PartedObject.root(of: inflated) else { return [] }
        return parts.compactMap {
            if case .object(let hex) = $0 { return SHA256Digest(hex: hex) }
            return nil
        }
    }
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
    }

    /// What a root starts with. An artifact's own JSON cannot start so.
    private static let rootPrefix = Data(#"{"byteripper_parted":1,"parts":["#.utf8)

    /// A section smaller than this stays in the root: its own file would cost
    /// more than repeating it.
    private static let smallestSection = 1024

    static func encodedRoot(_ parts: [Part]) throws -> Data {
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
        root.append(Data("]}".utf8))
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
            segments.append(.part(Data(bytes[span])))
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
            case .part(let part): whole.append(part)
            }
        }
        return whole == data ? segments : nil
    }

    /// Walks JSON by its structure alone, without building it.
    private struct Scanner {
        let bytes: [UInt8]
        var at = 0

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
