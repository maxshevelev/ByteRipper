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
        `ghidra_type`, `ghidra_set_data`, `ghidra_comment`, `ghidra_describe`. `ghidra_publish` makes the review visible to the app — every \
        ByteRipper that reads this store — as a new revision; publish at coherent checkpoints, not after \
        every rename. `ghidra_done` publishes and ends the session.

        A review aims at decompiled C that reads like the module's source:
        1. Names, not constants: a value of a set becomes an enum member and the parameter, field or return \
        type carries the enum (EFI_STATUS values, DEBUG levels, POST and halt codes, vendor ids). Write the \
        tag of a typedef: `typedef enum _NAME { … } NAME;`.
        2. Structures, not pointer arithmetic: define the header, entry or record the code walks and type \
        the pointer with it, so the C says `Entry->Size` and `Entries[Index]`. Lay a type out from what the \
        instructions prove; a field nobody can name is `Unknown08`. Fix signatures first: a typed \
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
        `## Identity` (file GUID, type, image, base, entry, where it was found, source package and how \
        sure); `## Purpose`; `## Interfaces` (what it consumes and produces — PPIs, protocols, HOBs, \
        variables, callbacks — a table: interface, GUID, kind, where); `## Flow` (numbered, from the \
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
                program, functions, whether there are unpublished changes. A module seen before is opened \
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
            paged("ghidra_functions", "functions", "List a module's functions",
                  "The module's functions as Ghidra holds them now: entry, name, name_source, size, signature. "
                  + "Paged by `offset` and `limit`; `more` says whether there are more."),
            AgentTool(
                name: "ghidra_function",
                title: "Read one function",
                description: """
                    One function as Ghidra holds it now: its signature, its parameters and locals with \
                    their `storage` and `first_use` (what `ghidra_rename_variable` names a local by), its \
                    comments, and its decompiled C — fresh after every write, ahead of what the app shows \
                    until a publish.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "address": AgentSchema.string("The function's entry address, e.g. \"0x68A\".")
                ], required: ["module", "address"])
            ) { call in
                let module = try module(call.arguments)
                let address = try call.arguments.string("address")
                return try await answer { try await backend.readCall(module, "function/\(address)", query: [:]) }
            },
            AgentTool(
                name: "ghidra_disassembly",
                title: "Read a function's instructions",
                description: "The instructions of the function at `address`, with their bytes and references.",
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "address": AgentSchema.string("An address in the function.")
                ], required: ["module", "address"])
            ) { call in
                let module = try module(call.arguments)
                let address = try call.arguments.string("address")
                return try await answer { try await backend.readCall(module, "disassembly/\(address)", query: [:]) }
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
                    the EDK2 archive holds it (`edk2`); a key is left out where the type is not. Each has its C, `size`, and \
                    for a structure or union every field's `offset`, `size`, `name` and `type`. `same` says \
                    whether the program's and the shared one agree. Read the types `ghidra_publish` reports \
                    in `type_conflicts` with it, and bring yours in line with `ghidra_type`.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "name": AgentSchema.string("The type's name, e.g. \"EFI_PEI_SERVICES\" or \"AMD_APOB_HEADER\".")
                ], required: ["module", "name"])
            ) { call in
                let module = try module(call.arguments)
                let name = try call.arguments.string("name")
                return try await answer { try await backend.readCall(module, "type", query: ["name": name]) }
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
                  "Names the function at `address`. A name Ghidra would make unique (`Foo_1`) is refused: "
                  + "choose another. `reason` says why, as the app shows it.",
                  ["address": AgentSchema.string("The function's entry address."),
                   "name": AgentSchema.string("The new name."),
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
            write("ghidra_rename_variable", "rename/variable", "Name a parameter or a local",
                  "Names, and perhaps types, a local by its `storage` and, for a register, `first_use` — as "
                  + "`ghidra_function` lists them — or a parameter by its `ordinal`. Never by Ghidra's own "
                  + "name for it (`iVar4`): those renumber.",
                  ["function": AgentSchema.string("The function's entry address."),
                   "name": AgentSchema.string("The new name."),
                   "storage": AgentSchema.string("The local's storage, e.g. \"EAX:4\" or \"Stack[-0x18]:4\"."),
                   "first_use": AgentSchema.string("For a register local: the address of its first use."),
                   "ordinal": AgentSchema.integer("Or a parameter by its position, from 0."),
                   "type": AgentSchema.string("A C type for it, e.g. \"EFI_PEI_SERVICES **\".")],
                  required: ["function", "name"]) { arguments in
                var body = try optional(arguments, ["function", "name", "storage", "first_use", "type"])
                if arguments.has("ordinal") { body["ordinal"] = .int(try arguments.integer("ordinal")) }
                return body
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
            write("ghidra_comment", "set/comment", "Write a comment",
                  "Sets the comment of `kind` at `address`, replacing the one there; empty `text` clears it. "
                  + "A plate comment heads a function in the C; pre and eol comments show in the C too.",
                  ["address": AgentSchema.string("The address."),
                   "text": AgentSchema.string("The comment; empty clears it."),
                   "kind": AgentSchema.choice(["pre", "post", "eol", "plate", "repeatable"], "Default \"pre\".")],
                  required: ["address", "text"]) { arguments in
                try optional(arguments, ["address", "text", "kind"])
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
                  + "after the next publish. Write the tag: `typedef struct _NAME { … } NAME;`.",
                  ["c": AgentSchema.string("The C text.")],
                  required: ["c"]) { arguments in
                ["c": .string(try arguments.string("c"))]
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
                differently, which stay in this module only: `ghidra_type_definition` shows both.
                """,
            inputSchema: AgentSchema.object(["module": moduleProperty], required: ["module"]),
            annotations: .edit
        ) { call in
            let module = try module(call.arguments)
            return try await answer { try await backend.publishModule(module, by: "agent") }
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
