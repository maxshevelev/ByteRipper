import AgentKit
import CodeAnalysis
import Foundation

/// The agent's tools for a review in Ghidra (`Design/SERVER_PLAN.md` §6.4):
/// the same list on the server's `/mcp` and on the app's own MCP server, over
/// whichever `GhidraBackend` the host has. The host holds the write lease; an
/// agent never sees one, and `ghidra_done` publishes and gives it back.
///
/// Names, descriptions and schemas are read by a model and stay in English.
public enum GhidraTools {
    /// How a module is first opened: by its bytes sent with the call (the
    /// server alone), or by a node of a dump open in the app, which reads the
    /// bytes itself and replaces this tool.
    public static func tools(backend: GhidraBackend, includeOpenByImage: Bool = true) -> [AgentTool] {
        var tools = [modulesTool(backend), openTool(backend, byImage: includeOpenByImage)]
        tools += readTools(backend)
        tools += writeTools(backend)
        tools += [publishTool(backend), doneTool(backend)]
        return tools
    }

    /// What the server tells a model about the tools: how a review goes, and
    /// the rules a review keeps (the skill's "What a review makes of the
    /// code"), so an agent without the skill gets them too.
    public static let instructions = """
        These tools review one UEFI module (a PEIM or a DXE driver) in Ghidra: the names, signatures, \
        types and comments a review writes are Ghidra's own and are kept in the module's project between \
        sessions. A module is named by the SHA-256 of its bytes (`module`). Start with `ghidra_modules` \
        or `ghidra_open`; read with `ghidra_functions`, `ghidra_function` (decompiled C, parameters and \
        locals with their storage), `ghidra_disassembly`, `ghidra_xrefs`, `ghidra_data`, `ghidra_strings`, `ghidra_type_definition`, \
        `ghidra_description`; write with `ghidra_rename`, `ghidra_function_create`, `ghidra_rename_variable`, `ghidra_signature`, \
        `ghidra_type`, `ghidra_set_data`, `ghidra_comment`, `ghidra_describe`, `ghidra_code_mode`, `ghidra_equate`, \
        `ghidra_function_tag`. `ghidra_function_tag` marks an EDK2 library routine the module statically links \
        in as `library`, which the artifact records as its review level and needs no further review. `ghidra_publish` makes the review visible to the app — every \
        ByteRipper that reads this store — as a new revision; publish at coherent checkpoints, not after \
        every rename. `ghidra_done` publishes and ends the session.

        A review aims at decompiled C that reads like the module's source:
        1. Names, not constants: a value of a set becomes an enum member and the parameter, field or return \
        type carries the enum (EFI_STATUS values, DEBUG levels, POST and halt codes, vendor ids). Write the \
        tag of a typedef: `typedef enum _NAME { … } NAME;`. A constant an instruction holds — an I/O port, \
        an MSR, a PCI config address — gets its name with `ghidra_equate`, as a member of an enum that \
        groups it, with a comment saying what it stands for and where that is known from; every port \
        write also gets an end-of-line comment saying what the register and the bits are.
        2. Structures, not pointer arithmetic: define the header, entry or record the code walks and type \
        the pointer with it, so the C says `Entry->Size` and `Entries[Index]`. Lay a type out from what the \
        instructions prove; a field nobody can name is `Unknown08`. Give a type a `description` and its \
        fields `comments` with `ghidra_type`: the reader sees them by clicking the name in the C. Fix signatures first: a typed \
        parameter retypes the locals that follow from it, here and in the callers.
        3. Names for what stays: functions, parameters, locals, in the module's convention (EDK2 \
        CamelCase), a function named for what it does for its caller. After a signature change, read the \
        function again before `ghidra_rename_variable`: Ghidra merges and retypes locals.
        4. Comments a source would have: a plate comment on each function that matters (what, why, what \
        it expects and returns or halts with); end-of-line comments where the code cannot say it — the \
        hardware or firmware meaning of a value, a path that does not return. Never paraphrase the line; \
        say what is uncertain. A comment replaces the one there: read it first.
        5. Read it again after a publish: the function and its callers. What still reads as a constant, a \
        cast or `local_` is the next round.
        6. Report defects found (an unbounded buffer, a wrong format) in a comment at their place and to \
        the person; never let them shape a name.
        7. The module's description is a result of the review as much as the code: a Markdown document, \
        kept with the project and published with it, that the app shows beside the code. Write its outline \
        early with `ghidra_describe`, fill and correct one section at a time as the review learns, and \
        leave it true to the code at every publish: the names in it are the names in the program. \
        \(descriptionFormat)
        """

