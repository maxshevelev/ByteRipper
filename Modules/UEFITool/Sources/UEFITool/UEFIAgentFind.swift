import AgentKit
import BytePattern
import Foundation
import HexText
import ToolModuleKit
import UEFIImage

/// `find_bytes`, once: the app's agent and the analysis server answer it with
/// this, each over its own content. What is searched comes through
/// `ToolReadHost` — an open panel's bytes in the app, a document's snapshot on
/// the server — and the search itself is the find bar's: `PatternScan` over
/// the content, `UEFIContentSearch` with `node`, and the pattern read as the
/// find bar reads it (`MaskedPattern.hex`, `MaskedPattern.guid`). Where a
/// match lies in the firmware is the locators' answer, the same ones `diff`
/// places a run with.
public enum UEFIAgentFind {
    /// The most bytes a preview takes on either side of a match.
    public static let maxContext = 64

    /// The document a search runs over, as the answer and its errors name it.
    public struct Document: Sendable {
        public let id: String
        /// How an error names it: `front.bin (d1)`.
        public let named: String

        public init(id: String, named: String) {
            self.id = id
            self.named = named
        }
    }

    /// One pattern the search runs, and what its matches are called.
    public struct Wanted: Sendable {
        public var pattern: MaskedPattern
        public var encoding: String

        public init(pattern: MaskedPattern, encoding: String) {
            self.pattern = pattern
            self.encoding = encoding
        }
    }

    /// The tool's description. `contents` says what the document's bytes are
    /// to this host — the panel's, unsaved edits included, or the snapshot's;
    /// `opensParts`, whether it has `open_part`; `extra` is said last.
    public static func description(contents: String, opensParts: Bool, extra: String = "") -> String {
        """
        Every place a text or a byte pattern occurs, in one of two scopes. Without `node`: \(contents) — \
        the find bar's own search — in address order, `offset`/`end` limiting the range. With `node` (an id \
        from `uefi_tree`, `uefi_find` or `uefi_at`, or "root" for the whole image): what the UEFI tree holds \
        at and under that node — every container opened, every compressed section searched in what it \
        decompresses to (nested ones too), a BIOS Guard update in its assembled region, a Lenovo LENV block \
        stored XOR-encoded decoded — and only so: a compressed stream or an encoded block as stored is not \
        searched, nor is an ME region. Opening everything takes a few seconds on a large image the first \
        time; the same search of unchanged bytes again — a next page — is answered from the last one. A text \
        the file holds only compressed is found this way and not the other. `text` is looked for as ASCII, \
        as UTF-16LE, or both (`encoding`, default both), any case with `ignore_case`; `hex` is bytes, with \
        `??` for a byte that may be anything ("24 ?? 4D 49"); `guid` is a GUID as code writes it, \
        "CDEA2BD3-FC25-4C1C-B97C-B31186064990", looked for as the 16 bytes it is in an image — the first \
        three groups byte-reversed: D3 2B EA CD 25 FC 1C 4C B9 7C B3 11 86 06 49 90. Each match: the \
        `encoding` that matched; without `node`, `start`, `end` (half-open file addresses) and `where` it \
        is, as `diff` places a run; with `node`, in tree order, the `node` that holds it whole (as \
        `uefi_tree` gives it) with `node_offset`, from its first byte (its part "all"), and `body_offset`, \
        from its body's, when the match lies in the body (its part "body", what `uefi_node_data` and \
        `pattern_part` read by default), its `volume` and `volume_offset`, and `start`/`end` in the file — \
        or, inside a compressed section, `in_compressed: true`, the `section`\(opensParts
            ? " (open it with `open_part` part \"decompressed\")" : "") and `buffer_start`/`buffer_end` in what it decompresses to, which `uefi_node_data` \
        reads — and `decoded` ("XOR 77") in a LENV block decoded. With `context`, a `preview` of the bytes \
        around it — none, and `redacted: true`, in an area the flash map names MSDM, Password or Key. \
        `total` counts every match; with `node`, `unread` lists the compressed sections that would not \
        decompress. Matches overlap, as in the find bar: "AA" in "AAAA" is three, or two with `overlapping` \
        false. Pages: `limit` is a ceiling — a page also stops before the answer passes the size bound and says \
        `truncated: "size"`; pass `next` back as `after` until it is null. `show` "compact" answers each \
        match as where it is and no more — `node` by its id with `node_offset` and `body_offset`, or \
        `start` — and "count" answers `total` alone. `pattern_node`, `pattern_range` and `pattern_part` take \
        the pattern from a node's bytes instead of `text` or `hex`, the place it came from among the \
        matches; `any` marks bytes of it that may be anything, such as an operand that holds an \
        address.
        """ + (extra.isEmpty ? "" : " " + extra)
    }

