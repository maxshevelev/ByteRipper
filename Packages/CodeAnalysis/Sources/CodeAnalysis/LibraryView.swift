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
        if let body = function.body, let id = index.bodies[body] { return id }
        if let id = function.libraryEntry?.id, index.entries[id] != nil { return id }
        return nil
    }

    /// The function as a reader sees it. `name` is this module's name for an
    /// address, nil when it has none.
    public static func function(_ local: CodeArtifact.Function, entry: Entry,
                                name: (CodeAddress) -> String?) -> CodeArtifact.Function {
        var function = local
        function.name = entry.name
        function.signature = entry.function?.signature ?? entry.signature ?? local.signature
        function.nameSource = "USER_DEFINED"
        function.nameReason = "library registry entry \(entry.id) v\(entry.version)"
        function.reviewLevel = .library
        function.reviewGaps = []
        function.libraryKind = entry.kind ?? local.libraryKind
        function.libraryEntry = .init(id: entry.id, version: entry.version, codes: local.libraryEntry?.codes ?? [])
        guard let source = entry.function, source.c != nil, !local.codeIsPending else { return function }
        let carried = carriedOver(from: source, to: local)
        let rendered = render(source, carried: carried, name: name)
        function.c = rendered.c
        function.cSpans = rendered.spans
        function.cSites = rendered.sites
        function.cFields = rendered.fields
        function.cUnreachable = rendered.unreachable
        return function
    }

    /// Where each address of the entry's function is in this module's: an
    /// instruction by its place, what it refers to by the same reference of the
    /// same instruction. Bodies that are equal have as many of both; where they
    /// have not, only the instructions' own distance from the entry carries over.
    static func carriedOver(from source: CodeArtifact.Function,
                            to local: CodeArtifact.Function) -> [CodeAddress: CodeAddress] {
        var map: [CodeAddress: CodeAddress] = [source.entry: local.entry]
        guard source.instructions.count == local.instructions.count else {
            for instruction in source.instructions where instruction.address >= source.entry {
                map[instruction.address] = CodeAddress(
                    instruction.address.value - source.entry.value + local.entry.value)
            }
            return map
        }
        for (theirs, ours) in zip(source.instructions, local.instructions) {
            map[theirs.address] = ours.address
            guard theirs.references.count == ours.references.count else { continue }
            for (from, to) in zip(theirs.references, ours.references) { map[from.to] = to.to }
        }
        return map
    }

    struct Rendered {
        var c: String
        var spans: [CodeArtifact.CSpan]
        var sites: [CodeArtifact.CSite]
        var fields: [CodeArtifact.CField]
        var unreachable: CodeArtifact.CUnreachable?
    }

    /// The entry's C, with what a token names being this module's: its address,
    /// and its name where the module has one. A target with no place here
    /// loses the link rather than lead somewhere wrong.
    static func render(_ source: CodeArtifact.Function, carried: [CodeAddress: CodeAddress],
                       name: (CodeAddress) -> String?) -> Rendered {
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
        for span in source.cSpans.sorted(by: { $0.start < $1.start }) {
            guard span.start >= cursor, span.start + span.length <= units.count else { continue }
            out += units[cursor..<span.start]
            cursor = span.start
            let target = span.target.flatMap { carried[$0] }
            let token = Array(units[span.start..<(span.start + span.length)])
            var written = token
            if span.kind == .function || span.kind == .global, let target, let own = name(target), !own.isEmpty {
                written = Array(own.utf16)
            }
            let start = out.count
            out += written
            cursor = span.start + span.length
            moves.append((at: cursor, by: out.count - cursor))
            spans.append(.init(start: start, length: written.count, kind: span.kind, target: target))
        }
        out += units[min(cursor, units.count)...]
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
            })
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
        guard let index = try? libraryIndex(), !index.entries.isEmpty else { return artifact }
        var artifact = artifact
        artifact.functions = throughRegistry(artifact.functions, names: artifact, index: index)
        return artifact
    }

    /// Functions as a reader sees them; `names` is the artifact they are from.
    func throughRegistry(_ functions: [CodeArtifact.Function], names artifact: CodeArtifact,
                         index: LibraryIndex) -> [CodeArtifact.Function] {
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
        return functions.map { function in
            guard let id = LibraryView.entryID(of: function, in: index), let read = entry(id) else { return function }
            return LibraryView.function(function, entry: read, name: { named[$0] })
        }
    }
}