    /// The description's sections, in order, as the skill's
    /// `reference/description.md` sets them; a model reads this.
    static let descriptionFormat = """
        Its sections, in this order, headed exactly so: `# <ModuleName>` and a one-paragraph summary; \
        `## Identity` (file GUID, type, image, base, entry, the board and the module's place in the \
        firmware's layout — never the dump file it was read from, the same module is in every dump of \
        the board — source package and how sure); `## Purpose`; `## Interfaces` (what it consumes and \
        produces — PPIs, protocols, HOBs, variables, callbacks — a table: interface, GUID, kind, where); `## Flow` (numbered, from the \
        entry point); `## Internal structure` (functions by role, globals, tables, the review's types); \
        `## Hardware and data`; `## Errors and diagnostics` (status, POST and halt codes, messages, \
        what the bench sees); `## Findings`; `## Open questions`; `## Review status`. A section with \
        nothing to say yet is left out. Link a function as `[Name](0xADDRESS)`; the app follows it. \
        Mark what is not proven (`probably`, `not confirmed`). Markdown: headings, paragraphs, `-` and \
        `1.` lists, tables, fenced code, `code`, **bold**, *italic*, links.
        """

    // MARK: - The tools

    static let moduleProperty = AgentSchema.string("The module: the SHA-256 of its bytes, as `ghidra_modules` lists it.")

