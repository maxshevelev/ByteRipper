import AgentDocuments
import AgentKit
import BytePattern
import DumpHost
import Foundation

/// The tools the server answers itself (`Design/SERVER_HEADLESS_PLAN.md`
/// §4.1): what it holds, the bytes, and a search of them. The app's tools are
/// about panes, parts and unsaved edits; these are over a snapshot, with the
/// same answer keys and no screen behind them.
@MainActor
public enum ServerDocuments {
    /// The most a `read` returns.
    public static let maxRead = 4096

    public static func tools(_ documents: DocumentRegistry) -> [AgentTool] {
        [documentsTool(documents), readTool(documents), findTool(documents)]
    }

    static let documentHelp = "The dump's id from `documents`. Default: the only one open."

    // MARK: - documents

    static func documentsTool(_ documents: DocumentRegistry) -> AgentTool {
        AgentTool(
            name: "documents",
            title: "Open documents",
            description: """
                Lists the firmware images this server holds: its `id` (pass it as `document` to the other \
                tools — never show it to the person), `name` (what to call it to the person), `size`, \
                `version` — raised by every Reopen, so a node id read from an older version is not \
                silently read against other bytes — `link` for a file opened from the server's disk (the \
                name as a Markdown link that opens it in ByteRipper on this Mac, where the app is \
                installed; none for an upload, which is kept under its hash), and `disk`: \
                `changed` when the file on disk is no longer the one read, `gone` when it is not there. \
                The snapshot goes on answering either way. Only these documents exist; the operator opens \
                and closes them in the console.
                """
        ) { _ in
            await MainActor.run { .json(["documents": .array(documents.rows.compactMap(entry))]) }
        }
    }

    /// One document as `documents` lists it, nil for a row that is not served.
    static func entry(_ row: DocumentRegistry.Row) -> JSONValue? {
        guard let host = row.host else { return nil }
        var entry: [String: JSONValue] = [
            "id": .string(row.id),
            "name": .string(row.name),
            "size": hex(host.contentSize),
            "version": .count(host.version)
        ]
        if !row.uploaded, let link = link(to: row.path) {
            entry["link"] = .string("[\(row.name)](\(link.absoluteString))")
        }
        if let disk = host.diskState() { entry["disk"] = .string(disk.rawValue) }
        return .object(entry)
    }

    /// The link that opens the file in a ByteRipper beside the person, as the
    /// app's own answers carry it: `byteripper://file?path=…`.
    public static func link(to path: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "byteripper"
        components.host = "file"
        components.queryItems = [URLQueryItem(name: "path", value: path.path)]
        return components.url
    }

    // MARK: - read

