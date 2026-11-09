import AgentKit
import CodeAnalysis
import Foundation

/// Agents agreeing a replacement of shared types, as tools: the module's
/// holder proposes, other agents vote, and the module's next publish applies
/// an agreed proposal (`TypeProposalBook`).
extension GhidraTools {
    static func typeProposalTools(_ backend: GhidraBackend) -> [AgentTool] {
        [typeProposalsTool(backend), typeProposeTool(backend), typeVoteTool(backend)]
    }

    static func typeProposalsTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_type_proposals",
            title: "Read the shared-type proposals",
            description: """
                Proposals to replace shared types, newest first. Each has the module that proposes, the types, \
                each as the module defines it (`module_c`) and as the shared types hold it (`shared_c`), the \
                module that wrote the shared copy (`origins`), the author's `reason`, the votes, and its \
                `state`: `open` (waiting, or held by an objection), `agreed` (\(TypeProposalBook.agreesNeeded) \
                agents other than the author agree and none objects: the module's next publish applies it), \
                `applied`, `rejected` (by the person), `withdrawn`. With `id`, that proposal; otherwise \
                narrowed by `state` and `module`. A verifier reads `state: "open"` for what waits for its vote.
                """,
            inputSchema: AgentSchema.object([
                "id": AgentSchema.string("One proposal's `id`."),
                "state": AgentSchema.choice(TypeProposalBook.State.allCases.map(\.rawValue), "Only proposals in this state."),
                "module": moduleProperty
            ]),
            annotations: .readOnly
        ) { call in
            let arguments = call.arguments
            let id = try arguments.optionalString("id")
            let request = TypeProposalBook.Request(action: id == nil ? .list : .read,
                                                   module: try arguments.optionalString("module"), id: id,
                                                   state: try arguments.optionalString("state"))
            return try await answer { try await backend.typeProposals(request) }
        }
    }

    static func typeProposeTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_type_propose",
            title: "Propose replacing shared types",
            description: """
                When this module's publish is refused because it would replace shared types, and the shared \
                definitions are the wrong ones: proposes this module's definitions as the shared ones. Only \
                the module's holder proposes, with the module in work. The proposal keeps each type as the \
                module defines it now and as the shared types hold it, and `reason` — the evidence: the \
                instructions, offsets and callers that prove the module's layout and disprove the shared one. \
                Other agents vote with `ghidra_type_vote`. Once \(TypeProposalBook.agreesNeeded) agents other \
                than you agree and none objects, this module's next publish (`ghidra_publish`, `ghidra_done`) \
                replaces the shared types, as their next version — provided the module still defines them as \
                proposed and nobody changed the shared ones meanwhile; otherwise it is refused as before, and \
                you propose again. Every other module whose review uses a replaced type then gets a remark on \
                its ticket. One live proposal per module, and per type: a refusal names the one in the way. \
                The person can agree or reject any proposal in the server's console.
                """,
            inputSchema: AgentSchema.object([
                "agent": agentProperty,
                "module": moduleProperty,
                "reason": AgentSchema.string("Why the shared definitions are wrong and this module's right: the evidence, with addresses.")
            ], required: ["agent", "module", "reason"]),
            annotations: .edit
        ) { call in
            let arguments = call.arguments
            let request = TypeProposalBook.Request(action: .propose, agent: try arguments.string("agent"),
                                                   module: try arguments.string("module"),
                                                   reason: try arguments.string("reason"))
            return try await answer { try await backend.typeProposals(request) }
        }
    }

    static func typeVoteTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_type_vote",
            title: "Vote on a shared-type proposal",
            description: """
                Votes on a proposal to replace shared types (`ghidra_type_proposals`). Read both definitions \
                and check the author's evidence against the code first — the module's instructions and those \
                of the modules that use the shared type (`ghidra_type_uses`). `agree` when the module's \
                layout is right; `object` with `text` saying what is wrong, with evidence: an objection holds \
                the proposal until you vote again. Your later vote replaces your earlier one. The author does \
                not vote. `withdraw` is the author's: it takes the proposal back. Answers with the proposal, \
                its `state`, `agrees` and `objections`.
                """,
            inputSchema: AgentSchema.object([
                "agent": agentProperty,
                "id": AgentSchema.string("The proposal's `id`."),
                "choice": AgentSchema.choice(["agree", "object", "withdraw"], "Your vote, or the author's withdrawal."),
                "text": AgentSchema.string("Why: required to object; a note otherwise.")
            ], required: ["agent", "id", "choice"]),
            annotations: .edit
        ) { call in
            let arguments = call.arguments
            let choice = try arguments.string("choice")
            var request = TypeProposalBook.Request(action: .vote, agent: try arguments.string("agent"),
                                                   id: try arguments.string("id"),
                                                   text: try arguments.optionalString("text"))
            if choice == "withdraw" {
                request.action = .withdraw
            } else {
                guard let value = TypeProposalBook.Choice(rawValue: choice) else {
                    throw AgentToolError("`choice` is agree, object or withdraw.")
                }
                request.choice = value
            }
            return try await answer { try await backend.typeProposals(request) }
        }
    }
}
