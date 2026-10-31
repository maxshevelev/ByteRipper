import AgentDocuments
import AgentKit
import CodeAnalysis
import DumpHost
import Foundation
import GhidraHost
import ToolModuleKit
import UEFITool

/// Every tool the server serves (`Design/SERVER_HEADLESS_PLAN.md` §7): the
/// server's own three, the UEFI Structure's queries, the code readings and —
/// with `--ghidra` — Ghidra's review tools with `ghidra_open` by a node.
///
/// What acts on a screen or edits a dump is not here at all
/// (`Design/SERVER_HEADLESS_PLAN.md` decision 7): there is no focus, no
/// panel, no `annotate`, no `reveal`, no `write`. The list is fixed while the
/// server runs.
@MainActor
public enum ServerTools {
    public static func all(documents: DocumentRegistry, store: URL, ghidra: GhidraBackend?) -> [AgentTool] {
        var tools = ServerDocuments.tools(documents)
        tools += queries.map { query in
            ToolQueryTools.tool(for: ServerToolText.query(query), documents: documents,
                                document: ServerDocuments.documentHelp)
        }
        tools += CodeReadings(documents: documents, wording: wording, store: { store },
                              catalogue: { .empty }).tools()
        if let ghidra {
            tools += GhidraNodeOpen.tools(backend: ghidra, documents: documents,
                                          description: ServerToolText.ghidraOpen,
                                          document: ServerDocuments.documentHelp)
        }
        return tools
    }

    /// The UEFI Structure's queries the server serves, in the module's words
    /// (`ServerToolText` rewords some). `region_scan` is not among them: it is
    /// the next stage (`Design/SERVER_HEADLESS_PLAN.md` decision 15).
    static var queries: [ToolAgentQuery] {
        UEFIAgentQueries.all(catalogue: { .empty })
            + UEFIAgentChecksums.all + UEFIAgentDMI.all
            + UEFIAgentVariables.queries + UEFIAgentNodeData.all
    }

    /// `code_query` and `code_modules` in a host's words: the app's name a
    /// Code panel, which this server has not got.
    public static let wording = CodeReadings.Wording(
        query: """
            Read a module's stored code analysis. The module is a PE32/TE image `node` of a dump — \
            `code_modules` lists the ones with an analysis — its bytes hashed to find the analysis; or a \
            `module` SHA-256, read from the store alone. `what` picks the list (default "functions"): \
            "functions"; one function's "instructions" or decompiled "c"; a function's callers and \
            callees ("references"); the instructions that "uses" an address — who calls a function, \
            jumps to a label, or reads a global or a string; "strings"; "symbols", the named data — \
            GUIDs, service tables, interfaces; or "post_codes", the values written to port 0x80 (what a \
            POST card shows), each at the call that supplies it, with the functions it passes through \
            (`via`) — `search` narrows by value — and, last, the writes whose value or port the code does \
            not say (`unresolved`). A function's `name_source` says where its name came from: DEFAULT is \
            Ghidra's FUN_ placeholder, ANALYSIS a name the UEFI pass read from the module (`name_reason` \
            says from what), IMPORTED the image's own. `review_level` is how far the review has got — full, partial, \
            decompiled, library or no_body; null in an analysis made before it was recorded — and \
            `review_gaps` what keeps it from full: name, plate, comments, params, locals. Addresses come twice: `entry`/`address` is \
            Ghidra's virtual address, `offset` the same byte's offset in the module, the number the hex \
            view shows (none when read by `module` alone). These are stored observations, not a live \
            disassembly; the C is Ghidra's reading of the instructions, not the source.
            """,
        modules: """
            The PE32/TE modules of a dump that have a stored code analysis: their image `node`, name, \
            the analyses (`recipes`, newest first) and how many functions the newest found. The modules \
            are found by their bytes — the same module in another dump has the same analysis — including \
            those inside compressed sections, which are opened for it: seconds on a large image the first \
            time. Read one with `code_query`.
            """,
        queryDocument: ServerDocuments.documentHelp,
        modulesDocument: ServerDocuments.documentHelp,
        missingNode: { named in
            "\(named) is a dump, not a module's code. Give the module's image `node` in it — "
                + "`code_modules` lists the ones with an analysis — or a `module` SHA-256."
        })

    /// What the client is told about the tools together, in `initialize` and
    /// `server/discover`. The review rules of the Ghidra skill follow when
    /// Ghidra is served, so an agent without the skill has them too.
    public static func instructions(ghidra: Bool) -> String {
        let host = """
            This server holds the firmware images its operator opened in the console; `documents` lists \
            them. There is no screen and no focus: when more than one is open, name the `document` a call \
            is about. Addresses and sizes are hex strings ("0x7F3000") both ways; ranges are half-open. \
            A list comes in pages: pass `next` back as `after` until it is null. `read` reads bytes of a \
            document's snapshot, `find_bytes` searches them, the `uefi_` tools read a firmware image's \
            structure, `code_query` and `code_modules` read the code store. A node id belongs to the \
            document it was listed on. To the person, name a file by its `name` and a node by its \
            `label`, never by an id (d1, 0.2.5). Nothing here edits a dump or shows anything on a screen; a tool refuses an \
            argument it does not take.
            """
        return ghidra ? host + "\n\n" + GhidraTools.instructions : host
    }
}