    /// The tool's arguments. `document` is the host's to describe.
    public static func properties(document: String) -> [String: JSONValue] {
        UEFIAgentNodeData.patternProperties.merging([
            "document": AgentSchema.string(document),
            "text": AgentSchema.string("A text to find. Give one of `text`, `hex` and `guid`."),
            "hex": AgentSchema.string("Bytes to find, as hex pairs; `??` for any byte: \"24 ?? 4D 49\"."),
            "guid": AgentSchema.string("A GUID to find, \"CDEA2BD3-FC25-4C1C-B97C-B31186064990\", braces "
                                       + "optional: its bytes in memory."),
            "encoding": AgentSchema.choice(["ascii", "utf16le", "both"], "How `text` is stored. Default \"both\"."),
            "ignore_case": AgentSchema.boolean("Letters in either case — ASCII letters of `text`. Default false."),
            "overlapping": AgentSchema.boolean("Count matches that overlap one another, as the find bar does. Default true."),
            "offset": AgentSchema.offset("Where the search of the document starts. Default 0x0. Not with `node`."),
            "end": AgentSchema.offset("The first byte after the searched range. Default: the end. Not with `node`."),
            "node": AgentSchema.string("Search what the UEFI tree holds at and under this node, decompressed and "
                                       + "decoded; \"root\" for the whole image."),
            "context": AgentSchema.integer("Bytes before and after each match to show in `preview`. Default 0, "
                                           + "at most \(maxContext)."),
            "show": AgentSchema.choice(UEFIAgentContentSearch.shows, UEFIAgentContentSearch.showHelp),
            "limit": AgentSchema.limit(default: 100, maximum: 1000),
            "after": AgentSchema.after
        ]) { $1 }
    }

    /// `text`, `hex` or `guid`, as the find bar reads each.
    public static func patterns(_ arguments: AgentArguments) throws -> [Wanted] {
        let text = try arguments.optionalString("text")
        let hex = try arguments.optionalString("hex")
        let guid = try arguments.optionalString("guid")
        guard [text, hex, guid].compactMap({ $0 }).count == 1 else {
            throw AgentToolError("Give one of `text`, `hex` and `guid`.")
        }
        if let guid {
            guard let pattern = try? MaskedPattern.guid(guid) else {
                throw AgentToolError("`guid` is not a GUID. Write it as code does, 8-4-4-4-12 hex digits: "
                    + "\"CDEA2BD3-FC25-4C1C-B97C-B31186064990\", braces optional.")
            }
            return [Wanted(pattern: pattern, encoding: "guid")]
        }
        if let hex {
            do {
                return [Wanted(pattern: try MaskedPattern.hex(hex), encoding: "hex")]
            } catch {
                throw AgentToolError("`hex` is not a byte pattern. Give pairs of hex digits and `??` for any byte, "
                    + "e.g. \"24 ?? 4D 49\". A hole is a whole byte — half a byte (`2?`) cannot be masked — "
                    + "and a pattern of `??` alone matches everywhere.")
            }
        }
        let typed = text ?? ""
        guard !typed.isEmpty else { throw AgentToolError("`text` is empty.") }
        let encoding = try arguments.choice("encoding", from: ["ascii", "utf16le", "both"], default: "both")
        let ignoreCase = try arguments.bool("ignore_case", default: false)
        var wanted: [Wanted] = []
        if encoding != "utf16le" {
            guard let ascii = try? MaskedPattern.ascii(typed, ignoringCase: ignoreCase) else {
                throw AgentToolError("`text` is not ASCII; look for it with `encoding` \"utf16le\".")
            }
            wanted.append(Wanted(pattern: ascii, encoding: "ascii"))
        }
        if encoding != "ascii" {
            wanted.append(Wanted(pattern: try MaskedPattern.utf16LE(typed, ignoringCase: ignoreCase),
                                 encoding: "utf16le"))
        }
        return wanted
    }

    /// The search. `locators` place a match in the firmware — finest first,
    /// the first that can say wins — and say which areas are secret.
    @MainActor
    public static func run(_ arguments: AgentArguments, host: any ToolReadHost, document: Document,
                           locators: [ToolAgentLocator]) async throws -> JSONValue {
        let wanted = try await UEFIAgentNodeData.pattern(host, arguments)
            .map { [Wanted(pattern: $0, encoding: "hex")] } ?? patterns(arguments)
        let overlapping = try arguments.bool("overlapping", default: true)
        let context = Int(max(0, min(Int64(maxContext),
                                     try arguments.has("context") ? arguments.integer("context") : 0)))
        let show = try arguments.choice("show", from: UEFIAgentContentSearch.shows, default: "full")
        if show != "full", context > 0 {
            throw AgentToolError("`context` shows bytes around a match: it needs `show` \"full\".")
        }
        let limit = show == "count" ? 0 : try arguments.limit(default: 100, maximum: 1000)
        if let node = try arguments.optionalString("node") {
            return try await inTree(arguments, host: host, document: document, wanted: wanted, node: node,
                                    overlapping: overlapping, context: context, limit: limit, show: show)
        }
        return try await inBytes(arguments, host: host, document: document, wanted: wanted, locators: locators,
                                 overlapping: overlapping, context: context, limit: limit, show: show)
    }