    static func modulesTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_modules",
            title: "List the modules kept in Ghidra",
            description: """
                The modules that have a kept Ghidra project: `module` (SHA-256), `name`, whether an owner \
                is `running`, whether the project holds a review (`reviewed`), and its last publish \
                (`published`: artifact, recipe, revision).
                """
        ) { _ in
            try await answer { try await backend.listModules() }
        }
    }

    static func openTool(_ backend: GhidraBackend, byImage: Bool) -> AgentTool {
        var properties: [String: JSONValue] = ["module": moduleProperty]
        if byImage {
            properties["image_base64"] = AgentSchema.string(
                "Or the module's PE32/TE image, base64, for a module that has no project yet.")
            properties["name"] = AgentSchema.string("With `image_base64`: what to call the module, e.g. \"CpuPei\".")
        }
        return AgentTool(
            name: "ghidra_open",
            title: "Open a module in Ghidra",
            description: """
                Starts the module's owner — Ghidra holding its project open — and answers its `hello`: \
                program, functions, whether there are unpublished changes. The owner saves the program \
                when it idles out, is stopped or gets a signal, so work between publishes survives a \
                server restart — only an owner killed outright or crashed loses it. A module seen before is opened \
                by `module`.\(byImage ? " A new one is sent as `image_base64` with a `name`: its project is made first — Ghidra's analysis and the UEFI pass, seconds for a PEIM, a minute for a large DXE driver." : "")
                """,
            inputSchema: AgentSchema.object(properties),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: true)
        ) { call in
            let arguments = call.arguments
            if byImage, let text = try arguments.optionalString("image_base64") {
                guard let image = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
                    throw AgentToolError("`image_base64` is not base64.")
                }
                let name = try arguments.optionalString("name") ?? "module"
                return try await answer { try await backend.openImage(image, name: name, document: nil, node: nil) }
            }
            let module = try module(arguments)
            return try await answer { try await backend.openModule(module) }
        }
    }

    static func readTools(_ backend: GhidraBackend) -> [AgentTool] {
        let paging: [String: JSONValue] = [
            "module": moduleProperty,
            "offset": AgentSchema.integer("How many to skip. Default 0."),
            "limit": AgentSchema.limit(default: 200, maximum: 1000)
        ]
        func paged(_ name: String, _ call: String, _ title: String, _ description: String) -> AgentTool {
            AgentTool(name: name, title: title, description: description,
                      inputSchema: AgentSchema.object(paging, required: ["module"])) { call_ in
                let arguments = call_.arguments
                let module = try module(arguments)
                var query: [String: String] = ["limit": String(try arguments.limit(default: 200, maximum: 1000))]
                if arguments.has("offset") { query["offset"] = String(try arguments.integer("offset")) }
                return try await answer { try await backend.readCall(module, call, query: query) }
            }
        }
        return [
            AgentTool(
                name: "ghidra_functions",
                title: "List a module's functions",
                description: """
                    The module's functions as Ghidra holds them now: entry, name, name_source, size, \
                    signature. `name_contains` and `name_source` (a Ghidra source such as USER_DEFINED) \
                    narrow the list, `address_from`/`address_to` narrow it by entry. `filter: \
                    "unfinished"` keeps what a review has not passed — a parameter or a local Ghidra \
                    still names itself or holds as `undefined`, or no plate comment — each with \
                    `leftovers`, and `summary` says how many of how many; that filter decompiles every \
                    function, so it is slow on a large module. `leftovers.fragments` counts the \
                    register and `unique:` pieces the decompiler splits off while a review types a \
                    function — its own artefacts, which do not make a function unfinished. Paged by \
                    `offset` and `limit`; `next` says where the next page starts.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "offset": AgentSchema.integer("How many to skip. Default 0."),
                    "limit": AgentSchema.limit(default: 200, maximum: 1000),
                    "filter": AgentSchema.choice(["unfinished"], "Only the functions a review has not passed."),
                    "name_contains": AgentSchema.string("Only functions whose name holds this text."),
                    "name_source": AgentSchema.string(
                        "Only functions from this Ghidra source: DEFAULT, ANALYSIS, IMPORTED, USER_DEFINED."),
                    "address_from": AgentSchema.offset("Only functions whose entry is at or after this address."),
                    "address_to": AgentSchema.offset("Only functions whose entry is at or before this address.")
                ], required: ["module"])
            ) { call_ in
                let arguments = call_.arguments
                let module = try module(arguments)
                var query: [String: String] = ["limit": String(try arguments.limit(default: 200, maximum: 1000))]
                if arguments.has("offset") { query["offset"] = String(try arguments.integer("offset")) }
                if let filter = try arguments.optionalString("filter") { query["filter"] = filter }
                if let contains = try arguments.optionalString("name_contains") { query["name_contains"] = contains }
                if let source = try arguments.optionalString("name_source") { query["name_source"] = source }
                if let from = try arguments.optionalOffset("address_from") {
                    query["address_from"] = String(format: "0x%llX", from)
                }
                if let to = try arguments.optionalOffset("address_to") {
                    query["address_to"] = String(format: "0x%llX", to)
                }
                return try await answer { try await backend.readCall(module, "functions", query: query) }
            },
            AgentTool(
                name: "ghidra_function",
                title: "Read one function",
                description: """
                    One function as Ghidra holds it now: its signature, its parameters and locals with \
                    their `storage` and `first_use` (what `ghidra_rename_variable` names a local by), its \
                    plate comment, what is left to name (`leftovers`, whose `fragments` are the \
                    decompiler's register pieces rather than missing names), and its decompiled C — \
                    fresh after every write, ahead of what the app shows until a publish. \
                    `summary: true` leaves the C and the equates out, for walking a module without \
                    its text.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "address": AgentSchema.string("The function's entry address, e.g. \"0x68A\"."),
                    "summary": AgentSchema.boolean(
                        "Leave out the decompiled C and the equates: signature, parameters, locals, "
                        + "plate, leftovers.")
                ], required: ["module", "address"])
            ) { call in
                let module = try module(call.arguments)
                let address = try call.arguments.string("address")
                var query: [String: String] = [:]
                if try call.arguments.bool("summary", default: false) { query["summary"] = "1" }
                return try await answer { try await backend.readCall(module, "function/\(address)", query: query) }
            },
            AgentTool(
                name: "ghidra_disassembly",
                title: "Read a function's instructions",
                description: "The instructions of the function at `address`, with their bytes, references and "
                    + "the names of their constants (`equates`). A large function comes in pages: `limit` "
                    + "instructions from `from`; `next` is the address to pass as `from` for the rest.",
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "address": AgentSchema.string("An address in the function."),
                    "from": AgentSchema.string("The first instruction of the page. Default: the function's first."),
                    "limit": AgentSchema.integer("The most instructions in the page. Default: all.")
                ], required: ["module", "address"])
            ) { call in
                let module = try module(call.arguments)
                let address = try call.arguments.string("address")
                var query: [String: String] = [:]
                if let from = try call.arguments.optionalString("from") { query["from"] = from }
                if call.arguments.has("limit") { query["limit"] = String(try call.arguments.integer("limit")) }
                return try await answer { try await backend.readCall(module, "disassembly/\(address)", query: query) }
            },
            AgentTool(
                name: "ghidra_xrefs",
                title: "Find references",
                description: "The references `to` an address (who calls a function, reads a global) or `from` one.",
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "to": AgentSchema.string("References to this address."),
                    "from": AgentSchema.string("Or references from this address.")
                ], required: ["module"])
            ) { call in
                let arguments = call.arguments
                let module = try module(arguments)
                var query: [String: String] = [:]
                if let to = try arguments.optionalString("to") { query["to"] = to }
                if let from = try arguments.optionalString("from") { query["from"] = from }
                guard query.count == 1 else { throw AgentToolError("Give `to` or `from`, one of them.") }
                return try await answer { try await backend.readCall(module, "xrefs", query: query) }
            },
            paged("ghidra_data", "data", "List a module's defined data",
                  "The defined data — named globals, GUIDs, tables — with address, name and type. Paged."),
            paged("ghidra_strings", "strings", "List a module's strings",
                  "The strings Ghidra found, with address and value. Paged."),
            AgentTool(
                name: "ghidra_description",
                title: "Read the module's description",
                description: """
                    The module's description as the project holds it now: `text` (Markdown, null while \
                    there is none), its `sections` (the `## ` headings, in order) and its size in \
                    `bytes`. Read it before `ghidra_describe` changes it.
                    """,
                inputSchema: AgentSchema.object(["module": moduleProperty], required: ["module"])
            ) { call in
                let module = try module(call.arguments)
                return try await answer { try await backend.readCall(module, "description", query: [:]) }
            },
            AgentTool(
                name: "ghidra_type_definition",
                title: "Read a type's definition",
                description: """
                    The type `name` three ways: as the module's program holds it (`program`), as the \
                    shared review archive holds it now (`shared`, what another review published), and as \
                    the EDK2 archive holds it (`edk2`); each is null where that place has no such type. \
                    Each has its C, `size`, and for a structure or union every field's `offset`, `size`, \
                    `name`, `type` and `comment`, with `packing` and `packing_value`. `same` says whether \
                    the program's and the shared one agree. A name and its tag find each other — `NAME` \
                    finds `_NAME` and the other way round; `resolved` gives the name that answered. \
                    `found` says whether any of the three has the type, and `near` lists close names when \
                    none does. Read the types `ghidra_publish` reports in `type_conflicts` with it, and \
                    bring yours in line with `ghidra_type`.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "name": AgentSchema.string("The type's name, e.g. \"EFI_PEI_SERVICES\" or \"AMD_APOB_HEADER\".")
                ], required: ["module", "name"])
            ) { call in
                let module = try module(call.arguments)
                let name = try call.arguments.string("name")
                return try await answer { try await backend.readCall(module, "type", query: ["name": name]) }
            },
            AgentTool(
                name: "ghidra_types",
                title: "List the module's types",
                description: """
                    The types the program holds — what a review defined and what the module used — with \
                    `kind` (struct, union, enum, typedef, function, pointer, array), `size` and `source` \
                    (the program, or the archive the type came from). `contains` narrows by name, \
                    `kind` by what a type is — one kind, or several separated by commas — `source` by \
                    origin, and `builtin` adds Ghidra's own types, left out by default. `sources` lists \
                    every origin the program's types hold — the reviews' archive included — so `source` \
                    is named rather than guessed. Paged by `offset` and `limit`; `total` is how many \
                    match.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "contains": AgentSchema.string("Only types whose name holds this text."),
                    "kind": AgentSchema.string(
                        "Only types of this kind — struct, union, enum, typedef, function, pointer, array — "
                        + "or of several, separated by commas."),
                    "source": AgentSchema.string("Only types from this origin: \"program\", or an archive's name."),
                    "builtin": AgentSchema.boolean("Add Ghidra's own types. Default false."),
                    "offset": AgentSchema.integer("How many to skip. Default 0."),
                    "limit": AgentSchema.limit(default: 200, maximum: 1000)
                ], required: ["module"])
            ) { call in
                let arguments = call.arguments
                let module = try module(arguments)
                var query: [String: String] = ["limit": String(try arguments.limit(default: 200, maximum: 1000))]
                if arguments.has("offset") { query["offset"] = String(try arguments.integer("offset")) }
                if let contains = try arguments.optionalString("contains") { query["contains"] = contains }
                if let kind = try arguments.optionalString("kind") { query["kind"] = kind }
                if let source = try arguments.optionalString("source") { query["source"] = source }
                if try arguments.bool("builtin", default: false) { query["builtin"] = "1" }
                return try await answer { try await backend.readCall(module, "types", query: query) }
            }
        ]
    }

    static func writeTools(_ backend: GhidraBackend) -> [AgentTool] {
        func write(_ name: String, _ call: String, _ title: String, _ description: String,
                   _ properties: [String: JSONValue], required: [String],
                   body: @escaping @Sendable (AgentArguments) throws -> [String: JSONValue]) -> AgentTool {
            var all = properties
            all["module"] = moduleProperty
            return AgentTool(name: name, title: title, description: description,
                             inputSchema: AgentSchema.object(all, required: ["module"] + required),
                             annotations: .edit) { call_ in
                let arguments = call_.arguments
                let module = try module(arguments)
                let payload = JSONValue.object(try body(arguments)).encoded()
                return try await answer { try await backend.writeCall(module, call, body: payload) }
            }
        }
        @Sendable func optional(_ arguments: AgentArguments, _ names: [String]) throws -> [String: JSONValue] {
            var found: [String: JSONValue] = [:]
            for name in names {
                if let value = try arguments.optionalString(name) { found[name] = .string(value) }
            }
            return found
        }
        return [
            write("ghidra_rename", "rename/function", "Name a function",
                  "Names the function at `address`. Any address inside a function names that function, "
                  + "and the answer says which it matched (`matched: \"entry\"` or `\"containing\"`); an "
                  + "address that carries a label is refused — a label is named with `ghidra_label`, "
                  + "which is not this call. A name Ghidra would make unique (`Foo_1`) is refused: "
                  + "choose another. `reason` says why, as the app shows it.",
                  ["address": AgentSchema.string("The function's entry address, or any address inside it."),
                   "name": AgentSchema.string("The new name."),
                   "reason": AgentSchema.string("Why this name, in a few words.")],
                  required: ["address", "name"]) { arguments in
                var body = try optional(arguments, ["address", "name", "reason"])
                body["by"] = "agent"
                return body
            },
            write("ghidra_label", "rename/label", "Name a branch label",
                  "Names the label at `address` — a jump target the C prints as `LAB_<address>`, which is a "
                  + "step of the flow: an error exit, a loop's head, the place a structure starts being "
                  + "read. `ghidra_rename` names functions only: given an address inside one it renames the "
                  + "function, so a label needs this call. A function's entry, and an address no "
                  + "instruction starts at, are refused. An empty `name` deletes the label there.",
                  ["address": AgentSchema.string("The label's address, e.g. \"0x9A05373\"."),
                   "name": AgentSchema.string("The new name, e.g. \"ErrorHeaderDoesNotFit\"."),
                   "reason": AgentSchema.string("Why this name, in a few words.")],
                  required: ["address", "name"]) { arguments in
                var body = try optional(arguments, ["address", "name", "reason"])
                body["by"] = "agent"
                return body
            },
            write("ghidra_function_create", "create/function", "Make a function where Ghidra made none",
                  "Makes a function at `address`: code only a table points at — a slot of a services table, "
                  + "a member of a PPI or a protocol — which no call names, so Ghidra left it outside any "
                  + "function and `ghidra_rename` finds nothing there. Disassembles it first if needed. "
                  + "With `name`, names it as `ghidra_rename` would. A function already there is answered as it is.",
                  ["address": AgentSchema.string("The entry address, e.g. the value in the table's slot."),
                   "name": AgentSchema.string("A name for it, optional."),
                   "reason": AgentSchema.string("Why this name, in a few words.")],
                  required: ["address"]) { arguments in
                var body = try optional(arguments, ["address", "name", "reason"])
                body["by"] = "agent"
                return body
            },
            AgentTool(
                name: "ghidra_rename_variable",
                title: "Name or type a parameter or a local",
                description: """
                    Names, and perhaps types, a local by its `storage` and, for a register, \
                    `first_use` — as `ghidra_function` lists them — or a parameter by its `ordinal`. \
                    Never by Ghidra's own name for it (`iVar4`): those renumber. `type` alone types it \
                    and keeps the name. After any call, read the function again: a local's `storage` \
                    can change, and a type alone gives it a `HASH:` storage. `items` does several in \
                    one call, each in a transaction of its own: the answer lists what applied and why \
                    an entry did not. A name already held is answered with the holder — its kind, \
                    address and `storage` — and that storage renames the holder, even one the \
                    decompiler no longer shows (the answer then says `stale: true`); freeing the name \
                    is what lets the local take it.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "function": AgentSchema.string(
                        "The function's entry address; with `items`, the function they all belong to."),
                    "name": AgentSchema.string("The new name; leave it out to type only."),
                    "storage": AgentSchema.string("The local's storage, e.g. \"EAX:4\" or \"Stack[-0x18]:4\"."),
                    "first_use": AgentSchema.string("For a register local: the address of its first use."),
                    "ordinal": AgentSchema.integer("Or a parameter by its position, from 0."),
                    "type": AgentSchema.string("A C type for it, e.g. \"EFI_PEI_SERVICES **\"."),
                    "items": ["type": "array",
                              "items": AgentSchema.object([
                                  "name": AgentSchema.string("The new name; leave it out to type only."),
                                  "storage": AgentSchema.string("The local's storage."),
                                  "first_use": AgentSchema.string(
                                      "For a register local: the address of its first use."),
                                  "ordinal": AgentSchema.integer("Or a parameter by its position, from 0."),
                                  "type": AgentSchema.string("A C type for it.")
                              ]),
                              "description": "Several variables of the function in one call."]
                ], required: ["module", "function"]),
                annotations: .edit
            ) { call_ in
                let arguments = call_.arguments
                let module = try module(arguments)
                let function = try arguments.string("function")
                if let items = arguments["items"] {
                    guard case .array(let list) = items else {
                        throw AgentToolError("`items` is a list of variables.")
                    }
                    var requests: [JSONValue] = []
                    for item in list {
                        guard case .object(var fields) = item else {
                            throw AgentToolError("An item of `items` is an object.")
                        }
                        fields["function"] = .string(function)
                        requests.append(.object(fields))
                    }
                    let payload = JSONValue.object(["items": .array(requests)]).encoded()
                    return try await answer {
                        try await backend.writeCall(module, "rename/variables", body: payload)
                    }
                }
                guard try arguments.optionalString("name") != nil || arguments.has("type") else {
                    throw AgentToolError("Give `name`, `type`, or both — or `items` for several variables.")
                }
                var body = try optional(arguments, ["function", "name", "storage", "first_use", "type"])
                if arguments.has("ordinal") { body["ordinal"] = .int(try arguments.integer("ordinal")) }
                let payload = JSONValue.object(body).encoded()
                return try await answer { try await backend.writeCall(module, "rename/variable", body: payload) }
            },
            write("ghidra_signature", "set/signature", "Set a function's signature",
                  "Sets the C signature of the function at `address`, the EDK2 way if wanted "
                  + "(`EFI_STATUS EFIAPI Foo (IN CONST EFI_PEI_SERVICES **PeiServices)`). Types the module "
                  + "lacks come from the EDK2 archive or from types a review defined. For a function no "
                  + "calling convention fits — a linker's clone that takes an argument in EDX, or returns "
                  + "through a pointer in ECX — give `storage`, one place per parameter as `ghidra_function` "
                  + "lists storage (`[\"ECX:4\", \"Stack[0x4]:4\"]`), and `return_storage` if the result is "
                  + "not where the convention puts it (`EDX:4,EAX:4` for 64 bits, high part first, `void`). "
                  + "Then no dummy parameter is needed for a register the function does not read.",
                  ["address": AgentSchema.string("The function's entry address."),
                   "signature": AgentSchema.string("The C prototype."),
                   "storage": .object(["type": "array", "items": .object(["type": "string"]),
                                       "description": "Where each parameter is, in order: \"EDX:4\", \"Stack[0x4]:4\"."]),
                   "return_storage": AgentSchema.string("Where the result is: \"EAX:4\", \"EDX:4,EAX:4\", \"void\"."),
                   "reason": AgentSchema.string("Why, in a few words.")],
                  required: ["address", "signature"]) { arguments in
                var body = try optional(arguments, ["address", "signature", "return_storage", "reason"])
                if arguments.has("storage") {
                    guard case .array(let places)? = arguments["storage"],
                          places.allSatisfy({ $0.stringValue != nil }) else {
                        throw AgentToolError("`storage` is a list of places, one string per parameter.")
                    }
                    body["storage"] = .array(places)
                }
                body["by"] = "agent"
                return body
            },
            AgentTool(
                name: "ghidra_comment",
                title: "Write a comment",
                description: """
                    Sets the comment of `kind` at `address`, replacing the one there; empty `text` \
                    clears it. A plate comment heads a function in the C; pre and eol comments show in \
                    the C too. A comment is printed where the decompiler prints the instruction it sits \
                    on: a step folded into one expression (`&&`, a nested call) may show at the start of \
                    that block, or not at all — so a step is safest at the first instruction of its block, \
                    and the plate carries what the body cannot show. `items` writes several in one call, \
                    each in a transaction of its own.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "address": AgentSchema.string("The address."),
                    "text": AgentSchema.string("The comment; empty clears it."),
                    "kind": AgentSchema.choice(["pre", "post", "eol", "plate", "repeatable"], "Default \"pre\"."),
                    "items": ["type": "array",
                              "items": AgentSchema.object([
                                  "address": AgentSchema.string("The address."),
                                  "text": AgentSchema.string("The comment; empty clears it."),
                                  "kind": AgentSchema.choice(["pre", "post", "eol", "plate", "repeatable"],
                                                             "Default \"pre\".")
                              ], required: ["address", "text"]),
                              "description": "Several comments in one call."]
                ], required: ["module"]),
                annotations: .edit
            ) { call_ in
                let arguments = call_.arguments
                let module = try module(arguments)
                if let items = arguments["items"] {
                    guard case .array(let list) = items else {
                        throw AgentToolError("`items` is a list of comments.")
                    }
                    for item in list {
                        guard case .object = item else {
                            throw AgentToolError("An item of `items` is an object.")
                        }
                    }
                    let payload = JSONValue.object(["items": .array(list)]).encoded()
                    return try await answer { try await backend.writeCall(module, "set/comments", body: payload) }
                }
                guard arguments.has("address"), arguments.has("text") else {
                    throw AgentToolError("Give `address` and `text` — or `items` for several comments.")
                }
                let body = try optional(arguments, ["address", "text", "kind"])
                let payload = JSONValue.object(body).encoded()
                return try await answer { try await backend.writeCall(module, "set/comment", body: payload) }
            },
            write("ghidra_code_mode", "set/code-mode", "Read a range as 16-bit or 32-bit code",
                  "Reads the code in [`start`, `end`) as 16-bit or as 32-bit x86. A 32-bit module holds "
                  + "16-bit code at its reset vector (real mode, before the switch to protected mode), "
                  + "which Ghidra decodes as 32-bit and so gets wrong: overlapping instructions, nonsense "
                  + "C. The instructions in the range are cleared and decoded again from `start` in the "
                  + "given size, without leaving the range; functions there get their bodies fixed. "
                  + "Addresses stay offsets: real-mode segments are not modelled, so a `cs:[F490h]` "
                  + "operand names F490h, not where it lands. `ghidra_disassembly` marks 16-bit "
                  + "instructions `bits: 16`. Defined data in the range is refused: clear it first.",
                  ["start": AgentSchema.string("The first address of the code, e.g. \"0x9DFE6E0\"."),
                   "end": AgentSchema.string("The first address past it: the range is [start, end)."),
                   "bits": ["type": "integer", "enum": [16, 32], "description": "The operand and address size."],
                   "reason": AgentSchema.string("Why, in a few words: what shows the code is 16-bit.")],
                  required: ["start", "end", "bits"]) { arguments in
                var body = try optional(arguments, ["start", "end", "reason"])
                let bits = try arguments.integer("bits")
                guard bits == 16 || bits == 32 else { throw AgentToolError("`bits` is 16 or 32.") }
                body["bits"] = .int(bits)
                body["by"] = "agent"
                return body
            },
            write("ghidra_equate", "set/equate", "Name a constant in an instruction",
                  "Names a constant an instruction holds — an I/O port (`PCI_CONFIG_ADDRESS` for 0xCF8), "
                  + "an MSR or register index, a magic value — as a Ghidra equate on that operand; the "
                  + "disassembly and the C show the name instead of the number, also where the number "
                  + "reaches an `out()` through a register. `value` picks the operand that holds it; "
                  + "`operand` picks one by index instead. Empty `name` removes it. One name stands for "
                  + "one value: a name already used for another is refused. A number the code computes "
                  + "(`ADD DL,4` to reach 0xCFC) is in no operand and gets a comment instead. "
                  + "Give every name an `enum` that groups it (`FCH_IO_PORT`, `AMD_MSR`, `LPC_DECODE_BITS`) "
                  + "and a `comment`: what the name stands for and where that is known from (a spec and "
                  + "its section, a coreboot or EDK2 header, the PPR, or `not confirmed`). The app shows "
                  + "the comment when the reader clicks the name, and the enum is shared with the next "
                  + "module reviewed, so a name given once brings its comment along: later, `name` and "
                  + "`enum` are enough. One value has one name in an enum.",
                  ["address": AgentSchema.string("The instruction's address."),
                   "name": AgentSchema.string("A C identifier, in the module's convention; empty removes it."),
                   "value": AgentSchema.string("The constant, e.g. \"0xCF8\", to pick the operand that holds it."),
                   "operand": AgentSchema.integer("Or the operand by its index, from 0."),
                   "enum": AgentSchema.string("The enum the name is a member of; made when missing."),
                   "comment": AgentSchema.string("What the name stands for and its source; replaces the member's comment."),
                   "enum_comment": AgentSchema.string("What the enum groups, e.g. \"FCH legacy I/O ports\".")],
                  required: ["address", "name"]) { arguments in
                var body = try optional(arguments, ["address", "name", "value", "enum", "comment", "enum_comment"])
                if arguments.has("operand") { body["operand"] = .int(try arguments.integer("operand")) }
                return body
            },
            write("ghidra_function_tag", "tag/function", "Tag a function",
                  "Tags the function containing `address`, as the other function writes find it. `tag` "
                  + "\"library\" marks an EDK2 library routine the module statically links in (`CopyMem`, "
                  + "`ZeroMem`, `AsmReadMsr64`, …) that the automatic detection did not recognise: the "
                  + "exported code artifact records a function carrying that tag at the `library` review "
                  + "level, complete as it is, whatever its name or comments. An empty `tag`, or `none`, "
                  + "removes the `library` tag. The answer lists the function's tags, sorted.",
                  ["address": AgentSchema.string("The function's entry address, or any address inside it."),
                   "tag": AgentSchema.string("The tag, e.g. \"library\"; empty or \"none\" removes the library tag.")],
                  required: ["address", "tag"]) { arguments in
                try optional(arguments, ["address", "tag"])
            },
            write("ghidra_set_data", "set/data", "Name or type a datum",
                  "Names and/or types the datum at `address`, e.g. a GUID or a table.",
                  ["address": AgentSchema.string("The address."),
                   "name": AgentSchema.string("Its name."),
                   "type": AgentSchema.string("Its C type, e.g. \"EFI_GUID\" or \"UINT32[4]\".")],
                  required: ["address"]) { arguments in
                try optional(arguments, ["address", "name", "type"])
            },
            write("ghidra_describe", "set/description", "Write the module's description",
                  "Writes the module's description — Markdown, what the module is for, how it works and how "
                  + "it is built — kept in the project and published with the review as an object of its "
                  + "own, which the app shows beside the code. With `section`, `text` replaces the body of "
                  + "that `## ` section only (added at the end if missing; empty `text` removes it); without "
                  + "it, `text` is the whole description (empty clears it). Up to 256 KiB. "
                  + descriptionFormat,
                  ["text": AgentSchema.string("The Markdown: the whole description, or one section's body without its heading."),
                   "section": AgentSchema.string("The `## ` heading whose body `text` replaces, e.g. \"Flow\".")],
                  required: ["text"]) { arguments in
                var body: [String: JSONValue] = ["text": .string(try arguments.string("text"))]
                if let section = try arguments.optionalString("section") { body["section"] = .string(section) }
                return body
            },
            write("ghidra_type", "type", "Define a type",
                  "Adds a structure, union, enum or typedef from C to the module, shared with modules opened "
                  + "after the next publish. Write the tag: `typedef struct _NAME { … } NAME;`. Without `c`, "
                  + "`name` picks a type the module or its archives hold. `description` says what the type is "
                  + "and where its layout is known from; `comments` gives fields or enum members theirs — what "
                  + "each holds and its source. The app shows them when the reader clicks the type or a field; "
                  + "an empty comment removes one. Comments are set after the C, which drops its own — a type "
                  + "defined again keeps its fields' comments and its description, and the answer says how "
                  + "many comments came back (`comments_kept`; it counts a redefinition, so it is 0 when no "
                  + "`c` is given), whether the C declares what the program already held (`unchanged`) and "
                  + "gives the type's `size`. A structure is laid out by the compiler spec "
                  + "unless the C says otherwise: `#pragma pack(1)` … `#pragma pack()` is how a packed record is "
                  + "written, and `size` beside the field offsets is how a wrong layout shows. "
                  + "`delete: true` with `name` removes a type the program holds — a probe or a mistake — so a "
                  + "publish cannot carry it; a type an archive holds is refused.",
                  ["c": AgentSchema.string("The C text."),
                   "name": AgentSchema.string("Without `c`: the type to describe, comment or delete."),
                   "description": AgentSchema.string("What the type is, and its source."),
                   "delete": AgentSchema.boolean("Remove the type `name` from the program. No `c` with it."),
                   "comments": ["type": "object", "additionalProperties": ["type": "string"],
                                "description": "A comment per field or enum member, by its name."]],
                  required: []) { arguments in
                var body = try optional(arguments, ["c", "name", "description"])
                if try arguments.bool("delete", default: false) {
                    guard body["c"] == nil, body["name"] != nil else {
                        throw AgentToolError("`delete` takes `name` and no `c`.")
                    }
                    body["delete"] = .bool(true)
                }
                guard body["c"] != nil || body["name"] != nil else {
                    throw AgentToolError("Give the type's `c`, or the `name` of one the module holds.")
                }
                if let comments = arguments["comments"] {
                    guard let members = comments.objectValue, members.values.allSatisfy({ $0.stringValue != nil }) else {
                        throw AgentToolError("Argument `comments`: expected an object of strings.")
                    }
                    body["comments"] = .object(members)
                }
                return body
            }
        ]
    }

    static func publishTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_publish",
            title: "Publish the review",
            description: """
                Saves the module's program and stores its artifact and review document as the next \
                revision: every ByteRipper reading this store shows the new names. Publishing an unchanged \
                program is the same revision. `type_conflicts` names types another review defines \
                differently, which stay in this module only: `ghidra_type_definition` shows both, and \
                `type_conflict_origins` names the module that wrote the shared copy. \
                `take_type_conflicts: true` replaces the shared copy of each conflicting type with this \
                module's — the answer to a layout that was published wrong, and never an enum, whose \
                clashing member means one of the two reviews is wrong. The types replaced come back as \
                `type_conflicts_taken`, a typedef and the structure it names each named, since the archive \
                holds them separately; a dry run with both flags says what would be taken. \
                `dry_run: true` answers the same without storing: the artifact's counts, the revision \
                it would become, the description's size and the type conflicts — the export is done, so \
                it costs what a publish costs. Publishing is the point another host sees the work; the \
                owner also writes the program out when it idles out, is stopped or gets a signal — not \
                after every change — so only an owner killed outright or crashed loses what came after \
                the last publish.
                """,
            inputSchema: AgentSchema.object([
                "module": moduleProperty,
                "dry_run": AgentSchema.boolean(
                    "Answer what a publish would store — counts, the revision, the conflicts — and store nothing."),
                "take_type_conflicts": AgentSchema.boolean(
                    "Replace the shared copy of each conflicting type with this module's. An enum is never taken.")
            ], required: ["module"]),
            annotations: .edit
        ) { call in
            let module = try module(call.arguments)
            let take = try call.arguments.bool("take_type_conflicts", default: false)
            if try call.arguments.bool("dry_run", default: false) {
                return try await answer {
                    try await backend.publishPreview(module, takeTypeConflicts: take)
                }
            }
            return try await answer { try await backend.publishModule(module, by: "agent", takeTypeConflicts: take) }
        }
    }

    static func doneTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_done",
            title: "End the review session",
            description: "Publishes what this session changed and gives the module's write lease back, so "
                + "another session or a person can write.",
            inputSchema: AgentSchema.object(["module": moduleProperty], required: ["module"]),
            annotations: .edit
        ) { call in
            let module = try module(call.arguments)
            return try await answer { try await backend.releaseModule(module, by: "agent") }
        }
    }

    // MARK: -

    public static func module(_ arguments: AgentArguments) throws -> SHA256Digest {
        let text = try arguments.string("module")
        guard let digest = SHA256Digest(hex: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AgentToolError("`module` is the SHA-256 of the module's bytes: 64 hex digits.")
        }
        return digest
    }

    /// The backend's JSON as the tool's answer; its refusal as a tool error
    /// the model reads.
    public static func answer(_ body: () async throws -> Data) async throws -> AgentAnswer {
        do {
            let data = try await body()
            guard let value = try? JSONValue.parse(data) else {
                return .text(String(decoding: data, as: UTF8.self))
            }
            return .json(value)
        } catch let error as GhidraHostError {
            throw AgentToolError(error.message)
        }
    }
}
