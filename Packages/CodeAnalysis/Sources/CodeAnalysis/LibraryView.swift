import Foundation

/// A library function has one description, and it is the registry's: its name,
/// its signature, its C with the comments in it. A module holds the code, at
/// its own addresses; it holds no description of a function the registry has.
/// This is how a reader gets one: the function as the module publishes it, with
/// everything that describes it taken from the entry.
///
/// What stays the module's is what is the module's: where the function is, who
/// calls it, its instructions. In the entry's C, what a token names is carried
/// over by the instruction that refers to it, since the same body refers to the
/// same things in the same places, and is printed by this module's name for it.
public enum LibraryView {
    /// The fields of an entry object a reader needs.
    public struct Entry: Sendable {
        public let id: String
        public let version: Int
        public let name: String
        public let kind: LibraryKind?
        public let signature: String?
        /// The function as the entry's own version was published; nil for an
        /// entry from before the entries held it.
        public let function: CodeArtifact.Function?

        public init?(object: Data, id: String, version: Int) {
            guard let fields = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any],
                  let name = fields["name"] as? String else { return nil }
            self.id = id
            self.version = version
            self.name = name
            kind = (fields["kind"] as? String).flatMap(LibraryKind.init(rawValue:))
            signature = fields["signature"] as? String
            function = fields["function"].flatMap { value -> CodeArtifact.Function? in
                guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                return try? JSONDecoder().decode(CodeArtifact.Function.self, from: data)
            }
        }
    }

    /// The registry's entry for a function: by its body, or by the mark of an
    /// artifact from before functions recorded their bodies. A thunk and an
    /// external have no body to match.
    public static func entryID(of function: CodeArtifact.Function, in index: LibraryIndex) -> String? {
        guard !function.external, !function.thunk else { return nil }
        if let body = function.body, index.takenOut?[body] != nil { return nil }
        if let body = function.body, let id = index.bodies[body] { return id }
        if let id = function.libraryEntry?.id, index.entries[id] != nil { return id }
        return nil
    }

    /// The function as a reader sees it. `name` is this module's name for an
    /// address, nil when it has none.
    public static func function(_ local: CodeArtifact.Function, entry: Entry,
                                name: (CodeAddress) -> String?,
                                string: (CodeAddress) -> String? = { _ in nil }) -> CodeArtifact.Function {
        var function = local
        function.name = entry.name
        function.signature = entry.function?.signature ?? entry.signature ?? local.signature
        function.nameSource = "USER_DEFINED"
        function.nameReason = "library registry entry \(entry.id)"
        function.reviewLevel = .library
        function.reviewGaps = []
        function.libraryKind = entry.kind ?? local.libraryKind
        function.libraryEntry = .init(id: entry.id, version: entry.version, codes: local.libraryEntry?.codes ?? [],
                                      state: local.libraryEntry?.state, differences: local.libraryEntry?.differences ?? [],
                                      base: local.libraryEntry?.base)
        guard let source = entry.function, source.c != nil, !local.codeIsPending else { return function }
        let carried = carriedOver(from: source, to: local)
        let rendered = render(source, carried: carried, name: name, string: string)
        function.c = rendered.c
        function.cSpans = rendered.spans
        function.cSites = rendered.sites
        function.cFields = rendered.fields
        function.cUnreachable = rendered.unreachable
        function.textFromRegistry = true
        function.publisherAddresses = rendered.publisherAddresses
        return function
    }

    /// Where each address of the entry's function is in this module's: an
    /// instruction by its place, what it refers to by the same reference of the
    /// same instruction. References pair within their type, in order, and only
    /// where the instruction has as many of that type on both sides: a project
    /// may hold a reference more on one side, which says nothing of the others.
    /// An address that would land in two places lands in neither: a lost link
    /// is better than a wrong one. Another body of the function has its own
    /// addresses: its C reads the same, and only the function's own entry can
    /// be linked, rather than a place that is not it.
    static func carriedOver(from source: CodeArtifact.Function,
                            to local: CodeArtifact.Function) -> [CodeAddress: CodeAddress] {
        var map: [CodeAddress: CodeAddress] = [source.entry: local.entry]
        guard source.instructions.count == local.instructions.count else { return map }
        var contested = Set<CodeAddress>()
        func carry(_ from: CodeAddress, _ to: CodeAddress) {
            if let held = map[from], held != to { contested.insert(from) } else { map[from] = to }
        }
        for (theirs, ours) in zip(source.instructions, local.instructions) {
            carry(theirs.address, ours.address)
            let own = Dictionary(grouping: ours.references, by: \.type)
            for (type, references) in Dictionary(grouping: theirs.references, by: \.type) {
                guard let others = own[type], others.count == references.count else { continue }
                for (from, to) in zip(references, others) { carry(from.to, to.to) }
            }
        }
        for address in contested where address != source.entry { map[address] = nil }
        return map
    }

    struct Rendered {
        var c: String
        var spans: [CodeArtifact.CSpan]
        var sites: [CodeArtifact.CSite]
        var fields: [CodeArtifact.CField]
        var unreachable: CodeArtifact.CUnreachable?
        /// Text that still carries the address of the module the entry was
        /// published from, because no place for it here could be shown.
        var publisherAddresses: [String] = []
    }

    /// The hex a generated name ends in, when it is `address`: `DAT_09dffb74`,
    /// `s_Success_09dffb80`.
    static func addressSuffix(of token: String, _ address: CodeAddress) -> Range<String.Index>? {
        let hex = String(address.value, radix: 16)
        let width = max(8, hex.count)
        let suffix = String(repeating: "0", count: width - hex.count) + hex
        guard token.hasSuffix(suffix), token.count > width else { return nil }
        return token.index(token.endIndex, offsetBy: -width)..<token.endIndex
    }

    static func hex(_ address: CodeAddress, width: Int) -> String? {
        let hex = String(address.value, radix: 16)
        guard hex.count <= width else { return nil }
        return String(repeating: "0", count: width - hex.count) + hex
    }

    /// Whether a name generated for a string can be this string: Ghidra's name
    /// is the text's start with its separators changed.
    static func name(_ stem: String, reads text: String) -> Bool {
        func letters(_ value: String) -> String { value.filter { $0.isLetter || $0.isNumber } }
        var stem = stem
        for prefix in ["s_", "u_"] where stem.hasPrefix(prefix) { stem.removeFirst(prefix.count) }
        let wanted = letters(stem)
        return !wanted.isEmpty && letters(text).hasPrefix(wanted)
    }

    /// `LAB_09dfd43f` and `(ram,0x09dfdf33)` are the publisher's instructions
    /// in plain text: this module's address is as long, so no position moves.
    static func rewriteCodeAddresses(in units: inout [UInt16], carried: [CodeAddress: CodeAddress],
                                     unmapped: inout [String]) {
        let text = String(decoding: units, as: UTF16.self)
        guard let pattern = try? NSRegularExpression(pattern: #"\bLAB_([0-9a-f]{8})\b|\(ram,0x([0-9a-f]+)\)"#) else { return }
        let whole = NSRange(location: 0, length: units.count)
        for match in pattern.matches(in: text, range: whole) {
            let group = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let found = String(decoding: units[group.location..<(group.location + group.length)], as: UTF16.self)
            if let address = CodeAddress(hex: "0x" + found), let place = carried[address],
               let written = hex(place, width: group.length) {
                units.replaceSubrange(group.location..<(group.location + group.length), with: Array(written.utf16))
            } else {
                unmapped.append(String(decoding: units[match.range.location..<(match.range.location + match.range.length)],
                                       as: UTF16.self))
            }
        }
    }

    /// The entry's C, with what a token names being this module's: its address,
    /// and its name where the module has one. A target with no place here
    /// loses the link rather than lead somewhere wrong.
    static func render(_ source: CodeArtifact.Function, carried: [CodeAddress: CodeAddress],
                       name: (CodeAddress) -> String?,
                       string: (CodeAddress) -> String? = { _ in nil }) -> Rendered {
        let units = Array((source.c ?? "").utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var cursor = 0
        var spans: [CodeArtifact.CSpan] = []
        // Source position → how far the text after it has moved.
        var moves: [(at: Int, by: Int)] = []
        func moved(_ position: Int) -> Int {
            position + (moves.last(where: { $0.at <= position })?.by ?? 0)
        }
        var unmapped: [String] = []
        // What the entry's data is here, for a datum no instruction refers to:
        // one reached through a table has no reference of its own to carry.
        let data = source.cSpans.compactMap { span -> (theirs: CodeAddress, ours: CodeAddress)? in
            guard span.kind == .global, let theirs = span.target, let ours = carried[theirs] else { return nil }
            return (theirs, ours)
        }.sorted { $0.theirs < $1.theirs }
        for span in source.cSpans.sorted(by: { $0.start < $1.start }) {
            guard span.start >= cursor, span.start + span.length <= units.count else { continue }
            out += units[cursor..<span.start]
            cursor = span.start
            var target = span.target.flatMap { carried[$0] }
            let token = Array(units[span.start..<(span.start + span.length)])
            var written = token
            if span.kind == .function || span.kind == .global, let target, let own = name(target), !own.isEmpty {
                written = Array(own.utf16)
            } else if span.kind == .global, let theirs = span.target {
                let text = String(decoding: token, as: UTF16.self)
                if let suffix = addressSuffix(of: text, theirs) {
                    let width = text.distance(from: suffix.lowerBound, to: suffix.upperBound)
                    // The nearest data before it, the same distance on: a table
                    // keeps its layout, an image moves it. Only a string here
                    // that reads as the name makes that the place.
                    if target == nil, let before = data.last(where: { $0.theirs < theirs }),
                       let place = CodeAddress(hex: "0x" + String(before.ours.value &+ (theirs.value &- before.theirs.value), radix: 16)),
                       let held = string(place), Self.name(String(text[..<suffix.lowerBound]), reads: held) {
                        target = place
                    }
                    if let target, let own = hex(target, width: width) {
                        written = Array((text[..<suffix.lowerBound] + own).utf16)
                    } else {
                        unmapped.append(text)
                    }
                }
            }
            let start = out.count
            out += written
            cursor = span.start + span.length
            moves.append((at: cursor, by: out.count - cursor))
            spans.append(.init(start: start, length: written.count, kind: span.kind, target: target))
        }
        out += units[min(cursor, units.count)...]
        rewriteCodeAddresses(in: &out, carried: carried, unmapped: &unmapped)
        return Rendered(
            c: String(decoding: out, as: UTF16.self),
            spans: spans,
            sites: source.cSites.compactMap { site in
                carried[site.address].map { .init(start: moved(site.start), length: site.length, address: $0) }
            },
            fields: source.cFields.map {
                .init(start: moved($0.start), length: $0.length, type: $0.type, offset: $0.offset)
            },
            unreachable: source.cUnreachable.map { block in
                .init(start: moved(block.start), length: block.length, blocks: block.blocks.compactMap { carried[$0] })
            },
            publisherAddresses: unmapped)
    }
}

extension CodeArtifact.CSite {
    init(start: Int, length: Int, address: CodeAddress) {
        self.start = start
        self.length = length
        self.address = address
    }
}

extension CodeArtifact.CField {
    init(start: Int, length: Int, type: String, offset: Int) {
        self.start = start
        self.length = length
        self.type = type
        self.offset = offset
    }
}

extension CodeArtifact.CUnreachable {
    init(start: Int, length: Int, blocks: [CodeAddress]) {
        self.start = start
        self.length = length
        self.blocks = blocks
    }
}

extension ContentStore {
    /// The artifact as a reader sees it: every function the registry has reads
    /// as its entry. One with no registry, or an entry that cannot be read,
    /// stays as it was published.
    public func throughRegistry(_ artifact: CodeArtifact) -> CodeArtifact {
        guard let index = try? libraryIndex(), index.readThrough == true, !index.entries.isEmpty else { return artifact }
        var artifact = artifact
        artifact.functions = throughRegistry(artifact.functions, names: artifact, index: index)
        return artifact
    }

    /// Functions as a reader sees them; `names` is the artifact they are from.
    func throughRegistry(_ functions: [CodeArtifact.Function], names artifact: CodeArtifact,
                         index: LibraryIndex) -> [CodeArtifact.Function] {
        guard index.readThrough == true else { return functions }
        var named: [CodeAddress: String] = [:]
        for symbol in artifact.symbols { named[symbol.address] = symbol.name }
        // A function's own name, the entry's when the registry has it, so a
        // caller prints what the callee is called wherever it is read.
        var entries: [String: LibraryView.Entry] = [:]
        func entry(_ id: String) -> LibraryView.Entry? {
            if let held = entries[id] { return held }
            guard let row = index.entries[id], let object = try? object(row.entry),
                  let read = LibraryView.Entry(object: object, id: id, version: row.version) else { return nil }
            entries[id] = read
            return read
        }
        for function in artifact.functions {
            named[function.entry] = LibraryView.entryID(of: function, in: index).flatMap { index.entries[$0]?.name }
                ?? function.name
        }
        var strings: [CodeAddress: String] = [:]
        for string in artifact.strings { strings[string.address] = string.value }
        return functions.map { function in
            guard let id = LibraryView.entryID(of: function, in: index) else {
                // A mark on what the registry gave back or no longer holds: a
                // function of the module, reading its own text.
                var own = function
                own.libraryEntry = nil
                return own
            }
            // An entry that cannot be read leaves the row marked and without
            // `text`, which is how it shows.
            guard let read = entry(id) else {
                var own = function
                own.textUnavailable = true
                return own
            }
            return LibraryView.function(function, entry: read, name: { named[$0] }, string: { strings[$0] })
        }
    }
}