    @MainActor
    private static func paging(_ arguments: AgentArguments, _ host: any ToolReadHost, _ document: Document,
                               _ extra: String = "") throws -> AgentPage {
        try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
            [document.id, host.contentVersion, extra,
             JSONValue.object(arguments.values.filter { $0.key != "after" && $0.key != "limit" }).jsonText]))
    }

    private static func preview(_ bytes: [UInt8], before: Int, encoding: String) -> JSONValue {
        [
            "hex": .string(AgentBytes.hexText(bytes)),
            "text": .string(encoding == "utf16le" ? AgentBytes.utf16le(bytes) : AgentBytes.printable(bytes)),
            "before": .count(before)
        ]
    }

    /// A preview left out of an item too large for the answer's bound.
    private static func dropPreview(_ item: JSONValue) -> JSONValue? {
        guard case .object(var members) = item, members["preview"] != nil else { return nil }
        members["preview"] = nil
        members["truncated"] = "item"
        return .object(members)
    }

    /// Each range placed by the finest locator that can say.
    @MainActor
    public static func locate(_ host: any ToolReadHost, _ ranges: [Range<UInt64>],
                       by locators: [ToolAgentLocator]) async -> [[ToolAgentPlace]] {
        var result = ranges.map { _ -> [ToolAgentPlace] in [] }
        for locator in locators.sorted(by: { $0.precedence > $1.precedence }) {
            let open = result.indices.filter { result[$0].isEmpty }
            guard !open.isEmpty else { break }
            let answers = await locator.locate(host, open.map { ranges[$0] })
            for (index, places) in zip(open, answers) { result[index] = places }
        }
        return result
    }

    /// A place as `where` lists it.
    public static func placeJSON(_ place: ToolAgentPlace) -> JSONValue {
        var members: [String: JSONValue] = ["kind": .string(place.kind), "name": .string(place.name)]
        if !place.id.isEmpty { members["id"] = .string(place.id) }
        if let label = place.label { members["label"] = .string(label) }
        return .object(members)
    }

    @MainActor
    private static func inBytes(_ arguments: AgentArguments, host: any ToolReadHost, document: Document,
                                wanted: [Wanted], locators: [ToolAgentLocator], overlapping: Bool,
                                context: Int, limit: Int, show: String) async throws -> JSONValue {
        let reader = try host.snapshot()
        let size = reader.size
        guard size > 0 else { throw AgentToolError("\(document.named) holds no bytes to search.") }
        let offset = try arguments.optionalOffset("offset") ?? 0
        let end = try arguments.optionalOffset("end") ?? size
        guard offset < size else {
            throw AgentToolError("`offset` \(offset.hexNumber) is past the end of \(document.named), "
                + "which is \(size.hexNumber) bytes long.")
        }
        guard offset < end else {
            throw AgentToolError("`end` \(end.hexNumber) is not after `offset` \(offset.hexNumber): "
                + "the range holds no bytes.")
        }
        guard end <= size else {
            throw AgentToolError("The range \((offset..<end).halfOpenHexText) is not inside "
                + "\(document.named), which is \(size.hexNumber) bytes long.")
        }
        let range = offset..<end
        if wanted.allSatisfy({ $0.pattern.count > range.count }) {
            throw AgentToolError("The pattern is longer than the range searched.")
        }
        var envelope: [String: JSONValue] = [
            "document": .string(document.id),
            "range": ["start": .string(offset.hexNumber), "end": .string(end.hexNumber),
                      "length": .string((end - offset).hexNumber)]
        ]
        let paging = try paging(arguments, host, document)
        let first = paging.first
        let patterns = wanted.map(\.pattern)
        let (total, page) = try await Task.detached(priority: .userInitiated) {
            var total = 0
            var page: [(range: Range<UInt64>, pattern: Int)] = []
            try PatternScan.matches(of: patterns, size: size, range: range, overlapping: overlapping,
                                    read: { try reader.read(at: $0, length: $1) }) { match, pattern in
                if total >= first, page.count < limit { page.append((match, pattern)) }
                total += 1
                return true
            }
            return (total, page)
        }.value
        envelope["total"] = .count(total)
        if show == "count" {
            envelope["matches"] = .array([])
            envelope["next"] = .null
            return .object(envelope)
        }
        if show == "compact" {
            let rows = page.map { match in
                UEFIAgentContentSearch.compact(.object(["start": .string(match.range.lowerBound.hexNumber),
                                                        "encoding": .string(wanted[match.pattern].encoding)]),
                                               keepingEncoding: wanted.count > 1)
            }
            return try paging.answer(envelope, key: "matches", items: rows, total: total, bound: arguments.answerBound)
        }

        let places = await locate(host, page.map(\.range), by: locators)
        var items: [JSONValue] = []
        for (match, places) in zip(page, places) {
            var members: [String: JSONValue] = [
                "encoding": .string(wanted[match.pattern].encoding),
                "where": .array(places.map(placeJSON)),
                "start": .string(match.range.lowerBound.hexNumber),
                "end": .string(match.range.upperBound.hexNumber)
            ]
            // An area the flash map names for a secret — MSDM, a password, a
            // key — gives its matches but not the bytes around them.
            let secret = places.contains { UEFIAgentRegions.isSecretName($0.name) }
            if context > 0, secret { members["redacted"] = true }
            if context > 0, !secret {
                let from = match.range.lowerBound - min(UInt64(context), match.range.lowerBound)
                let to = min(size, match.range.upperBound + UInt64(context))
                let bytes = (try? reader.read(at: from, length: Int(to - from))) ?? []
                members["preview"] = preview(bytes, before: Int(match.range.lowerBound - from),
                                             encoding: wanted[match.pattern].encoding)
            }
            items.append(.object(members))
        }
        return try paging.answer(envelope, key: "matches", items: items, total: total,
                                 bound: arguments.answerBound, shorten: dropPreview)
    }

    /// With `node`: what the UEFI tree holds at and under it, decompressed and
    /// decoded (`UEFIContentSearch`, the UEFI panel's Contents search), each
    /// match placed at its node and in its volume.
    @MainActor
    private static func inTree(_ arguments: AgentArguments, host: any ToolReadHost, document: Document,
                               wanted: [Wanted], node text: String, overlapping: Bool, context: Int,
                               limit: Int, show: String) async throws -> JSONValue {
        guard !arguments.has("offset"), !arguments.has("end") else {
            throw AgentToolError("`offset` and `end` are the document's: with `node` the search covers what the tree "
                + "holds under it, decompressed and decoded, which is no one range of addresses. Leave them out, "
                + "or search the document without `node`.")
        }
        let tree = try await UEFIAgentQueries.readyTree(host)
        let start = try UEFIAgentQueries.nodeID(text)
        let paging = try paging(arguments, host, document, start.description)
        let result: UEFIContentSearch.Result
        do {
            result = try await UEFIContentSearch.run(wanted.map(\.pattern), from: start, in: tree,
                                                     overlapping: overlapping, keep: paging.first + limit,
                                                     padding: UInt64(context))
        } catch UEFIContentSearchError.unknownNode(let id) {
            throw UEFIAgentQueries.unknownNode(id)
        }
        var envelope: [String: JSONValue] = [
            "document": .string(document.id),
            "total": .count(result.total),
            "searched": .string(result.searchedBytes.hexNumber),
            "buffers": .count(result.buffers)
        ]
        if start == .root {
            envelope["node"] = "root"
        } else if let node = tree.node(start) {
            envelope["node"] = UEFIAgentQueries.summary(of: node, in: tree)
        }
        if !result.unreadSections.isEmpty {
            envelope["unread"] = .array(result.unreadSections.map { .string($0.description) })
        }
        if result.matches.count < min(result.total, paging.first + limit) {
            envelope["note"] = .string("Too many matches to place them all in tree order; these are the first "
                + "\(result.matches.count). Search from a deeper `node` to narrow it.")
        }
        if show == "count" {
            envelope["matches"] = .array([])
            envelope["next"] = .null
            envelope["note"] = nil
            return .object(envelope)
        }
        let items: [JSONValue] = result.matches.dropFirst(paging.first).prefix(limit).map { match in
            let entry = UEFIAgentContentSearch.entry(for: match, encoding: wanted[match.pattern].encoding, in: tree)
            if show == "compact" { return UEFIAgentContentSearch.compact(entry, keepingEncoding: wanted.count > 1) }
            guard case .object(var members) = entry, context > 0 else { return entry }
            // An area the flash map names for a secret gives its matches but
            // not the bytes around them.
            if let node = match.node.flatMap(tree.node), UEFIAgentRegions.isSecret(node, in: tree) {
                members["redacted"] = true
                return .object(members)
            }
            members["preview"] = preview(match.excerpt, before: match.excerptMatch.lowerBound,
                                         encoding: wanted[match.pattern].encoding)
            return .object(members)
        }
        return try paging.answer(envelope, key: "matches", items: items, total: result.total,
                                 bound: arguments.answerBound, shorten: dropPreview)
    }
}
