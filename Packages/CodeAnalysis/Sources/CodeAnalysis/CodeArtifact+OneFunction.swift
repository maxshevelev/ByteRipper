import Foundation

extension CodeArtifact {
    /// What a function reads as: two readings with one fingerprint look alike
    /// to a reader, whatever else differs. The app's record of what was seen
    /// and a parted artifact's index both hold this.
    public static func fingerprint(name: String, signature: String?, c: String?) -> String {
        SHA256Digest(data: Data("\(name)\u{0}\(signature ?? "")\u{0}\(c ?? "")".utf8)).hex
    }

    /// An artifact read for one function: that function whole, every other one
    /// without its code, and the tables of the analysis as they are. A diff
    /// opens one function, and decoding the code of all the others is most of
    /// the time a whole revision takes to read. The others still name their
    /// entries, so a call on a line of the function leads where it did.
    ///
    /// A function the artifact does not hold is simply not there, as in the
    /// whole artifact. Text that does not read as an artifact's layout is
    /// decoded whole, which reports what is wrong with it.
    public static func decoding(_ data: Data, function entry: CodeAddress) throws -> CodeArtifact {
        let decoder = JSONDecoder()
        guard let reduced = OneFunctionReader(data: data, entry: entry).reduced() else {
            return try decoder.decode(CodeArtifact.self, from: data)
        }
        return try decoder.decode(CodeArtifact.self, from: reduced)
    }
}

/// Walks the JSON of an artifact without decoding it and writes the same text
/// with the code taken out of every function but one. It reads only what it
/// must: where a value ends, and the keys of the functions.
private struct OneFunctionReader {
    let data: Data
    let entry: CodeAddress

    /// What a function keeps out of its code: everything else is short.
    private static let code: Set<[UInt8]> = Set(
        ["c", "c_spans", "c_sites", "c_fields", "c_unreachable", "instructions"].map { Array($0.utf8) })
    private static let functionsKey = Array("functions".utf8)
    private static let entryKey = Array("entry".utf8)

    func reduced() -> Data? {
        data.withUnsafeBytes { raw -> Data? in
            var walk = Walk(bytes: raw.bindMemory(to: UInt8.self))
            return walk.artifact(entry: entry)
        }
    }

    private struct Walk {
        let bytes: UnsafeBufferPointer<UInt8>
        var at = 0

        init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        mutating func artifact(entry: CodeAddress) -> Data? {
            guard consume(0x7B) else { return nil }                 // {
            while true {
                skipSpace()
                guard let key = string() else { return nil }
                guard consume(0x3A) else { return nil }             // :
                skipSpace()
                if bytes[key].elementsEqual(OneFunctionReader.functionsKey) {
                    let start = at
                    guard let functions = functions(entry: entry) else { return nil }
                    var whole = Data(bytes[0..<start])
                    whole.append(contentsOf: functions)
                    whole.append(contentsOf: bytes[at...])
                    return whole
                }
                guard skipValue() else { return nil }
                guard consume(0x2C) else { return nil }             // , — the functions are still to come
            }
        }

        /// The array of functions, each as it is to be decoded.
        private mutating func functions(entry: CodeAddress) -> [UInt8]? {
            guard consume(0x5B) else { return nil }                 // [
            var out: [UInt8] = [0x5B]
            skipSpace()
            if at < bytes.count, bytes[at] == 0x5D {                // ]
                at += 1
                out.append(0x5D)
                return out
            }
            var first = true
            while true {
                if !first { out.append(0x2C) }
                first = false
                guard function(entry: entry, into: &out) else { return nil }
                skipSpace()
                guard at < bytes.count else { return nil }
                let next = bytes[at]
                at += 1
                if next == 0x5D {
                    out.append(0x5D)
                    return out
                }
                guard next == 0x2C else { return nil }
                skipSpace()
            }
        }

        /// One function: the whole text for the one asked for, and for any
        /// other only the members that are not its code.
        private mutating func function(entry: CodeAddress, into out: inout [UInt8]) -> Bool {
            skipSpace()
            let start = at
            guard consume(0x7B) else { return false }
            var kept: [Range<Int>] = []
            var isAsked = false
            skipSpace()
            if at < bytes.count, bytes[at] == 0x7D {                // }
                at += 1
                out.append(contentsOf: bytes[start..<at])
                return true
            }
            while true {
                skipSpace()
                let memberStart = at
                guard let key = string() else { return false }
                guard consume(0x3A) else { return false }
                skipSpace()
                let valueStart = at
                guard skipValue() else { return false }
                if bytes[key].elementsEqual(OneFunctionReader.entryKey), bytes[valueStart] == 0x22 {
                    let text = String(decoding: bytes[(valueStart + 1)..<(at - 1)], as: UTF8.self)
                    isAsked = CodeAddress(hex: text) == entry
                }
                if !OneFunctionReader.code.contains(Array(bytes[key])) { kept.append(memberStart..<at) }
                skipSpace()
                guard at < bytes.count else { return false }
                let next = bytes[at]
                at += 1
                if next == 0x7D { break }
                guard next == 0x2C else { return false }
            }
            if isAsked {
                out.append(contentsOf: bytes[start..<at])
                return true
            }
            out.append(0x7B)
            for (index, member) in kept.enumerated() {
                if index > 0 { out.append(0x2C) }
                out.append(contentsOf: bytes[member])
            }
            out.append(0x7D)
            return true
        }

        private mutating func skipSpace() {
            while at < bytes.count {
                switch bytes[at] {
                case 0x20, 0x0A, 0x0D, 0x09: at += 1
                default: return
                }
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            skipSpace()
            guard at < bytes.count, bytes[at] == byte else { return false }
            at += 1
            return true
        }

        /// Where the contents of the string at `at` lie, quotes off, and `at`
        /// past it.
        private mutating func string() -> Range<Int>? {
            let start = at + 1
            return skipString() ? start..<(at - 1) : nil
        }

        private mutating func skipString() -> Bool {
            guard at < bytes.count, bytes[at] == 0x22, let base = bytes.baseAddress else { return false }
            at += 1
            let start = at
            // `memchr`, not a loop: the C of a function is one long string, and
            // strings are most of what is walked over.
            while at < bytes.count {
                guard let quote = memchr(base + at, 0x22, bytes.count - at) else { return false }
                let index = base.distance(to: quote.assumingMemoryBound(to: UInt8.self))
                var slashes = 0
                while index - slashes > start, bytes[index - slashes - 1] == 0x5C { slashes += 1 }
                at = index + 1
                if slashes % 2 == 0 { return true }
            }
            return false
        }

        /// Past the value at `at`: a string, a number or a word, or an object
        /// or array to its closing bracket.
        private mutating func skipValue() -> Bool {
            guard at < bytes.count else { return false }
            switch bytes[at] {
            case 0x22:
                return skipString()
            case 0x7B, 0x5B:
                var depth = 0
                while at < bytes.count {
                    switch bytes[at] {
                    case 0x22:
                        guard skipString() else { return false }
                        continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 {
                            at += 1
                            return true
                        }
                    default: break
                    }
                    at += 1
                }
                return false
            default:
                while at < bytes.count {
                    switch bytes[at] {
                    case 0x2C, 0x7D, 0x5D, 0x20, 0x0A, 0x0D, 0x09: return true
                    default: at += 1
                    }
                }
                return false
            }
        }
    }
}
