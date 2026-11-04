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
        tools += libraryTools(backend)
        tools += [publishTool(backend), doneTool(backend), forgetTool(backend)]
        return tools
    }

    /// What the server tells a model about the tools: how a review goes, and
    /// the rules a review keeps (the skill's "What a review makes of the
    /// code"), so an agent without the skill gets them too.
    public static let instructions = """
        These tools review one UEFI module (a PEIM or a DXE driver) in Ghidra: the names, signatures, \
        types and comments a review writes are Ghidra's own and are kept in the module's project between \
        sessions. A module is named by the SHA-256 of its bytes (`module`). Start with `ghidra_modules` \
        or `ghidra_open`; read with `ghidra_functions`, `ghidra_gaps` (the code between bodies the \
        analysis never cut), `ghidra_function` (decompiled C, parameters and \
        locals with their storage), `ghidra_disassembly`, `ghidra_xrefs`, `ghidra_data`, `ghidra_strings`, `ghidra_equates_on_memory`, `ghidra_type_definition`, \
        `ghidra_type_uses` (where every module names a type), `ghidra_description`; write with `ghidra_rename`, `ghidra_function_create`, `ghidra_function_delete`, `ghidra_function_merge`, \
        `ghidra_rename_variable`, `ghidra_function_locals_reset`, `ghidra_redecode`, `ghidra_signature`, \
        `ghidra_type`, `ghidra_set_data`, `ghidra_comment`, `ghidra_describe`, `ghidra_code_mode`, `ghidra_equate`, \
        `ghidra_function_tag`. `ghidra_function_tag` marks library code the module statically links in, and \
        whose: `library.edk2`, `library.amd` (AGESA) or `library.intel` (FSP/RC), by the criteria in the \
        skill's "Library functions"; the artifact records it at the library review level with that kind, \
        and it needs no further review. The shared registry of reviewed library functions is applied to a \
        module as it opens — `library` in `ghidra_open`'s answer; `ghidra_library` lists the matches and \
        `ghidra_library_apply` applies, replaces or declines one. `ghidra_publish` makes the review visible to the app — every \
        ByteRipper that reads this store — as a new revision; publish at coherent checkpoints, not after \
        every rename. `ghidra_done` publishes and ends the session; `ghidra_forget` lets a kept \
        project go — its owner stopped and its folder moved to the Trash — for a program that cannot \
        be put right, and touches nothing of the store.

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
        CamelCase), a function named for what it does for its caller. A decompiler's temporary (`bVar1`) does not count against `full`, but work out its purpose from its uses and name it; a default name stays only, as an exception, where no definite purpose can be established, or with a comment where the tool refuses the name. After a signature change, read the \
        function again before `ghidra_rename_variable`: Ghidra merges and retypes locals.
        4. Comments a source would have: a plate comment on each function that matters, whose first paragraph, up to the first blank line, says briefly what the function is for, since the app shows that paragraph alone over a call (then what, why, what \
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
        leave it true to the code at every publish. \
        \(descriptionFormat)
        """

    /// The description's sections, in order, as the skill's
    /// `reference/description.md` sets them; a model reads this.
    static let descriptionFormat = """
        It is an article for a service technician who does not program: plain prose, every abbreviation \
        expanded in parentheses at its first mention, routines by what they do rather than by address; no function inventories, \
        decompiler artefacts, revision history or review status — the app and the store hold those. Its \
        sections, in this order, headed exactly so: `# <ModuleName>` and a short summary; `## What it is` \
        (kind of file, whose, stage of start-up, the board and the module's place in the firmware — never \
        the dump file it was read from); `## What it does`; `## Execution flow` (the main chains as short ordered walks; the events it registers for, when each fires, what it does; each chain and event links its main function or two, helpers left out); `## Interactions`; \
        `## Inside the module`; `## Failures` (codes, messages, what the bench \
        sees); `## Known problems` (with their practical effect); `## Terms` (only the narrow terms specific to this module that the article uses, in full: what each is, where it sits, why it matters here; common terms a technician knows, such as BIOS, USB, CMOS, UEFI, Variable, stay out). A section with nothing to say \
        yet is left out. A link `[Name](0xADDRESS)` is optional outside `Execution flow`; a sentence must read without it. Say what \
        is not proven. Markdown: headings, paragraphs, `-` and `1.` lists, tables, fenced code, `code`, \
        **bold**, *italic*, links.
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
                (`published`: artifact, recipe, revision, and `at`, when what is stored last changed). \
                `modification` and `writes` under `published` count this project's writes up to that \
                publish, for telling what is still unpublished: they move at a publish that stores \
                nothing new, and are no figure of the publish itself.
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
                server restart — only an owner killed outright or crashed loses it, and then `writes_lost` here and in \
                `ghidra_modules` says so from the next open on. It counts from this build's first open of the project: \
                what was lost before that cannot be told, and its absence on a module not opened since says nothing. \
                `language_patch` names the patch of the x86 language this Ghidra was compiled with; a stock Ghidra answers none. A module seen before is opened \
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
                return try await answer {
                    await opened(try await backend.openImage(image, name: name, document: nil, node: nil),
                                 module: SHA256Digest(data: image), backend: backend)
                }
            }
            let module = try module(arguments)
            return try await answer {
                await opened(try await backend.openModule(module), module: module, backend: backend)
            }
        }
    }

    /// `ghidra_open`'s answer: the owner's `hello`, and what the library
    /// registry applied to the module as it opened (`library`) — or why it
    /// could not (`library_error`): the open stands either way.
    public static func opened(_ hello: Data, module: SHA256Digest, backend: GhidraBackend) async -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: hello)) as? [String: Any] else { return hello }
        do {
            let data = try await backend.library(module, GhidraHost.LibraryRequest(action: .apply))
            if let plan = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               (plan["entries"] as? Int ?? 0) > 0 {
                object["library"] = openSummary(plan)
            }
        } catch {
            object["library_error"] = "\(error)"
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? hello
    }

    /// The registry's part of an open's answer: what was applied in full,
    /// what changed and what was left, without the functions already current.
    static func openSummary(_ plan: [String: Any]) -> [String: Any] {
        var summary: [String: Any] = ["entries": plan["entries"] ?? 0,
                                      "already_applied": (plan["applied"] as? [Any])?.count ?? 0]
        for key in ["results", "edited", "candidates", "released"] {
            if let list = plan[key] as? [Any], !list.isEmpty { summary[key] = list }
        }
        if let declined = plan["declined"] as? [Any], !declined.isEmpty { summary["declined"] = declined.count }
        return summary
    }

    /// A write on the registry itself, as a tool asks for it.
    private static func change(_ arguments: AgentArguments, _ backend: GhidraBackend,
                               _ change: LibraryChange) async throws -> AgentAnswer {
        let module = try module(arguments)
        let request = GhidraHost.LibraryRequest(action: .change, dryRun: try arguments.bool("dry_run", default: false),
                                                change: change)
        return try await answer { try await backend.library(module, request) }
    }

    static func libraryTools(_ backend: GhidraBackend) -> [AgentTool] {
        [
            AgentTool(
                name: "ghidra_library",
                title: "Match a module against the library registry",
                description: """
                    The module's functions against the shared registry of reviewed library functions, \
                    matched by body (Ghidra's Function ID: the code with relocated addresses masked, and \
                    its constants). `applied`: functions carrying the current version of their entry. \
                    `to_apply`: matches that apply by themselves — `ghidra_open` applies them, and \
                    `ghidra_library_apply` without `address` does: an unnamed function takes the whole \
                    entry (`whole`); one a review named takes the entry's name, its old name kept in the \
                    reason, and only what its review left empty (`fill`); a newer version replaces one \
                    applied and not edited since; a body that differs from an entry only in the codes an \
                    assert routine is called with is a `variant` of it. `edited`: applied, then edited — \
                    the review's now. `candidates`: bodies of an entry's shape with other constants, \
                    each difference listed (`value`, `entry_value`, `assert`): other functions unless a \
                    review says why the values make no difference. `declined`: entries a review refused \
                    for the function. With `id`: one entry — its index row, its review, its history and \
                    `gaps`, what its review lacks, read from the review itself; `library_registry` reads the \
                    `function_parts` left out of the review. A match's `gaps` are the \
                    function's own missing parts as the last published analysis recorded them, and \
                    `entry_gaps` the entry's, so a decision to apply, replace or take can be made without \
                    opening either — and the two are read in the same words.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "id": AgentSchema.string("An entry's id, as `library_registry` or a match lists it: read that entry.")
                ], required: ["module"])
            ) { call in
                let module = try module(call.arguments)
                if let id = try call.arguments.optionalString("id") {
                    return try await answer { try await backend.library(module, .init(action: .entry, id: id)) }
                }
                return try await answer { try await backend.library(module, .init(action: .status)) }
            },
            AgentTool(
                name: "ghidra_library_rename",
                title: "Give a library registry entry a narrower name",
                description: """
                    The name changes in the entry, its signatures and its stored C, not in comments or in \
                    other entries' C. A library function's name is unique in the registry, and it goes by what the functions \
                    mean, not by who published first. When a publish answers `library.name_conflicts`, read \
                    the entry that holds the name (`library_registry` with its `id`) beside the new function. \
                    If the name fits the new function, or fits neither well, give the entry the narrower name \
                    its code earns with this tool, and publish again; otherwise rename the new function. The \
                    `reason` says what the review found, and the history keeps it. Every module takes the new \
                    name at its next open. The text of the entry's recorded `function.c` keeps the old name \
                    until a new C is recorded; a reader through the registry sees the new one. `dry_run: true` \
                    answers the same and writes nothing.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "id": AgentSchema.string("The entry to rename, as a name conflict's `held_by` gives it."),
                    "name": AgentSchema.string("The narrower name, free in the registry."),
                    "reason": AgentSchema.string("What the review of both functions found."),
                    "dry_run": AgentSchema.boolean("Answer what the rename would do and write nothing.")
                ], required: ["module", "id", "name", "reason"]),
                annotations: .edit
            ) { call in
                let arguments = call.arguments
                let module = try module(arguments)
                let request = GhidraHost.LibraryRequest(
                    action: .rename, id: try arguments.string("id"), reason: try arguments.string("reason"),
                    dryRun: try arguments.bool("dry_run", default: false), name: try arguments.string("name"))
                return try await answer { try await backend.library(module, request) }
            },
            AgentTool(
                name: "ghidra_library_take_out",
                title: "Give a body back to its modules",
                description: """
                    A library function depends on no module: it refers to no data but a constant of its own \
                    library's source, and calls only library functions. A body that does not qualify leaves \
                    the registry with this tool: with `body`, that body alone; without, the whole entry, and \
                    its name is free. A publish does not offer it again. A module whose function took it or \
                    was tagged with it keeps the text at its next open, and the function stops being library. \
                    The history stays. `ghidra_library_restore` takes a wrong decision back. `dry_run: true` \
                    answers the same and writes nothing.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "id": AgentSchema.string("The entry."),
                    "body": AgentSchema.string("One of its bodies; omit for the whole entry."),
                    "reason": AgentSchema.string("What in the code ties it to a module."),
                    "dry_run": AgentSchema.boolean("Answer what would be done and write nothing.")
                ], required: ["module", "id", "reason"]),
                annotations: .edit
            ) { call in
                try await change(call.arguments, backend, LibraryChange(
                    action: .takeOut, id: try call.arguments.string("id"),
                    body: try call.arguments.optionalString("body"), reason: try call.arguments.string("reason")))
            },
            AgentTool(
                name: "ghidra_library_restore",
                title: "Take a body back into the registry",
                description: """
                    Takes back a `ghidra_library_take_out`: the body returns to its entry, or the entry returns \
                    with it. The name must still be free. `dry_run: true` answers the same and writes nothing.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "body": AgentSchema.string("The body key, as the index's `taken_out` lists it."),
                    "reason": AgentSchema.string("Why the decision was wrong."),
                    "dry_run": AgentSchema.boolean("Answer what would be done and write nothing.")
                ], required: ["module", "body", "reason"]),
                annotations: .edit
            ) { call in
                try await change(call.arguments, backend, LibraryChange(
                    action: .restore, body: try call.arguments.string("body"), reason: try call.arguments.string("reason")))
            },
            AgentTool(
                name: "ghidra_library_split",
                title: "Make one body of an entry its own entry",
                description: """
                    Different bodies are different functions. One body of an entry becomes an entry of its own, \
                    under the name its code earns, starting from the review they shared; correct its text from \
                    a module that holds it. The body the entry is keyed by stays: give it its name with \
                    `ghidra_library_rename`, and split the others off. `dry_run: true` answers the same and \
                    writes nothing.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "id": AgentSchema.string("The entry."),
                    "body": AgentSchema.string("The body to split off."),
                    "name": AgentSchema.string("Its name, free in the registry."),
                    "reason": AgentSchema.string("What the review found."),
                    "dry_run": AgentSchema.boolean("Answer what would be done and write nothing.")
                ], required: ["module", "id", "body", "name", "reason"]),
                annotations: .edit
            ) { call in
                try await change(call.arguments, backend, LibraryChange(
                    action: .split, id: try call.arguments.string("id"), body: try call.arguments.string("body"),
                    name: try call.arguments.string("name"), reason: try call.arguments.string("reason")))
            },
            AgentTool(
                name: "ghidra_library_cite",
                title: "Cite the source of a body's constant",
                description: """
                    A body that refers to data enters the registry only if the data is a constant defined in \
                    its own library's source. Cite the file and line after comparing the bytes with that \
                    source; the registry cannot check it and keeps who said so. Give `id` for an entry's bodies, \
                    or `body` for one, also before its first publish: a publish's `library.not_library` names \
                    the key. A GUID never qualifies. A body with two constants has two citations: another \
                    file or line adds one, the same file and line replaces it, `remove: true` takes it away. \
                    `citations` says which, with what was replaced; the registry keeps that. `dry_run: true` \
                    answers the same and writes nothing.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "id": AgentSchema.string("The entry; omit when naming a `body`."),
                    "body": AgentSchema.string("One body key."),
                    "file": AgentSchema.string("The source file, by its path in its tree."),
                    "line": AgentSchema.integer("The line that defines the constant."),
                    "note": AgentSchema.string("What was compared."),
                    "remove": AgentSchema.boolean("Take this file and line away."),
                    "dry_run": AgentSchema.boolean("Answer what would be done and write nothing.")
                ], required: ["module", "file", "line"]),
                annotations: .edit
            ) { call in
                try await change(call.arguments, backend, LibraryChange(
                    action: .cite, id: try call.arguments.optionalString("id"),
                    body: try call.arguments.optionalString("body"), reason: try call.arguments.optionalString("note"),
                    file: try call.arguments.string("file"), line: Int(try call.arguments.integer("line")),
                    remove: try call.arguments.bool("remove", default: false) ? true : nil))
            },
            AgentTool(
                name: "ghidra_library_apply",
                title: "Apply or decline a library registry entry",
                description: """
                    Applies the registry's entries to the module, each in a transaction of its own, and \
                    answers each in `results`: `renamed` (from, to), `filled`, `differences` the \
                    function's review keeps, `unplaced` (a variable or comment the function has no place \
                    for), `leftovers` — the gaps the function still keeps after the apply, so a local it \
                    left unnamed says so at once — and `marked` when the function is now the entry's. \
                    Without `address`: every match `ghidra_library` lists in `to_apply`. With `address`: that function — a candidate \
                    only with `reason` (why its other constants make no difference: it becomes a variant \
                    of the entry at the next publish); `replace: true` puts the entry's review in place \
                    of a review that differs or was edited since; `leftovers` accompany an apply that \
                    names `address`, and a bulk apply leaves them out (the reading decompiles each \
                    function it answers); `fields` takes only the parts named — \
                    signature (return type, convention, parameter types), names (the function's and its \
                    parameters'), locals, plate, comments — and keeps the rest of the function's. \
                    `dry_run: true` answers the same and writes nothing: each entry is applied in its \
                    transaction and rolled back, so a `replace` can be read before it is made. \
                    `decline: true` refuses the entry for the function (`id`, or the one matched), and it \
                    is not offered again. A difference a review keeps is settled by keeping it, or by \
                    publishing it as the entry's next version (`ghidra_publish` with \
                    `take_library_conflicts` and a reason). A match's `gaps` are the function's own missing \
                    parts and `entry_gaps` the entry's, so the two reviews can be compared before either \
                    is changed.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "address": AgentSchema.string("The function's entry. Leave out to apply every match that applies by itself."),
                    "id": AgentSchema.string("The entry, where several match the function."),
                    "reason": AgentSchema.string("Why a candidate's other constants make no difference, or why an entry is declined."),
                    "replace": AgentSchema.boolean("Put the entry's review in place of the function's."),
                    "fields": AgentSchema.strings(
                        "Take parts of the entry's review and keep the rest of the function's: signature, "
                            + "names, locals, plate, comments."),
                    "dry_run": AgentSchema.boolean(
                        "Answer what the apply would do — filled, differences, unplaced, leftovers — and "
                            + "write nothing."),
                    "decline": AgentSchema.boolean("Refuse the entry for the function at `address`."),
                    "full": AgentSchema.boolean(
                        "Answer with the functions already carrying their entry; by default only a count.")
                ], required: ["module"]),
                annotations: .edit
            ) { call in
                let arguments = call.arguments
                let module = try module(arguments)
                let address = try arguments.optionalString("address")
                let request = GhidraHost.LibraryRequest(
                    action: try arguments.bool("decline", default: false) ? .decline : .apply,
                    address: address, id: try arguments.optionalString("id"),
                    reason: try arguments.optionalString("reason"),
                    replace: try arguments.bool("replace", default: false),
                    fields: try arguments.strings("fields"),
                    dryRun: try arguments.bool("dry_run", default: false))
                if request.action == .decline, address == nil {
                    throw AgentToolError("`decline` names the function by `address`.")
                }
                let full = try arguments.bool("full", default: false)
                let reply = try await answer { try await backend.library(module, request) }
                return full ? reply : Self.compactPlan(reply)
            }
        ]
    }

    /// A registry answer without the list of what was already current: the
    /// entries applied from before are noise beside what this call did.
    /// `full: true` asks for the list too.
    static func compactPlan(_ answer: AgentAnswer) -> AgentAnswer {
        guard case .json(let value) = answer, case .object(var plan) = value else { return answer }
        if let applied = plan.removeValue(forKey: "applied")?.arrayValue {
            plan["applied_count"] = .count(applied.count)
        }
        return .json(.object(plan))
    }

    /// A publish's registry part without its unchanged list, which on a
    /// reviewed module is every entry the publish did not touch. `full: true`
    /// asks for it.
    static func compactPublish(_ answer: AgentAnswer) -> AgentAnswer {
        guard case .json(let value) = answer, case .object(var publication) = value,
              case .object(let library)? = publication["library"] else { return answer }
        var compact = library
        if let unchanged = compact.removeValue(forKey: "unchanged")?.arrayValue {
            compact["unchanged_count"] = .count(unchanged.count)
        }
        publication["library"] = .object(compact)
        return .json(.object(publication))
    }

    /// `take_library_conflicts` as the tool takes it: `true` — every conflict,
    /// with the one `library_reason` — or a list of entry ids, each with its
    /// reason from `library_reason` given as an object of id to text.
    static func libraryTake(_ arguments: AgentArguments) throws -> LibraryTake {
        var entryReasons: [String: String] = [:]
        if let given = arguments["entry_reasons"] {
            guard let map = given.objectValue else {
                throw AgentToolError("Argument `entry_reasons`: an object of entry id to reason.")
            }
            for (id, text) in map {
                guard let reason = text.stringValue else {
                    throw AgentToolError("Argument `entry_reasons`: an object of entry id to reason.")
                }
                entryReasons[id] = reason
            }
        }
        return try libraryConflictsTake(arguments).with(entryReasons: entryReasons)
    }

    private static func libraryConflictsTake(_ arguments: AgentArguments) throws -> LibraryTake {
        guard let value = arguments["take_library_conflicts"] else { return .none }
        if let all = value.boolValue {
            guard all else { return .none }
            return .all(try arguments.optionalString("library_reason") ?? "")
        }
        guard let items = value.arrayValue, items.allSatisfy({ $0.stringValue != nil }) else {
            throw AgentToolError("Argument `take_library_conflicts`: expected true or false, "
                + "or a list of entry ids.")
        }
        let ids = items.compactMap(\.stringValue)
        var reasons: [String: String] = [:]
        if let map = arguments["library_reason"]?.objectValue {
            for (id, text) in map {
                guard let reason = text.stringValue else {
                    throw AgentToolError("Argument `library_reason`: an object of entry id to reason.")
                }
                reasons[id] = reason
            }
        } else if let text = try arguments.optionalString("library_reason") {
            for id in ids { reasons[id] = text }
        }
        for id in ids where reasons[id] == nil { reasons[id] = "" }
        return .these(reasons)
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
                name: "ghidra_type_uses",
                title: "Find where the modules name a type",
                description: """
                    Where every module's last published analysis names a type, whole identifiers only, by \
                    its name and its tag together: `modules`, each with `module`, `name`, `revision` and \
                    `uses` — `functions` (`entry`, `name`, `in_signature`, `line_count` and the first \
                    `lines` of C, comments included), `data` typed with it or whose comment names it, the \
                    module's other `types` that name it, and `holds_the_type`. For correcting a name across \
                    the modules, before or after `ghidra_type` withdraws it. It reads the store: a module \
                    with no project here is found, and writes not yet published are not seen. `functions` \
                    counts them all; `limit` bounds how many are listed, and `truncated` says some were \
                    left out. Slow on a large store: it reads every module.
                    """,
                inputSchema: AgentSchema.object([
                    "name": AgentSchema.string("The type's name or its tag."),
                    "limit": AgentSchema.limit(default: 200, maximum: 1000)
                ], required: ["name"])
            ) { call_ in
                let arguments = call_.arguments
                let name = try arguments.string("name")
                let limit = try arguments.limit(default: 200, maximum: 1000)
                return try await answer { try await backend.typeUses(name: name, limit: limit) }
            },
            AgentTool(
                name: "ghidra_functions",
                title: "List a module's functions",
                description: """
                    The module's functions as Ghidra holds them now: entry, name, name_source, size, \
                    signature, `tags`, and for a function the export writes at the library review \
                    level `library` — `edk2_name` or `tag` — and `library_kind` — edk2, amd or intel; \
                    none for a bare `library` tag. `name_contains` and `name_source` (a Ghidra source such as USER_DEFINED) \
                    narrow the list, `address_from`/`address_to` narrow it by entry. `filter: \
                    "unfinished"` keeps what a review has not passed — a parameter or a local Ghidra \
                    still names itself, or one still typed `undefined`, or no plate comment — each with \
                    `leftovers`, and `summary` says how many of how many; that filter decompiles every \
                    function, so it is slow on a large module. `leftovers.fragments` counts the \
                    register and `unique:` pieces the decompiler splits off while a review types a \
                    function — its own artefacts, which do not make a function unfinished, though a \
                    name like `uVar1` among them still prints in the C — and `fragment_names` names \
                    them; `filter: "fragments"` lists every function that has them. Paged by \
                    `offset` and `limit`; `next` says where the next page starts. `library_entry` is \
                    the function's mark and whether it is still the entry (`state`: entry, edited). \
                    While the registry reads through, a row at its entry has the entry's name and \
                    signature and `text: "registry"`, or `text_unavailable` saying why not; `leftovers`, \
                    and so `filter: "unfinished"`, stay the project's, and can list a function that \
                    reads as its entry.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "offset": AgentSchema.integer("How many to skip. Default 0."),
                    "limit": AgentSchema.limit(default: 200, maximum: 1000),
                    "filter": AgentSchema.choice(["unfinished", "fragments"], "Only the functions a review has not passed: a placeholder parameter or stored local, or no plate. A decompiler's temporary (`uVar1`) does not count, since some cannot be named; `summary.fragments_only` counts the functions it leaves out with only those left."),
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
            paged("ghidra_gaps", "gaps", "List the gaps between function bodies", """
                The spans of executable memory between neighbouring function bodies that hold \
                anything but padding — the code the analysis never made a function of, because it \
                cuts a function where a reference points and a body registered in a table, or \
                reached by nothing at all, has none. Each gap says `start`, `end`, `size` and \
                `first_bytes` (16); whether its first byte is already an `instruction` or \
                `defined_data`; the `references` into it from outside — `all`, `data`, `code` — with \
                up to eight `reference_targets` and, when something points in with data, `body_at`; \
                whether a body `preceded_by_body` runs into it; \
                and a `verdict`: `data` — what refers in reads a datum that already has its type; \
                `body` — a data reference lands in the gap outside any datum, so something \
                registered it (a callback, a table slot) and `ghidra_function_create` at that \
                target makes it a function, whatever its first bytes look like; `tail` — nothing \
                refers to it and the body before it runs into it, so it is that body's tail and \
                belongs with it, not a function of its own; `unclaimed` — nothing refers to it and \
                no body runs into it; `referenced` — code refers into it, which a function ought to \
                have taken. `count` is how many gaps the module has; paged by `offset` and `limit`.
                """),
            AgentTool(
                name: "ghidra_function",
                title: "Read one function",
                description: """
                    One function as Ghidra holds it now: its signature, its `tags` and — for a function \
                    the export writes at the library review level — `library`, why: `edk2_name` for a \
                    name on the EDK2 list, `tag` for a review's library tag — and `library_kind`, whose: \
                    edk2, amd or intel; its parameters and locals with \
                    their `storage` and `first_use` (what `ghidra_rename_variable` names a local by), its \
                    plate comment, its `comments` — every comment in the body with its `address`, `kind` \
                    (plate, pre, eol, post, repeatable) and `text`, to check against a re-read of the C — \
                    what is left to name or type — a name Ghidra made up, or an \
                    `undefined` type — (`leftovers`, whose `fragments` are the decompiler's register \
                    pieces rather than missing names), and its decompiled C — \
                    fresh after every write, ahead of what the app shows until a publish. \
                    While the registry reads through, a function at its entry answers the entry's name, \
                    signature, plate, comments and C with `text: "registry"`, as the store reads it, and \
                    `publisher_addresses` lists any name that still carries the address of the module \
                    the entry came from; `parameters` and `locals` stay the project's. Any write in it \
                    makes it `edited` (`library_entry.state`): it then answers as Ghidra holds it. A \
                    publish that changes its review makes that the entry's next version, for every \
                    module that holds it, from any holder; one that does not — a name on a temporary, \
                    a label, an equate alone — leaves the entry as it is, the function reads as the \
                    entry again, and `project_names` lists a temporary's name the C does not print. \
                    `text_unavailable` says why a marked function has no `text`: the entry could not \
                    be read, or this store has no reading of the function. \
                    `summary: true` leaves the C and the equates out, for walking a module without \
                    its text. A function the decompiler refuses answers `decompile_error` and \
                    `suspects`: the parameters, locals and referenced data whose applied type is a \
                    pointer to something that is not a structure — where `PTRSUB off of non \
                    structured pointer type` comes from — so the offending symbol is named rather \
                    than bisected for.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "address": AgentSchema.string("The function's entry address, e.g. \"0x68A\"."),
                    "summary": AgentSchema.boolean(
                        "Leave out the decompiled C and the equates: signature, parameters, locals, "
                        + "plate, leftovers."),
                    "explain": AgentSchema.boolean(
                        "When the C does not come out, bisect the data the body references: each "
                        + "datum is let go in turn inside a transaction that is rolled back, and the "
                        + "ones after which the C decompiles are named under `explained`. Nothing is "
                        + "kept; a rollback that did not take says so and stops.")
                ], required: ["module", "address"])
            ) { call in
                let module = try module(call.arguments)
                let address = try call.arguments.string("address")
                var query: [String: String] = [:]
                if try call.arguments.bool("summary", default: false) { query["summary"] = "1" }
                if try call.arguments.bool("explain", default: false) { query["explain"] = "1" }
                return try await answer { try await backend.readCall(module, "function/\(address)", query: query) }
            },
            AgentTool(
                name: "ghidra_disassembly",
                title: "Read a function's instructions",
                description: "The instructions of the function at `address`, with their bytes, references and "
                    + "the names of their constants (`equates`). At an instruction no function holds, as "
                    + "`ghidra_gaps` lists them, the code from there to the next function, and `gap` in place of "
                    + "`entry`. At bytes nothing has decoded, a reading of them as code with the program left as "
                    + "it was, `undecoded: true`, 64 rows unless `limit` says otherwise, and `stopped_by` for what "
                    + "ended it: not a claim that they are code. A large function comes in pages: `limit` "
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
                description: "The references `to` an address (who calls a function, reads a global) or `from` one. "
                    + "`to` also answers `held_by`: instructions that hold the address as a constant and have no reference to it, "
                    + "such as `MOV EAX,addr` before `CALL EAX`; in an image based at zero it is empty, a small constant being no address. "
                    + "`function` answers `calls`: every call it makes and every jump that leaves it, in order, each with `at`, `text` and "
                    + "`kind`, \"direct\" or \"indirect\", and `target` and `name` where known; an indirect one traced to its `MOV` gives "
                    + "`held_at`, one with no `target` is not known from here. An empty list means no calls.",
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "to": AgentSchema.string("References to this address."),
                    "from": AgentSchema.string("Or references from this address."),
                    "function": AgentSchema.string("Or the calls this function makes.")
                ], required: ["module"])
            ) { call in
                let arguments = call.arguments
                let module = try module(arguments)
                var query: [String: String] = [:]
                if let to = try arguments.optionalString("to") { query["to"] = to }
                if let from = try arguments.optionalString("from") { query["from"] = from }
                if let function = try arguments.optionalString("function") { query["function"] = function }
                guard query.count == 1 else { throw AgentToolError("Give `to`, `from` or `function`, one of them.") }
                return try await answer { try await backend.readCall(module, "xrefs", query: query) }
            },
            paged("ghidra_equates_on_memory", "equates-on-memory", "List equates on memory operands",
                  "Equates that sit on a memory operand, usually the displacement of `[reg+N]`: `address`, "
                  + "`name`, `operand`, `text` (the instruction), `function`. `value` in `ghidra_equate` once "
                  + "chose these by mistake, so read each one; a name meant for the immediate is removed with "
                  + "an empty `name` and `operand`, then set again. One set on purpose is listed too. "
                  + "`count` is how many the module has. Paged."),
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
                    `bytes`. `section` answers that section's body alone as `text`; `outline: true` leaves \
                    `text` out. Read what `ghidra_describe` is about to change: one section need not cost \
                    the whole description.
                    """,
                inputSchema: AgentSchema.object([
                    "module": moduleProperty,
                    "section": AgentSchema.string("The `## ` heading to read alone."),
                    "outline": AgentSchema.boolean("Only the headings and the size.")
                ], required: ["module"])
            ) { call in
                let module = try module(call.arguments)
                var query: [String: String] = [:]
                if let section = try call.arguments.optionalString("section") { query["section"] = section }
                if try call.arguments.bool("outline", default: false) { query["outline"] = "1" }
                let asked = query
                return try await answer { try await backend.readCall(module, "description", query: asked) }
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
                    match. With `contains`, `in_archives` lists what the review archive and EDK2 hold under that \
                    name and the program does not yet: it needs no definition, and is taken in when first used.
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
                let fields = try body(arguments)
                let payload = JSONValue.object(fields).encoded()
                // A question about a write is no write: it takes no lease, so a
                // later `ghidra_done` has nothing to give back for it.
                if call == "set/equate", fields["dry_run"] == .bool(true) {
                    return try await answer { try await backend.previewCall(module, "preview/equate", body: payload) }
                }
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
                  + "With `name`, names it as `ghidra_rename` would. A function already there is answered as it is. "
                  + "An address inside another function's body is refused, naming that function: a function made "
                  + "there splits the body it belongs to. Undo a split with `ghidra_function_delete` or "
                  + "`ghidra_function_merge` first.",
                  ["address": AgentSchema.string("The entry address, e.g. the value in the table's slot."),
                   "name": AgentSchema.string("A name for it, optional."),
                   "reason": AgentSchema.string("Why this name, in a few words.")],
                  required: ["address"]) { arguments in
                var body = try optional(arguments, ["address", "name", "reason"])
                body["by"] = "agent"
                return body
            },
            write("ghidra_function_delete", "delete/function", "Remove a function",
                  "Removes the function at `address` — its entry or any address inside it. The bytes stay "
                  + "disassembled; what the function said about them is gone, and the next publish drops it "
                  + "from the analysis. This is how a split is undone: `ghidra_function_create` refuses to make "
                  + "a function inside another function's body, and a body the analysis split on a conditional "
                  + "jump is removed here and the right one made again.",
                  ["address": AgentSchema.string("The function's entry, or any address inside it.")],
                  required: ["address"]) { arguments in
                try optional(arguments, ["address"])
            },
            write("ghidra_function_locals_reset", "clear/locals", "Let a function's locals go",
                  "Removes the local variables of the function at `address` — the decompiler's and the "
                  + "review's, or with `names` only those — and decompiles it again, answering what was cleared "
                  + "(`locals`: each one's name, storage, first use and type, to give back what matters with "
                  + "`ghidra_rename_variable`) and whether the C now decompiles (`decompiles`), with the error "
                  + "when it does not. The candidate for a function the decompiler refuses, such as two symbols "
                  + "assigned to one variable, where names it kept stand in the way: name the two its error names "
                  + "before clearing everything. It is not a guarantee, and what is cleared goes: read the "
                  + "function again and name what matters. While the C still fails, the "
                  + "answer names `suspects` — the parameters, locals and referenced data typed as a pointer "
                  + "to something that is not a structure, which is where such a failure comes from.",
                  ["address": AgentSchema.string("The function's entry address, or any address inside it."),
                   "names": .object(["type": "array", "items": .object(["type": "string"]),
                                     "description": .string("Only these locals. Default: every one.")])],
                  required: ["address"]) { arguments in
                var body = try optional(arguments, ["address"])
                if let names = arguments["names"] { body["names"] = names }
                return body
            },
            write("ghidra_function_merge", "merge/functions", "Make two functions one",
                  "Gives the body of `from` to `into` and removes `from`: the way back from a split the "
                  + "analysis made, where a conditional jump inside a body it took for a function left half "
                  + "of it as a function of its own. Both are named by entry or any address inside them, as "
                  + "`ghidra_function` lists them; the answer gives the survivor's entry, name and size. "
                  + "Merging a function into itself, or one that is already part of the other, is refused.",
                  ["into": AgentSchema.string("The function that keeps its entry and name."),
                   "from": AgentSchema.string("The function that becomes part of it.")],
                  required: ["into", "from"]) { arguments in
                try optional(arguments, ["into", "from"])
            },
            AgentTool(
                name: "ghidra_rename_variable",
                title: "Name or type a parameter or a local",
                description: """
                    Names, and perhaps types, a local by its `storage` and, for a register, \
                    `first_use` — as `ghidra_function` lists them — or a parameter by its `ordinal`. \
                    Never by Ghidra's own name for it (`iVar4`): those renumber. Two locals that share \
                    a storage and a first use cannot be told apart — a function holds one variable per \
                    storage — and naming either is refused; say what each is in the plate comment, and \
                    name the slot itself with `shared`: the whole storage takes one name, every use of \
                    it reads by that name, and the plate says which meaning each use carries. Use a \
                    neutral name there (`PcieSizeTooSmall`), never one of the meanings. A slot whose \
                    storage a parameter also holds is refused: name the parameter by ordinal. A slot \
                    that cannot be named whole — one use stays under another name — is refused too, \
                    and nothing is changed, rather than answered as applied. With `shared`, a `HASH:…` or `unique:…` storage is refused: it is the decompiler's own temporary, made afresh by each decompile, not a slot the module holds. Without `shared`, such a local is named and typed by its storage as any other. \
                    `type` alone types it and keeps the name. After any call, read the function again: a local's `storage` \
                    can change, and a type alone gives it a `HASH:` storage. `items` does several in \
                    one call, each in a transaction of its own: the answer lists what applied and why \
                    an entry did not. A name already held is answered with the holder — its kind, \
                    address, `storage` and `first_use` — and those rename the holder, even one the \
                    decompiler no longer shows (the answer then says `stale: true`); freeing the name \
                    is what lets the local take it. A `first_use` that is no longer the variable's is refused with what the storage holds now, since a retype can merge locals: list them again. A type the decompiler does not take is refused and nothing is changed.
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
                    "shared": AgentSchema.boolean(
                        "Name the whole storage once, for a slot the decompiler shows as several "
                        + "variables; with this, `storage` alone names it and `first_use` is not given."),
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
                if try arguments.bool("shared", default: false) { body["shared"] = .bool(true) }
                let payload = JSONValue.object(body).encoded()
                return try await answer { try await backend.writeCall(module, "rename/variable", body: payload) }
            },
            write("ghidra_signature", "set/signature", "Set a function's signature",
                  "Sets the C signature of the function at `address`, the EDK2 way if wanted; with no `storage`, "
                  + "a 32-bit stack keeps no hole for a UINT64, and `aligned` in the answer lists the parameters "
                  + "that puts elsewhere than the convention did: `convention`, where it put them, `storage`, where they are "
                  + "(`EFI_STATUS EFIAPI Foo (IN CONST EFI_PEI_SERVICES **PeiServices)`). Types the module "
                  + "lacks come from the EDK2 archive or from types a review defined. For a function no "
                  + "calling convention fits — a linker's clone that takes an argument in EDX, or returns "
                  + "through a pointer in ECX — give `storage`, one place per parameter as `ghidra_function` "
                  + "lists storage (`[\"ECX:4\", \"Stack[0x4]:4\"]`), and `return_storage` if the result is "
                  + "not where the convention puts it (`EDX:4,EAX:4` for 64 bits, high part first, `void`). "
                  + "Then no dummy parameter is needed for a register the function does not read. A convention "
                  + "that does not give that storage is dropped, so the C prints none against it. "
                  + "A function analysis left at `unknown`, for which the decompiler writes a warning into its C, moves to "
                  + "`default`, which names no convention and does not say the function follows one; "
                  + "`convention_stays_unknown` in the answer says why not, when that would move a parameter.",
                  ["address": AgentSchema.string("The function's entry address."),
                   "signature": AgentSchema.string("The C prototype."),
                   "storage": .object(["type": "array", "items": .object(["type": "string"]),
                                       "description": "Where each parameter is, in order: \"EDX:4\", \"Stack[0x4]:4\"."]),
                   "return_storage": AgentSchema.string("Where the result is: \"EAX:4\", \"EDX:4,EAX:4\", \"void\"."),
                   "reason": AgentSchema.string("Why the signature is this one. Kept as `signature_reason`, apart from the name's reason.")],
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
            write("ghidra_function_extend", "function/extend", "Extend a body cut short",
                  "Extends the body of `function` to `end` (exclusive), for a body the analysis ended at an "
                  + "instruction it took for the end of the flow, such as INT1: the last instruction is set "
                  + "to fall through and the following instructions join the body. Refused when a function "
                  + "holds part of the range or the range is not whole decoded instructions.",
                  ["function": AgentSchema.string("The function, by entry or any address inside it."),
                   "end": AgentSchema.string("The first address past the new body.")],
                  required: ["function", "end"]) { arguments in
                try optional(arguments, ["function", "end"])
            },
            write("ghidra_redecode", "redecode", "Decode a range of code again",
                  "Decodes the instructions in [`start`, `end`) again from `start`, in the mode already "
                  + "there: the correction for a boundary the analysis got wrong, where it decoded from a "
                  + "byte inside an instruction. An instruction reaching into the range goes too. The answer "
                  + "lists the `instructions` now there and the `functions` whose bodies were fixed. A "
                  + "function whose entry now falls inside an instruction was cut at a false boundary: one "
                  + "Ghidra named is removed (`functions_removed`), one a review named stays and is reported "
                  + "(`entries_inside_instructions`) for `ghidra_function_delete` or `ghidra_function_merge`. "
                  + "Defined data in the range is refused: clear it first. For 16-bit code in a 32-bit module "
                  + "use `ghidra_code_mode`.",
                  ["start": AgentSchema.string("The address the true instruction starts at."),
                   "end": AgentSchema.string("The first address past the range: [start, end)."),
                   "reason": AgentSchema.string("What shows the boundary was wrong.")],
                  required: ["start", "end"]) { arguments in
                try optional(arguments, ["start", "end", "reason"])
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
                  + "reaches an `out()` through a register. `value` picks the immediate operand that holds it, never a displacement in `[reg+1]`; "
                  + "`operand` picks one by index instead, and is how a displacement is named. Empty `name` removes it. One name stands for "
                  + "one value: a name already used for another is refused. A number the code computes "
                  + "(`ADD DL,4` to reach 0xCFC) is in no operand and gets a comment instead. "
                  + "Give every name an `enum` that groups it (`FCH_IO_PORT`, `AMD_MSR`, `LPC_DECODE_BITS`) "
                  + "and a `comment`: what the name stands for and where that is known from (a spec and "
                  + "its section, a coreboot or EDK2 header, the PPR, or `not confirmed`). The app shows "
                  + "the comment when the reader clicks the name, and the enum is shared with the next "
                  + "module reviewed, so a name given once brings its comment along: later, `name` and "
                  + "`enum` are enough. One value has one name in an enum. Instead of `address`, `functions` with "
                  + "`value` names that value wherever those functions hold it as an immediate operand; the answer "
                  + "lists `applied`, each address with its instruction, `skipped` operands, which keep another name they already have, and `not_immediate`, where those functions hold the value as an address, which is not named. A small value is held by unrelated instructions too: "
                  + "`dry_run: true` answers the same and writes nothing, so read the instructions first and name by `address` where only some are meant. `items` takes several operands in one call, each `address` with its own `operand`, `value` or `name` over the call's own, all or none; that is the way to name a displacement in many places. `in_c` says whether the function's C now prints the name, `not_in_c` lists the names of `items` it does not: an equate stands on the instruction, and the C can print something else, such as an enum member the operand's type chose.",
                  ["address": AgentSchema.string("The instruction's address."),
                   "functions": .object(["type": "array", "items": .object(["type": "string"]),
                                         "description": .string("Functions by entry address, instead of `address`; needs `value`.")]),
                   "items": .object(["type": "array", "items": .object(["type": "object"]),
                                     "description": .string("Several operands, each {address, operand or value, and optionally name, enum, comment}.")]),
                   "dry_run": AgentSchema.boolean("With `functions`: answer what would be named and write nothing."),
                   "name": AgentSchema.string("A C identifier, in the module's convention; empty removes it."),
                   "value": AgentSchema.string("The constant, e.g. \"0xCF8\", to pick the operand that holds it."),
                   "operand": AgentSchema.integer("Or the operand by its index, from 0."),
                   "enum": AgentSchema.string("The enum the name is a member of; made when missing."),
                   "comment": AgentSchema.string("What the name stands for and its source; replaces the member's comment."),
                   "enum_comment": AgentSchema.string("What the enum groups, e.g. \"FCH legacy I/O ports\".")],
                  required: ["name"]) { arguments in
                var body = try optional(arguments, ["address", "name", "value", "enum", "comment", "enum_comment"])
                if let functions = arguments["functions"] { body["functions"] = functions }
                if let items = arguments["items"] { body["items"] = items }
                if try arguments.bool("dry_run", default: false) { body["dry_run"] = .bool(true) }
                if arguments.has("operand") { body["operand"] = .int(try arguments.integer("operand")) }
                return body
            },
            write("ghidra_function_tag", "tag/function", "Tag a function",
                  "Tags the function containing `address`, as the other function writes find it. A library "
                  + "tag marks code the module statically links in that the automatic detection did not "
                  + "recognise, and says whose: `library.edk2` (EDK2's MdePkg libraries — `CopyMem`, HobLib, "
                  + "PeiServicesLib, BaseLib's math), `library.amd` (AGESA's own libraries — LibAmd I/O, "
                  + "assert, IDS debug print) or `library.intel` (FSP and Reference Code libraries). Which "
                  + "one, and when a vendor routine is the module's own work rather than a library, is "
                  + "decided by the criteria in the skill's \"Library functions\". The exported code "
                  + "artifact records a function carrying the tag at the `library` review level with that "
                  + "kind, complete as it is. A function holds one library tag: a new one replaces it; the "
                  + "bare `library` is refused. An empty `tag`, or `none`, removes the library tag. The "
                  + "answer lists the function's tags, sorted, with `library` and `library_kind`.",
                  ["address": AgentSchema.string("The function's entry address, or any address inside it."),
                   "tag": AgentSchema.string(
                       "The tag: library.edk2, library.amd or library.intel; empty or \"none\" removes the library tag.")],
                  required: ["address", "tag"]) { arguments in
                try optional(arguments, ["address", "tag"])
            },
            write("ghidra_set_data", "set/data", "Name or type a datum",
                  "Names and/or types the datum at `address`, e.g. a GUID or a table. An empty `name` removes "
                  + "the label there, a leftover under a type that now names the place. A type laid over decoded "
                  + "instructions is refused, naming them, unless `clear_code: true`: they go, the function "
                  + "holding them gives those bytes up, and `code_cleared` says so. An address outside the image, such as "
                  + "an MMIO register, takes a name and `outside_memory` says so: the C prints it where the code uses "
                  + "that address, and `ghidra_data` and the artifact's symbols do not list it.",
                  ["address": AgentSchema.string("The address."),
                   "clear_code": AgentSchema.boolean("Remove instructions the type covers and shorten the body."),
                   "name": AgentSchema.string("Its name; empty removes the label."),
                   "type": AgentSchema.string("Its C type, e.g. \"EFI_GUID\" or \"UINT32[4]\".")],
                  required: ["address"]) { arguments in
                try optional(arguments, ["address", "name", "type", "clear_code"])
            },
            write("ghidra_describe", "set/description", "Write the module's description",
                  "Writes the module's description — Markdown, what the module is for, how it works and how "
                  + "it is built — kept in the project and published with the review as an object of its "
                  + "own, which the app shows beside the code. With `section`, `text` replaces the body of "
                  + "that `## ` section only (added at the end if missing, or beside the section `before` or `after` names; either alone moves the section); without it, `text` is the whole "
                  + "description. Empty `text` is refused; `delete: true`, without `text`, removes the section "
                  + "named, or the whole description, and the answer says which in `removed`. With `section`, `old_text` and `new_text` change one string inside that section without sending the rest; refused unless `old_text` occurs there exactly once. Up to 256 KiB. The answer names "
                  + "the sections and the size, not the text: `ghidra_description` reads it. "
                  + descriptionFormat,
                  ["text": AgentSchema.string("The Markdown: the whole description, or one section's body without its heading."),
                   "section": AgentSchema.string("The `## ` heading whose body `text` replaces, e.g. \"Execution flow\"."),
                   "before": AgentSchema.string("The section this `section` goes just before."),
                   "after": AgentSchema.string("The section this `section` goes just after."),
                   "old_text": AgentSchema.string("A string in `section` to change; it must occur there exactly once. Goes with `new_text`, takes no `text`."),
                   "new_text": AgentSchema.string("What `old_text` becomes; may be empty."),
                   "delete": AgentSchema.boolean("Removes the section named, or the whole description. Takes no `text`.")],
                  required: []) { arguments in
                var body: [String: JSONValue] = [:]
                if let text = try arguments.optionalString("text") { body["text"] = .string(text) }
                if let old = try arguments.optionalString("old_text") { body["old_text"] = .string(old) }
                if let new = try arguments.optionalString("new_text") { body["new_text"] = .string(new) }
                if let before = try arguments.optionalString("before") { body["before"] = .string(before) }
                if let after = try arguments.optionalString("after") { body["after"] = .string(after) }
                if try arguments.bool("delete", default: false) { body["delete"] = .bool(true) }
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
                  + "publish cannot carry it; a type an archive holds is refused. With `shared: true` and a "
                  + "`reason` it takes a type out of the shared review archive instead: a name that turned out "
                  + "false. The typedef and its tag go together, and it is refused while another archive type "
                  + "uses them, naming those. Who and why are recorded and shown by `ghidra_type_definition` "
                  + "(`withdrawn`). Modules that took the type keep their copy, but no module opened after it "
                  + "gets it, and a publish cannot bring it back — it reads as a `type_conflicts` entry whose "
                  + "origin says `withdrawn`, and `take_type_conflicts` does not override that. Owners already "
                  + "running hold their copy of the archive until they restart. `ghidra_type_uses` lists what "
                  + "still names it, to walk and correct.",
                  ["c": AgentSchema.string("The C text."),
                   "name": AgentSchema.string("Without `c`: the type to describe, comment or delete."),
                   "description": AgentSchema.string("What the type is, and its source."),
                   "delete": AgentSchema.boolean("Remove the type `name` from the program. No `c` with it."),
                   "shared": AgentSchema.boolean("With `delete`: from the shared review archive, not the program."),
                   "reason": AgentSchema.string("With `shared`: why the name is withdrawn. Required, and recorded."),
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
                if try arguments.bool("shared", default: false) {
                    guard try arguments.bool("delete", default: false) else {
                        throw AgentToolError("`shared` goes with `delete`.")
                    }
                    guard let reason = try arguments.optionalString("reason"),
                          !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AgentToolError("Taking a type out of the shared archive needs a `reason`.")
                    }
                    body["shared"] = .bool(true)
                    body["reason"] = .string(reason)
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
                program is the same revision. `stale_links` lists links in comments and the description whose \
                text is a default name (`FUN_…`) while the target now has a real one: `at` and `kind` say \
                where, `name` is what the text should read; they are reported, not rewritten. `type_conflicts` names types another review defines \
                differently, which stay in this module only: `ghidra_type_definition` shows both, and \
                `type_conflict_origins` names the module that wrote the shared copy. \
                `take_type_conflicts: true` replaces the shared copy of each conflicting type with this \
                module's — the answer to a layout that was published wrong, and never an enum, whose \
                clashing member means one of the two reviews is wrong. The types replaced come back as \
                `type_conflicts_taken`, a typedef and the structure it names each named, since the archive \
                holds them separately. A type made of a replaced one follows it and is not named, so a take \
                can name fewer types than `type_conflicts` listed; a dry run with both flags merges into a \
                copy of the archive and answers what the publish would. \
                The library registry is offered every function tagged `library.<kind>` whose review \
                meets the bar of a finished function: `library` says which bodies became entries \
                (`added`), new versions (`updated` — a change to a function that was the entry's current \
                version, from any module: no module holds an entry), were the same (`unchanged`), or hold \
                another review not made on the current version (`conflicts`: the entry's name and \
                version, the version this review was made on as `base`, who published the current one, \
                and the name this module proposes); `library_below_bar` lists the tagged functions short of the bar with \
                their gaps. `take_library_conflicts: true` with `library_reason` makes this module's review \
                of every conflicting body the entry's next version; a list of entry ids takes those alone, \
                each with its own reason in `library_reason` given as an object — a reason is required for \
                each and kept in the entry's history. The conflicts not taken come back in `conflicts`, \
                with the version this review was based on as `base`. A change names its `module` and \
                `reason` on its row and in the entry's history, so a publish that would move an entry with \
                no reason is refused and stores nothing, naming the entries in the refusal. Give each one \
                in `entry_reasons`, an object of entry id to why this module changes it. A first version, \
                an unchanged entry and a taken conflict with its reason need none; a take that names the \
                entry also speaks for a change on its current version, and a function's own reason does \
                only when its name or signature is all that moved. A store that predates this rule is \
                refused, since it would take the change with no reason. By default the answer carries only \
                what the publish changed; `full: true` adds the list of entries it left as they were. \
                `dry_run: true` answers the same without storing (its artifact hash is taken before the registry's states and marks, so a publish that touches the registry stores another): the artifact's counts, the revision \
                it would become, the description's size, the type conflicts, and — with the library \
                decision given as it would be to the publish — `library`, what the registry offer would \
                do: the entries it would add or move to their next version, the conflicts it would leave, \
                the entries that need a reason in `library.needs_reason` with the refusal in \
                `library_refused`, and the same refusal a take of an entry that is not in conflict gets, \
                in `library_error`. \
                The export is done, so it costs what a publish costs. Publishing is the point another host sees the work; the \
                owner also writes the program out when it idles out, is stopped or gets a signal — not \
                after every change — so only an owner killed outright or crashed loses what came after \
                the last publish.
                """,
            inputSchema: AgentSchema.object([
                "module": moduleProperty,
                "dry_run": AgentSchema.boolean(
                    "Answer what a publish would store — counts, the revision, the conflicts — and store nothing."),
                "take_type_conflicts": AgentSchema.boolean(
                    "Replace the shared copy of each conflicting type with this module's. An enum is never taken."),
                "take_library_conflicts": .object([
                    "type": .array([.string("boolean"), .string("array")]),
                    "items": ["type": "string"],
                    "description": .string("Take the conflicts this module's review wins: true for every "
                        + "one, or a list of entry ids for those alone.")
                ]),
                "library_reason": .object([
                    "type": .array([.string("string"), .string("object")]),
                    "additionalProperties": ["type": "string"],
                    "description": .string("Why this module's review is the better one: one text for "
                        + "take_library_conflicts: true, or an object of entry id to reason for a list.")
                ]),
                "entry_reasons": .object([
                    "type": "object",
                    "additionalProperties": ["type": "string"],
                    "description": .string("Why this module changes each entry this publish moves: an object "
                        + "of entry id to reason, kept in the entry's history.")
                ]),
                "full": AgentSchema.boolean(
                    "Answer with every entry the publish left as it was; by default only what changed.")
            ], required: ["module"]),
            annotations: .edit
        ) { call in
            let module = try module(call.arguments)
            let take = try call.arguments.bool("take_type_conflicts", default: false)
            let libraryTake = try Self.libraryTake(call.arguments)
            let full = try call.arguments.bool("full", default: false)
            if try call.arguments.bool("dry_run", default: false) {
                let reply = try await answer {
                    try await backend.publishPreview(module, takeTypeConflicts: take,
                                                     takeLibrary: libraryTake)
                }
                return full ? reply : Self.compactPublish(reply)
            }
            let options = GhidraHost.PublishOptions(
                takeTypeConflicts: take,
                takeLibrary: libraryTake)
            let reply = try await answer { try await backend.publishModule(module, by: "agent", options: options) }
            return full ? reply : Self.compactPublish(reply)
        }
    }

    static func doneTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_done",
            title: "End the review session",
            description: "Publishes what the project holds and the store has not got, this session's changes or "
                + "an earlier session's, and gives the module's write lease back, so "
                + "another session or a person can write. With nothing changed it publishes nothing. The "
                + "module's owner stays up until it has been idle for a while, so a read or the next open "
                + "costs no start; a later write takes a new lease. A publish that would move a library entry "
                + "with no reason is refused and the lease stays: give `entry_reasons` to `ghidra_publish` first.",
            inputSchema: AgentSchema.object(["module": moduleProperty], required: ["module"]),
            annotations: .edit
        ) { call in
            let module = try module(call.arguments)
            return try await answer { try await backend.releaseModule(module, by: "agent") }
        }
    }

    static func forgetTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_forget",
            title: "Let a module's kept project go",
            description: """
                Stops the module's owner and moves its kept Ghidra project to the Trash, and answers \
                where it went. Nothing of the analysis store is touched: the module's revisions, their \
                artifacts and the shared review types stay, and the module opens again from its bytes \
                and is analysed afresh. This is for a project whose program cannot be put right — an \
                analysis gone wrong that a re-run should replace. Publish what is worth keeping first: \
                the store is the only part that survives.
                """,
            inputSchema: AgentSchema.object(["module": moduleProperty], required: ["module"]),
            annotations: .edit
        ) { call in
            let module = try module(call.arguments)
            return try await answer { try await backend.forgetModule(module) }
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