    static func readTool(_ documents: DocumentRegistry) -> AgentTool {
        AgentTool(
            name: "read",
            title: "Read bytes",
            description: """
                Reads bytes of an open document's snapshot. `format`: "hex" (default) gives rows of 16 bytes \
                with their address and text, as the dump shows them; "ascii" a string with "." for bytes \
                that are not printable; "utf16le" the bytes decoded as UTF-16LE text; "u8", "u16", "u32", \
                "u64" a list of unsigned integers in hex, little-endian unless `endian` is "big". At most \
                \(maxRead) bytes; a range running past the end of the document is cut there and says so.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string(documentHelp),
                "offset": AgentSchema.offset("Where to start, e.g. \"0x7F3000\"."),
                "length": AgentSchema.offset("How many bytes. Default 256, at most \(maxRead)."),
                "format": AgentSchema.choice(AgentBytes.formats, "How to show them. Default \"hex\"."),
                "endian": AgentSchema.choice(["little", "big"], "For u16, u32 and u64. Default \"little\".")
            ], required: ["offset"])
        ) { call in
            try await read(call.arguments, documents)
        }
    }

    static func read(_ arguments: AgentArguments, _ documents: DocumentRegistry) async throws -> AgentAnswer {
        let document = try documents.resolve(arguments.optionalString("document"))
        let host = document.readHost()
        let offset = try arguments.offset("offset")
        let asked = try arguments.optionalOffset("length") ?? 256
        let format = try arguments.choice("format", from: AgentBytes.formats, default: "hex")
        let bigEndian = try arguments.choice("endian", from: ["little", "big"], default: "little") == "big"
        guard asked > 0 else { throw AgentToolError("Argument `length` must be at least 1.") }
        guard asked <= UInt64(maxRead) else {
            throw AgentToolError("Argument `length`: at most \(maxRead) bytes in one read.")
        }
        let size = host.contentSize
        guard offset < size else {
            throw AgentToolError("Offset \(hexText(offset)) is past the end of \(document.named), "
                + "which is \(hexText(size)) bytes long.")
        }
        let end = min(offset + asked, size)
        let bytes = try host.read(offset..<end)
        var answer = AgentBytes.shown(bytes, at: offset, format: format, bigEndian: bigEndian)
        answer["offset"] = .string(hexText(offset))
        answer["length"] = .string(hexText(end - offset))
        if end - offset < asked { answer["cut_at_end_of_file"] = true }
        return ToolQueryTools.stamped(.json(.object(answer)), with: document)
    }

    // MARK: - find_bytes

    static func findTool(_ documents: DocumentRegistry) -> AgentTool {
        AgentTool(
            name: "find_bytes",
            title: "Find bytes or text",
            description: """
                Every place a text or a byte pattern occurs in a document's snapshot — the bytes as they \
                were read, which is what every other tool answers from. `text` is looked for as ASCII, as \
                UTF-16LE, or both (`encoding`, default both), any case with `ignore_case`; `hex` is bytes, \
                with `??` for a byte that may be anything ("24 ?? 4D 49"). `offset`/`end` limit the range. \
                Each match: `start`, `end` (half-open addresses) and the `encoding` that matched. Matches \
                do not overlap unless `overlapping`: "AA" in "AAAA" is two, or three with it. `total` \
                counts every match in the range. Pages: `limit` is a ceiling — a page also stops before \
                the answer passes the size bound and then says `truncated: "size"`; pass `next` back as \
                `after` until it is null.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string(documentHelp),
                "text": AgentSchema.string("A text to find. Give `text` or `hex`."),
                "hex": AgentSchema.string("Bytes to find, as hex pairs; `??` for any byte: \"24 ?? 4D 49\"."),
                "encoding": AgentSchema.choice(["ascii", "utf16le", "both"],
                                               "How `text` is stored. Default \"both\"."),
                "ignore_case": AgentSchema.boolean("Letters in either case — ASCII letters of `text`. Default false."),
                "overlapping": AgentSchema.boolean("Count matches that overlap one another. Default false."),
                "offset": AgentSchema.offset("Where the search starts. Default 0x0."),
                "end": AgentSchema.offset("The first byte after the searched range. Default: the end."),
                "limit": AgentSchema.limit(default: 100, maximum: 1000),
                "after": AgentSchema.after
            ])
        ) { call in
            try await find(call.arguments, documents)
        }
    }

    /// One pattern the search runs, and what its matches are called.
    struct Wanted {
        var pattern: MaskedPattern
        var encoding: String
    }

    /// The search runs off the main actor, which also serves every other
    /// call and the console: a snapshot may be hundreds of megabytes. The
    /// scan is `BytePattern`'s, the find bar's and the app's own.
    static func find(_ arguments: AgentArguments, _ documents: DocumentRegistry) async throws -> AgentAnswer {
        let document = try documents.resolve(arguments.optionalString("document"))
        let host = document.readHost()
        let reader = try host.snapshot()
        let size = reader.size
        let from = try arguments.optionalOffset("offset") ?? 0
        let to = try arguments.optionalOffset("end") ?? size
        guard from < to, to <= size else {
            throw AgentToolError("The range \(hexText(from))–\(hexText(to)) is not inside \(document.named), "
                + "which is \(hexText(size)) bytes long.")
        }
        let wanted = try patterns(arguments)
        let overlapping = try arguments.bool("overlapping", default: false)
        let limit = try arguments.limit(default: 100, maximum: 1000)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
            [document.id, host.contentVersion,
             JSONValue.object(arguments.values.filter { $0.key != "after" && $0.key != "limit" }).jsonText]))
        let first = paging.first
        let patterns = wanted.map(\.pattern)
        let (total, page) = try await Task.detached(priority: .userInitiated) {
            var total = 0
            var page: [(range: Range<UInt64>, pattern: Int)] = []
            try PatternScan.matches(of: patterns, size: size, range: from..<to, overlapping: overlapping,
                                    read: { try reader.read(at: $0, length: $1) }) { match, pattern in
                if total >= first, page.count < limit { page.append((match, pattern)) }
                total += 1
                return true
            }
            return (total, page)
        }.value

        let items: [JSONValue] = page.map { match in
            .object([
                "start": hex(match.range.lowerBound),
                "end": hex(match.range.upperBound),
                "encoding": .string(wanted[match.pattern].encoding)
            ])
        }
        let answer = try paging.answer(["total": .count(total)], key: "matches", items: items, total: total,
                                       bound: arguments.answerBound)
        return ToolQueryTools.stamped(.json(answer), with: document)
    }

    /// `hex`, or `text` in the encodings asked for — as the app builds them.
    static func patterns(_ arguments: AgentArguments) throws -> [Wanted] {
        let text = try arguments.optionalString("text")
        let hex = try arguments.optionalString("hex")
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
            let encoding = try arguments.choice("encoding", from: ["ascii", "utf16le", "both"], default: "both")
            let ignoreCase = try arguments.bool("ignore_case", default: false)
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

    // MARK: - Shapes

    static func hexText(_ value: UInt64) -> String { String(format: "0x%llX", value) }
    static func hex(_ value: UInt64) -> JSONValue { .string(hexText(value)) }
}
