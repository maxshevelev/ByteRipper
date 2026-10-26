import AgentKit
import CodeAnalysis
import Foundation

/// The code analysis a panel is showing, as an agent's questions
/// (`Design/CODE_PANEL_PLAN.md`, stage 5). The same typed artifact the panel
/// reads: no second parse, and no Ghidra on the agent's side.
@MainActor
final class AgentCodeTools {
    private let desk: AgentDesk

    init(desk: AgentDesk) {
        self.desk = desk
    }

    nonisolated func tools() -> [AgentTool] { [queryTool] }

    private static let lists = ["functions", "instructions", "c", "uses", "strings", "references"]

    private nonisolated var queryTool: AgentTool {
        AgentTool(
            name: "code_query",
            title: "Read a module's code analysis",
            description: """
                Read the stored code analysis a Code panel is showing. `what` picks the list (default \
                "functions"): "functions"; one function's "instructions" or decompiled "c"; a function's \
                callers and callees ("references"); the instructions that "uses" an address — who calls a \
                function, jumps to a label, or reads a global or a string; or "strings". `function` names \
                one by its name or Ghidra entry address; `address` is the target for "uses"; `search` \
                narrows functions by name or instruction text, and strings by value. Addresses come \
                twice: `entry`/`address` is Ghidra's virtual address, `offset` is the same byte's offset \
                in the module, the number the hex view shows. The document must be open as a Code panel \
                or a Code tab; the answer names its module and recipe. These are stored observations, not \
                a live disassembly; the C is Ghidra's reading of the instructions, not the source.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The document's id from `documents`. Default: the focused one."),
                "what": AgentSchema.choice(Self.lists, "The list to read. Default \"functions\"."),
                "function": AgentSchema.string("A function name or Ghidra entry address, for \"instructions\", \"c\" and \"references\"."),
                "address": AgentSchema.string("A Ghidra address, for \"uses\"."),
                "search": AgentSchema.string("A word to narrow functions or strings by."),
                "limit": AgentSchema.limit(default: 200, maximum: 500)
            ])
        ) { call in
            try await self.answer(call.arguments)
        }
    }

    private func answer(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try desk.place(named: try arguments.optionalString("document"))
        guard let controller = place.controller else {
            throw AgentToolError("\(place.named) is not on screen, so it has no code panel.")
        }
        guard let screen = controller.codeScreen(for: place.pane) else {
            throw AgentToolError("\(place.named) is not a code screen. Open the module with `Open with Code` first.")
        }
        let what = try arguments.choice("what", from: Self.lists, default: "functions")
        let search = (try arguments.optionalString("search"))?.lowercased()
        let limit = try arguments.limit(default: 200, maximum: 500)
        let model = CodeModel(artifact: screen.artifact, moduleBytes: screen.bytes)

        func offsetText(_ address: CodeAddress) -> JSONValue {
            guard let offset = model.moduleOffset(of: address) else { return .null }
            return .string("0x" + String(offset, radix: 16, uppercase: true))
        }
        func reference(_ address: CodeAddress) -> JSONValue {
            var members: [String: JSONValue] = [
                "entry": .string(address.description),
                "offset": offsetText(address)
            ]
            if let index = model.function(at: address), !model.functions[index].name.isEmpty {
                members["name"] = .string(model.functions[index].name)
            }
            return .object(members)
        }
        func namedFunction() throws -> CodeArtifact.Function {
            guard let name = try arguments.optionalString("function") else {
                throw AgentToolError("Argument `function` is required for this `what`.")
            }
            guard let index = model.function(named: name) else {
                throw AgentToolError("No function \"\(name)\" in this analysis.")
            }
            return model.functions[index]
        }

        var body: [String: JSONValue] = [
            "document": .string(place.id),
            "what": .string(what),
            "module": .string(screen.manifest.module.name),
            "recipe": .string(screen.manifest.recipe.id)
        ]

        switch what {
        case "functions":
            let functions = model.functions(matching: search ?? "").map { model.functions[$0] }
            body["total"] = .int(Int64(functions.count))
            body["functions"] = .array(functions.prefix(limit).map { function in
                .object([
                    "name": .string(function.name),
                    "entry": .string(function.entry.description),
                    "offset": offsetText(function.entry),
                    "size": function.size.map { JSONValue.int(Int64($0)) } ?? JSONValue.null,
                    "external": .bool(function.external),
                    "thunk": .bool(function.thunk),
                    "signature": function.signature.map(JSONValue.string) ?? .null,
                    "callers": .array(function.callers.map { .string($0.description) }),
                    "callees": .array(function.callees.map { .string($0.description) })
                ])
            })

        case "instructions":
            let function = try namedFunction()
            body["function"] = .string(function.name)
            body["total"] = .int(Int64(function.instructions.count))
            body["instructions"] = .array(function.instructions.prefix(limit).map { instruction in
                .object([
                    "address": .string(instruction.address.description),
                    "offset": offsetText(instruction.address),
                    "bytes": .string(instruction.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")),
                    "mnemonic": instruction.mnemonic.map(JSONValue.string) ?? .null,
                    "text": .string(instruction.text),
                    "references": .array(instruction.references.map {
                        .object(["to": .string($0.to.description), "type": .string($0.type)])
                    })
                ])
            })

        case "c":
            let function = try namedFunction()
            body["function"] = .string(function.name)
            body["entry"] = .string(function.entry.description)
            body["signature"] = function.signature.map(JSONValue.string) ?? .null
            body["c"] = function.c.map(JSONValue.string) ?? .null
            if function.c == nil {
                body["note"] = .string("Ghidra left no C for this function: it is external, a thunk, or did not decompile.")
            }

        case "uses":
            guard let text = try arguments.optionalString("address"),
                  let address = CodeAddress(hex: text) else {
                throw AgentToolError("Argument `address` is required for \"uses\": a Ghidra address such as 0x4BF.")
            }
            let uses = model.uses(of: address)
            body["address"] = .string(address.description)
            body["offset"] = offsetText(address)
            body["total"] = .int(Int64(uses.count))
            body["uses"] = .array(uses.prefix(limit).map { use in
                .object([
                    "from": .string(use.from.description),
                    "offset": offsetText(use.from),
                    "type": .string(use.type),
                    "function": .string(model.functions[use.function].name),
                    "text": .string(model.lines[use.line].instruction.text)
                ])
            })

        case "strings":
            let strings = screen.artifact.strings.filter { entry in
                guard let search, !search.isEmpty else { return true }
                return entry.value.lowercased().contains(search)
                    || entry.type.lowercased().contains(search)
                    || entry.address.description.lowercased().contains(search)
            }
            body["total"] = .int(Int64(strings.count))
            body["strings"] = .array(strings.prefix(limit).map { entry in
                .object([
                    "address": .string(entry.address.description),
                    "offset": offsetText(entry.address),
                    "type": .string(entry.type),
                    "value": .string(entry.value)
                ])
            })

        default:
            let function = try namedFunction()
            body["function"] = .string(function.name)
            body["callers"] = .array(function.callers.map(reference))
            body["callees"] = .array(function.callees.map(reference))
        }
        return .json(.object(body))
    }
}
