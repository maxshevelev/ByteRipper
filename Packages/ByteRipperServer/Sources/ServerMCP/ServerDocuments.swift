import AgentDocuments
import AgentKit
import BytePattern
import DumpHost
import Foundation
import ToolModuleKit
import UEFITool

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

    /// `find_bytes` is `UEFIAgentFind`'s, the app's too: here it runs over the
    /// document's snapshot, off the main actor, which also serves every other
    /// call and the console. A match is placed by the UEFI tree, as the app
    /// places one.
    static func findTool(_ documents: DocumentRegistry) -> AgentTool {
        AgentTool(
            name: "find_bytes",
            title: "Find bytes or text",
            description: UEFIAgentFind.description(
                contents: "the document's snapshot, the bytes as they were read, which is what every other tool "
                    + "answers from", opensParts: false),
            inputSchema: AgentSchema.object(UEFIAgentFind.properties(document: documentHelp))
        ) { call in
            try await find(call.arguments, documents)
        }
    }

    @MainActor
    static func find(_ arguments: AgentArguments, _ documents: DocumentRegistry) async throws -> AgentAnswer {
        let document = try documents.resolve(arguments.optionalString("document"))
        let answer = try await UEFIAgentFind.run(arguments, host: document.readHost(),
                                                 document: .init(id: document.id, named: document.named),
                                                 locators: [UEFIAgentLocator.locator])
        return ToolQueryTools.stamped(.json(answer), with: document)
    }


    // MARK: - Shapes

    static func hexText(_ value: UInt64) -> String { String(format: "0x%llX", value) }
    static func hex(_ value: UInt64) -> JSONValue { .string(hexText(value)) }
}
