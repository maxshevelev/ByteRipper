import AgentKit
import BytePattern
import Foundation
import ToolModuleKit
import UEFIImage

/// The search through what the tree holds, for an agent: the same walk as the
/// panel's Contents search (`UEFIContentSearch`) — every volume opened, every
/// compressed section's decompressed bytes searched — answered as a list of
/// matches, each placed at its node and in its volume.
@MainActor
public enum UEFIAgentContentSearch {
    nonisolated public static var all: [ToolAgentQuery] { [search] }

    /// One pattern the search runs, and what its matches are called.
    public struct Wanted: Sendable {
        public var pattern: MaskedPattern
        public var encoding: String
    }

    /// The patterns a text or a hex string asks for: hex bytes with `??` holes,
    /// or text as ASCII, UTF-16LE or both — as `find_bytes` and the panel take
    /// them.
    nonisolated public static func patterns(text: String?, hex: String?, encoding: String = "both",
                                            ignoreCase: Bool = false) throws -> [Wanted] {
        switch (text, hex) {
        case (nil, nil), (.some, .some):
            throw AgentToolError("Give `text` or `hex`, one of them.")
        case (_, .some(let hex)):
            do {
                return [Wanted(pattern: try MaskedPattern.hex(hex), encoding: "hex")]
            } catch {
                throw AgentToolError("`hex` is not a byte pattern. Give pairs of hex digits and `??` for any byte, "
                    + "e.g. \"24 ?? 4D 49\"; a pattern of `??` alone matches everywhere.")
            }
        case (.some(let text), _):
            guard !text.isEmpty else { throw AgentToolError("`text` is empty.") }
            var wanted: [Wanted] = []
            if encoding != "utf16le" {
                guard let ascii = try? MaskedPattern.ascii(text, ignoringCase: ignoreCase) else {
                    throw AgentToolError("`text` is not ASCII; look for it with `encoding` \"utf16le\".")
                }
                wanted.append(Wanted(pattern: ascii, encoding: "ascii"))
            }
            if encoding != "ascii" {
                wanted.append(Wanted(pattern: try MaskedPattern.utf16LE(text, ignoringCase: ignoreCase),
                                     encoding: "utf16le"))
            }
            return wanted
        }
    }

    // MARK: - uefi_find_bytes

