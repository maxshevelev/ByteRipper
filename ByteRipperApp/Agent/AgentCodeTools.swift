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

    private nonisolated var queryTool: AgentTool {
        AgentTool(
            name: "code_query",
            title: "Read a module's code analysis",
            description: """
                Read the stored code analysis a Code panel is showing: functions, one function's \
                instructions, strings, or a function's callers and callees. `what` picks the list \
                (default "functions"); `function` names one by its name or Ghidra entry address for \
                "instructions" and "references"; `search` narrows functions by name or instruction text, \
                and strings by value. Addresses come twice: `entry` is Ghidra's virtual address, `offset` \
                is the same byte's offset in the module, the number the hex view shows. The document must \
                be open as a Code panel or a Code tab; the answer names its module and recipe. These are \
                stored observations, not a live disassembly; `code` panels show the same model.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The document's id from `documents`. Default: the focused one."),
                "what": AgentSchema.choice(["functions", "instructions", "strings", "references"],
                                           "The list to read. Default \"functions\"."),
                "function": AgentSchema.string("A function name or Ghidra entry address, for \"instructions\" and \"references\"."),
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
        let what = try arguments.choice("what", from: ["functions", "instructions", "strings", "references"],
                                        default: "functions")
        let search = (try arguments.optionalString("search"))?.lowercased()
        let limit = try arguments.limit(default: 200, maximum: 500)
        let layout = try? ModuleLayout(module: screen.bytes)
        let base = screen.artifact.program?.imageBase?.value

        func addressText(_ address: CodeAddress) -> String { address.description }
        func offsetText(_ address: CodeAddress) -> JSONValue {
            guard let layout,
                  let offset = layout.fileOffset(for: address, imageBase: base)
            else { return .null }
            return .string("0x" + String(offset, radix: 16, uppercase: true))
        }
        func reference(_ address: CodeAddress) -> JSONValue {
            let named = screen.artifact.functions.first { $0.entry == address }
            var members: [String: JSONValue] = [
                "entry": .string(addressText(address)),
                "offset": offsetText(address)
            ]
            if let named, !named.name.isEmpty { members["name"] = .string(named.name) }
            return .object(members)
        }

        var body: [String: JSONValue] = [
            "document": .string(place.id),
            "what": .string(what),
            "module": .string(screen.manifest.module.name),
            "recipe": .string(screen.manifest.recipe.id)
        ]

        switch what {
        case "functions":
            let functions = screen.artifact.functions.filter { function in
                guard let search, !search.isEmpty else { return true }
                return function.name.lowercased().contains(search)
                    || function.entry.description.lowercased().contains(search)
                    || (function.signature?.lowercased().contains(search) ?? false)
                    || function.instructions.contains {
                        $0.text.lowercased().contains(search)
                            || ($0.mnemonic?.lowercased().contains(search) ?? false)
                    }
            }
            body["total"] = .int(Int64(functions.count))
            body["functions"] = .array(functions.prefix(limit).map { function in
                .object([
                    "name": .string(function.name),
                    "entry": .string(addressText(function.entry)),
                    "offset": offsetText(function.entry),
                    "size": function.size.map { JSONValue.int(Int64($0)) } ?? JSONValue.null,
                    "external": .bool(function.external),
                    "thunk": .bool(function.thunk),
                    "signature": function.signature.map(JSONValue.string) ?? .null,
                    "callers": .array(function.callers.map { .string(addressText($0)) }),
                    "callees": .array(function.callees.map { .string(addressText($0)) })
                ])
            })

        case "instructions":
            let function = try namedFunction(arguments, in: screen.artifact)
            body["function"] = .string(function.name)
            body["total"] = .int(Int64(function.instructions.count))
            body["instructions"] = .array(function.instructions.prefix(limit).map { instruction in
                .object([
                    "address": .string(addressText(instruction.address)),
                    "offset": offsetText(instruction.address),
                    "bytes": .string(instruction.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")),
                    "mnemonic": instruction.mnemonic.map(JSONValue.string) ?? .null,
                    "text": .string(instruction.text),
                    "references": .array(instruction.references.map {
                        .object(["to": .string(addressText($0.to)), "type": .string($0.type)])
                    })
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
                    "address": .string(addressText(entry.address)),
                    "offset": offsetText(entry.address),
                    "type": .string(entry.type),
                    "value": .string(entry.value)
                ])
            })

        default:
            let function = try namedFunction(arguments, in: screen.artifact)
            body["function"] = .string(function.name)
            body["callers"] = .array(function.callers.map(reference))
            body["callees"] = .array(function.callees.map(reference))
        }
        return .json(.object(body))
    }

    private func namedFunction(_ arguments: AgentArguments,
                               in artifact: CodeArtifact) throws -> CodeArtifact.Function {
        guard let name = try arguments.optionalString("function") else {
            throw AgentToolError("Argument `function` is required for this `what`.")
        }
        if let function = artifact.functions.first(where: { $0.name == name }) {
            return function
        }
        if let address = CodeAddress(hex: name),
           let function = artifact.functions.first(where: { $0.entry == address }) {
            return function
        }
        throw AgentToolError("No function \"\(name)\" in this analysis.")
    }
}
