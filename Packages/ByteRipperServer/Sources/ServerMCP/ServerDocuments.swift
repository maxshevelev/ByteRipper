import AgentDocuments
import AgentKit
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
                silently read against other bytes — `link` for the file on disk (the name as a Markdown \
                link that opens it in ByteRipper — write it where you name the file), and `disk`: \
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
        if let link = link(to: row.path) {
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
                counts every match in the range; a page holds up to `limit` from `after`, and `next` is \
                the offset to pass back as `after`, or null at the end.
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
                "after": AgentSchema.offset("The offset to go on from — the `next` of the page before.")
            ])
        ) { call in
            try await find(call.arguments, documents)
        }
    }

    static func find(_ arguments: AgentArguments, _ documents: DocumentRegistry) async throws -> AgentAnswer {
        let document = try documents.resolve(arguments.optionalString("document"))
        let host = document.readHost()
        let size = host.contentSize
        let from = try arguments.optionalOffset("offset") ?? 0
        let to = min(try arguments.optionalOffset("end") ?? size, size)
        let after = try arguments.optionalOffset("after")
        let limit = try arguments.limit(default: 100, maximum: 1000)
        let overlapping = try arguments.bool("overlapping", default: false)
        let ignoreCase = try arguments.bool("ignore_case", default: false)
        guard from <= to else { throw AgentToolError("Argument `end` is before `offset`.") }

        let text = try arguments.optionalString("text")
        let hex = try arguments.optionalString("hex")
        guard (text == nil) != (hex == nil) else { throw AgentToolError("Give one of `text` or `hex`.") }
        var requested: [(bytes: [UInt8?], encoding: String)] = []
        if let hex {
            requested = [(try hexPattern(hex), "hex")]
        } else if let text {
            let encoding = try arguments.choice("encoding", from: ["ascii", "utf16le", "both"], default: "both")
            if encoding != "utf16le" { requested.append((text.utf8.map { Optional($0) }, "ascii")) }
            if encoding != "ascii" { requested.append((utf16le(text), "utf16le")) }
        }
        guard requested.allSatisfy({ !$0.bytes.isEmpty }) else { throw AgentToolError("The pattern is empty.") }

        let bytes = try host.snapshot().read(at: from, length: Int(to - from))
        var found: [(offset: UInt64, length: Int, encoding: String)] = []
        for pattern in requested {
            for index in matches(of: pattern.bytes, in: bytes, ignoreCase: ignoreCase, overlapping: overlapping) {
                found.append((from + UInt64(index), pattern.bytes.count, pattern.encoding))
            }
        }
        found.sort { $0.offset < $1.offset }

        let remaining = after.map { offset in found.filter { $0.offset > offset } } ?? found
        let page = Array(remaining.prefix(limit))
        var answer: [String: JSONValue] = [
            "total": .count(found.count),
            "matches": .array(page.map { match in
                .object([
                    "start": .string(hexText(match.offset)),
                    "end": .string(hexText(match.offset + UInt64(match.length))),
                    "encoding": .string(match.encoding)
                ])
            })
        ]
        if remaining.count > page.count { answer["next"] = .string(hexText(remaining[page.count].offset)) }
        return ToolQueryTools.stamped(.json(.object(answer)), with: document)
    }

    // MARK: - Searching

    /// "24 ?? 4D 49": two hex digits a byte, `??` any byte.
    static func hexPattern(_ text: String) throws -> [UInt8?] {
        try text.split(separator: " ").map { part in
            if part == "??" || part == "?" { return nil }
            guard part.count == 2, let value = UInt8(part, radix: 16) else {
                throw AgentToolError("\"\(part)\" is not two hex digits or `??`.")
            }
            return value
        }
    }

    static func utf16le(_ text: String) -> [UInt8?] {
        text.utf16.flatMap { unit in [UInt8(truncatingIfNeeded: unit), UInt8(truncatingIfNeeded: unit >> 8)] }
            .map { Optional($0) }
    }

    /// Where `pattern` matches `bytes`, each nil a byte that may be anything.
    static func matches(of pattern: [UInt8?], in bytes: [UInt8], ignoreCase: Bool,
                        overlapping: Bool) -> [Int] {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return [] }
        let length = pattern.count
        let last = bytes.count - length
        func same(_ have: UInt8, _ want: UInt8) -> Bool { ignoreCase ? fold(have) == fold(want) : have == want }
        var found: [Int] = []
        var index = 0
        while index <= last {
            if let first = pattern[0], !same(bytes[index], first) {
                index += 1
                continue
            }
            var matched = true
            for back in 1..<length {
                guard let want = pattern[back] else { continue }
                if !same(bytes[index + back], want) { matched = false; break }
            }
            if matched {
                found.append(index)
                index += overlapping ? 1 : length
            } else {
                index += 1
            }
        }
        return found
    }

    /// ASCII lower case, which is what `ignore_case` promises.
    static func fold(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    // MARK: - Shapes

    static func hexText(_ value: UInt64) -> String { String(format: "0x%llX", value) }
    static func hex(_ value: UInt64) -> JSONValue { .string(hexText(value)) }
}