    nonisolated static let search = ToolAgentQuery(
        name: "uefi_find_bytes",
        title: "Find bytes in UEFI contents",
        description: """
            Every place a text or a byte pattern occurs in what the UEFI tree holds — the bytes of the \
            image and, unlike `find_bytes`, what every compressed section decompresses to (LZMA, Tiano, \
            Brotli and the rest, nested ones too), a BIOS Guard update's assembled region, and a Lenovo \
            LENV block stored XOR-encoded, decoded — and only so: a compressed section's body and an \
            encoded LENV block as they are stored are not searched. An ME region is not searched at all. Opens every container \
            first, which takes a few seconds on a large image the first time; the same search of unchanged \
            bytes again — a next page — is answered from the last one. `node` (an id from `uefi_tree`, `uefi_find` or `uefi_at`) \
            searches only that node and what is under it; without it, the whole image. `text` is looked \
            for as ASCII, as UTF-16LE, or both (`encoding`, default both), any case with `ignore_case`; \
            `hex` is bytes, with `??` for a byte that may be anything ("24 ?? 4D 49"). Matches come in \
            tree order. Each: `encoding`; `node` — the deepest node that holds the match whole, as \
            `uefi_tree` gives it — and `node_offset` from its first byte; `volume` (id and label) with \
            `volume_offset` from the volume's first byte when both are in the same bytes; for a match in \
            the file `start` and `end` (half-open file addresses); for one in decompressed bytes \
            `in_compressed: true`, `section` (the compressed section to open with `open_part` part \
            "decompressed") and `buffer_start`/`buffer_end` in what it decompresses to — read there with \
            `uefi_node_data`; `decoded` ("XOR 77") for a match in a LENV block's decoded bytes, whose file \
            addresses hold them encoded. `total` counts every match; `unread` lists compressed sections \
            that could not be decompressed and were not searched. Pages: `limit` is a ceiling — a page also \
            stops before the answer passes the size bound and says `truncated: "size"`; pass `next` back as \
            `after` until it is null.
            """,
        properties: [
            "text": AgentSchema.string("A text to find. Give `text` or `hex`."),
            "hex": AgentSchema.string("Bytes to find, as hex pairs; `??` for any byte: \"24 ?? 4D 49\"."),
            "encoding": AgentSchema.choice(["ascii", "utf16le", "both"], "How `text` is stored. Default \"both\"."),
            "ignore_case": AgentSchema.boolean("Letters in either case — ASCII letters of `text`. Default false."),
            "node": AgentSchema.string("Search only this node and what is under it. Default: the whole image."),
            "limit": AgentSchema.limit(default: 100, maximum: 1000),
            "after": AgentSchema.after
        ]
    ) { host, arguments in
        let encoding = try arguments.choice("encoding", from: ["ascii", "utf16le", "both"], default: "both")
        let wanted = try patterns(text: try arguments.optionalString("text"), hex: try arguments.optionalString("hex"),
                                  encoding: encoding, ignoreCase: try arguments.bool("ignore_case", default: false))
        let start = try UEFIAgentQueries.nodeID(arguments.optionalString("node"))
        let limit = try arguments.limit(default: 100, maximum: 1000)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
            [host.contentVersion, JSONValue.object(arguments.values.filter { $0.key != "after" && $0.key != "limit" }).jsonText]))
        let tree = try await UEFIAgentQueries.readyTree(host)
        let result: UEFIContentSearch.Result
        do {
            result = try await UEFIContentSearch.run(wanted.map(\.pattern), from: start, in: tree,
                                                     keep: paging.first + limit)
        } catch UEFIContentSearchError.unknownNode(let id) {
            throw UEFIAgentQueries.unknownNode(id)
        }

        var envelope: [String: JSONValue] = [
            "total": .count(result.total),
            "searched": .string(UEFIAgentQueries.hex(result.searchedBytes)),
            "buffers": .count(result.buffers)
        ]
        if start != .root, let node = tree.node(start) {
            envelope["node"] = UEFIAgentQueries.summary(of: node, in: tree)
        }
        if !result.unreadSections.isEmpty {
            envelope["unread"] = .array(result.unreadSections.map { .string($0.description) })
        }
        if result.matches.count < min(result.total, paging.first + limit) {
            envelope["note"] = .string("Too many matches to place them all in tree order; these are the first "
                + "\(result.matches.count). Search from a `node` to narrow it.")
        }
        let items = result.matches.dropFirst(paging.first).prefix(limit).map { match in
            entry(for: match, encoding: wanted[match.pattern].encoding, in: tree)
        }
        return .json(try paging.answer(envelope, key: "matches", items: Array(items), total: result.total,
                                       bound: arguments.answerBound))
    }

    static func entry(for match: UEFIContentSearch.Match, encoding: String, in tree: LazyUEFITree) -> JSONValue {
        var members: [String: JSONValue] = ["encoding": .string(encoding)]
        if let node = match.node.flatMap(tree.node) {
            members["node"] = UEFIAgentQueries.summary(of: node, in: tree)
        }
        if let offset = match.nodeOffset { members["node_offset"] = .string(UEFIAgentQueries.hex(offset)) }
        if let volume = match.volume.flatMap(tree.node) {
            members["volume"] = ["id": .string(volume.id.description),
                                 "label": .string(UEFIAgentQueries.label(of: volume, in: tree))]
        }
        if let offset = match.volumeOffset { members["volume_offset"] = .string(UEFIAgentQueries.hex(offset)) }
        if let range = match.fileRange {
            members["start"] = .string(UEFIAgentQueries.hex(range.lowerBound))
            members["end"] = .string(UEFIAgentQueries.hex(range.upperBound))
        } else {
            members["in_compressed"] = true
            members["buffer_start"] = .string(UEFIAgentQueries.hex(match.range.lowerBound))
            members["buffer_end"] = .string(UEFIAgentQueries.hex(match.range.upperBound))
        }
        if let section = match.section { members["section"] = .string(section.description) }
        if let key = match.decodedXORKey { members["decoded"] = .string(String(format: "XOR %02X", key)) }
        return .object(members)
    }
}
