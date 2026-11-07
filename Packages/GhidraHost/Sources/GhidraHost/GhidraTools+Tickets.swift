import AgentKit
import CodeAnalysis
import Foundation

/// The review board as tools: a verifier writes what is wrong in a module's
/// review, the reviewer answers and fixes it there, and a verifier other than
/// the reviewer closes the module's ticket (`TicketBook`).
extension GhidraTools {
    static let agentProperty = AgentSchema.string(
        "Your own name as an agent, e.g. \"Review Manager\" or \"Verifier · devex-macbook\": several agents share "
            + "one token, and the board tells them apart by it. Use the same name every time.")

    static func ticketTools(_ backend: GhidraBackend) -> [AgentTool] {
        [ticketsTool(backend), remarkTool(backend), replyTool(backend), closeTicketTool(backend)]
    }

    static func ticketsTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_tickets",
            title: "Read the review board",
            description: """
                The review board: one ticket per module, holding the remarks verifying agents made on its \
                review, each with its author, severity (`wrong`, `misleading`, `cosmetic`), status (`open`, \
                `answered`, `fixed`, `wont_fix`, `verified`) and thread of replies. With `module`, that \
                module's ticket in full (`state: "none"` when it has none). Without, the tickets, newest \
                activity first, narrowed by `state` — `open` (a remark is still to be dealt with), \
                `settled` (none is, not yet closed), `closed` — and by `author`, an agent's name: a \
                reviewer reads `author` = its own name to find the remarks on its work, and \
                `state: "open"` for what waits. A ticket's `reviewer` is the agent that took the module \
                into work last.
                """,
            inputSchema: AgentSchema.object([
                "module": moduleProperty,
                "state": AgentSchema.choice(["open", "settled", "closed"], "Only tickets in this state."),
                "author": AgentSchema.string("Only tickets where this agent wrote, replied or is the reviewer.")
            ]),
            annotations: .readOnly
        ) { call in
            let arguments = call.arguments
            let module = try arguments.optionalString("module")
            let request = TicketBook.Request(action: module == nil ? .list : .read, module: module,
                                             state: try arguments.optionalString("state"),
                                             author: try arguments.optionalString("author"))
            return try await answer { try await backend.tickets(request) }
        }
    }

    static func remarkTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_ticket_remark",
            title: "Write a remark on a module's review",
            description: """
                Writes a remark on the module's ticket — made if the module has none, opened again if it \
                was closed: a closed module is open again until a verifier closes it once more. One remark \
                per finding: what the review says, what the code does, where (`function`, `address`), and \
                `severity`: `wrong` (the review says what the code does not do), `misleading` (true, but a \
                reader gets a wrong idea), `cosmetic` (wording, a name's style). The remark is raised \
                against the module's published revision unless `revision` names another. It stays open \
                across revisions until a verifier marks it `verified`. Answers the ticket.
                """,
            inputSchema: AgentSchema.object([
                "agent": agentProperty,
                "module": moduleProperty,
                "severity": AgentSchema.choice(TicketBook.Severity.allCases.map(\.rawValue), "How much it matters."),
                "text": AgentSchema.string("The finding: what the review says, what the code does, what it should say."),
                "function": AgentSchema.string("The function it is in, by name or entry."),
                "address": AgentSchema.string("The address it is about, hex."),
                "revision": AgentSchema.integer("The revision read, when not the last published.")
            ], required: ["agent", "module", "severity", "text"]),
            annotations: .edit
        ) { call in
            let arguments = call.arguments
            guard let severity = TicketBook.Severity(rawValue: try arguments.string("severity")) else {
                throw AgentToolError("`severity` is wrong, misleading or cosmetic.")
            }
            let remark = TicketBook.NewRemark(
                severity: severity, text: try arguments.string("text"),
                function: try arguments.optionalString("function"), address: try arguments.optionalString("address"),
                revision: arguments["revision"] == nil ? nil : Int(clamping: try arguments.integer("revision")))
            let request = TicketBook.Request(action: .add, agent: try arguments.string("agent"),
                                             module: try arguments.string("module"), remark: remark)
            return try await answer { try await backend.tickets(request) }
        }
    }

    static func replyTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_ticket_reply",
            title: "Reply to a remark",
            description: """
                Replies in a remark's thread and, with `status`, moves it on. The reviewer sets `answered` \
                (a reply, the review unchanged — say why), `fixed` (with the `revision` the fix is \
                published in) or `wont_fix` (say why). Another agent — not the one that took the module \
                into work — sets `verified` after reading the fix or accepting the answer, or `open` when \
                it is not right yet; the reviewer setting either is refused. A reply with no `status` is \
                part of the conversation. Answers the ticket.
                """,
            inputSchema: AgentSchema.object([
                "agent": agentProperty,
                "module": moduleProperty,
                "id": AgentSchema.string("The remark's `id`, as `ghidra_tickets` lists it."),
                "text": AgentSchema.string("The reply."),
                "status": AgentSchema.choice(TicketBook.Status.allCases.map(\.rawValue), "The remark's new status."),
                "revision": AgentSchema.integer("For `fixed`: the revision the fix is published in.")
            ], required: ["agent", "module", "id"]),
            annotations: .edit
        ) { call in
            let arguments = call.arguments
            var status: TicketBook.Status?
            if let text = try arguments.optionalString("status") {
                guard let value = TicketBook.Status(rawValue: text) else {
                    throw AgentToolError("`status` is one of: "
                        + TicketBook.Status.allCases.map(\.rawValue).joined(separator: ", ") + ".")
                }
                status = value
            }
            let request = TicketBook.Request(
                action: .reply, agent: try arguments.string("agent"), module: try arguments.string("module"),
                id: try arguments.string("id"), text: try arguments.optionalString("text"), status: status,
                revision: arguments["revision"] == nil ? nil : Int(clamping: try arguments.integer("revision")))
            return try await answer { try await backend.tickets(request) }
        }
    }

    static func closeTicketTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_ticket_close",
            title: "Close a module's review",
            description: """
                Closes the module's ticket: its review is checked and stands. Refused while a remark is \
                `open`, `answered` or `fixed` and not yet `verified`, naming them, and refused to the agent \
                that took the module into work — another verifier closes it. A module with no remarks is \
                closed with none: checked and found right. A later remark opens it again. Answers the ticket.
                """,
            inputSchema: AgentSchema.object([
                "agent": agentProperty,
                "module": moduleProperty,
                "note": AgentSchema.string("What was checked, in a line.")
            ], required: ["agent", "module"]),
            annotations: .edit
        ) { call in
            let arguments = call.arguments
            let request = TicketBook.Request(action: .close, agent: try arguments.string("agent"),
                                             module: try arguments.string("module"),
                                             note: try arguments.optionalString("note"))
            return try await answer { try await backend.tickets(request) }
        }
    }

    /// What `ghidra_create` and `ghidra_take` add of the module's ticket: its
    /// state and the remarks still to be dealt with, each in a line. Nothing
    /// when the module has no ticket or the backend keeps no board.
    static func reviewSummary(_ data: Data) -> [String: Any]? {
        guard let ticket = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = ticket["state"] as? String, state != "none" else { return nil }
        var summary: [String: Any] = ["state": state, "open_remarks": ticket["open_remarks"] ?? 0]
        let remarks = (ticket["remarks"] as? [[String: Any]] ?? []).filter {
            ["open", "answered", "fixed"].contains($0["status"] as? String ?? "")
        }
        if !remarks.isEmpty {
            summary["remarks"] = remarks.prefix(20).map { remark -> [String: Any] in
                var line: [String: Any] = [:]
                for key in ["id", "severity", "status", "author", "function", "address"] where remark[key] != nil {
                    line[key] = remark[key]
                }
                let text = remark["text"] as? String ?? ""
                line["text"] = text.count > 240 ? String(text.prefix(239)) + "…" : text
                return line
            }
            summary["read"] = "ghidra_tickets with this module reads the threads"
        }
        return summary
    }
}
