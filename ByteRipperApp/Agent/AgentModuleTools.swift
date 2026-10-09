import Cocoa
import AgentKit
import Localization
import ToolModuleKit

/// The tools the tool-modules contribute, turned into tools the server lists,
/// and `open_panel`, which is how an agent reaches a panel that is not open
/// (`Design/AGENT_PLAN.md`, "What a tool-module contributes").
///
/// A query runs against a read host for the document the agent names — the
/// pane's own shared parse, whatever the left panel shows. An action runs on
/// the live session of its module in the tab holding the document, and when
/// there is none it says so and names `open_panel`. The list is the same
/// whatever is open: a client plans against a list that holds still.
@MainActor
final class AgentModuleTools {
    let desk: AgentDesk
    /// The one door a module's edit is applied through.
    private let edits: AgentEditTools
    private let modules: () -> [any ToolModule.Type]

    init(desk: AgentDesk, edits: AgentEditTools,
         modules: @escaping () -> [any ToolModule.Type] = { ToolRegistry.modules }) {
        self.desk = desk
        self.edits = edits
        self.modules = modules
    }

    /// Every module's queries, its comparisons of two documents, its edits,
    /// then every module's actions, then `open_panel`.
    nonisolated func tools(modules list: [any ToolModule.Type]) -> [AgentTool] {
        let queries = list.flatMap { module in module.agentQueries.map { query(module, $0) } }
        let comparisons = list.flatMap { module in module.agentComparisons.map { comparison($0) } }
        let edits = list.flatMap { module in module.agentEdits.map { edit($0) } }
        let actions = list.flatMap { module in module.agentActions.map { action(module, $0) } }
        return queries + comparisons + edits + actions + [openPanelTool(list)]
    }

    /// What `open_panel` and the "not open" answers call a module: the last
    /// part of its identifier, `uefi-structure` for
    /// `dev.maxik.tool.uefi-structure`.
    nonisolated static func shortName(of module: any ToolModule.Type) -> String {
        String(module.identifier.split(separator: ".").last ?? Substring(module.identifier))
    }

    // MARK: - Queries

    private nonisolated func query(_ module: any ToolModule.Type, _ query: ToolAgentQuery) -> AgentTool {
        var properties = query.properties
        properties["document"] = AgentSchema.string("The document's id from `documents`. Default: the focused one.")
        return AgentTool(
            name: query.name, title: query.title, description: query.description,
            inputSchema: AgentSchema.object(properties, required: query.required)
        ) { call in
            try await self.runQuery(query, call.arguments)
        }
    }

    private func runQuery(_ query: ToolAgentQuery, _ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments)
        // A host that reads and nothing else: no session is behind it, and a
        // query must not draw zones or put up sheets on a panel that is not
        // there.
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        var answer = try await query.run(host, arguments)
        if case .json(let value) = answer, case .object(var members) = value {
            members["document"] = .string(place.id)
            answer = .json(.object(members))
        }
        return answer
    }

    // MARK: - Comparisons

    private nonisolated func comparison(_ comparison: ToolAgentComparison) -> AgentTool {
        var properties = comparison.properties
        properties["document"] = AgentSchema.string("The first document's id from `documents`. Default: the focused one.")
        properties["against"] = AgentSchema.string("The id of the document to set beside it, from `documents` or `open_dump`.")
        return AgentTool(
            name: comparison.name, title: comparison.title, description: comparison.description,
            inputSchema: AgentSchema.object(properties, required: comparison.required + ["against"])
        ) { call in
            try await self.runComparison(comparison, call.arguments)
        }
    }

    private func runComparison(_ comparison: ToolAgentComparison, _ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments)
        let other = try resolve(id: arguments.string("against"))
        guard other.pane !== place.pane else {
            throw AgentToolError("`document` and `against` are the same document, \(place.id).")
        }
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        let otherHost = PaneToolHost(pane: other.pane, owner: other.controller, tools: nil)
        var answer = try await comparison.run(host, otherHost, arguments)
        if case .json(let value) = answer, case .object(var members) = value {
            members["document"] = .string(place.id)
            members["against"] = .string(other.id)
            answer = .json(.object(members))
        }
        return answer
    }

    // MARK: - Edits

    private nonisolated func edit(_ edit: ToolAgentEdit) -> AgentTool {
        var properties = edit.properties
        properties["document"] = AgentSchema.string("The document's id from `documents`. Default: the focused one.")
        return AgentTool(
            name: edit.name, title: edit.title, description: edit.description,
            inputSchema: AgentSchema.object(properties, required: edit.required),
            annotations: .edit
        ) { call in
            try await self.runEdit(edit, call.arguments)
        }
    }

    /// The module works the change out; `AgentEditTools` decides whether it
    /// is made — asked first too, so a refused edit costs no parse.
    private func runEdit(_ edit: ToolAgentEdit, _ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments)
        try edits.checkEditable(place)
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        let version = host.contentVersion
        let transaction = try await edit.run(host, arguments)
        guard host.contentVersion == version else {
            throw AgentToolError("\(place.id) changed while the edit was being worked out; nothing was written. Ask again.")
        }
        let undoName = AgentEditTools.inAppLanguage { L("Agent: %1$@", edit.undoName()) }
        return .json(try edits.apply(ToolTransaction(name: undoName, writes: transaction.writes), to: place))
    }

    // MARK: - Actions

    private nonisolated func action(_ module: any ToolModule.Type, _ action: ToolAgentAction) -> AgentTool {
        var properties = action.properties
        properties["document"] = AgentSchema.string("The document's id from `documents`. Default: the focused one.")
        let identifier = module.identifier
        let title = module.title
        let short = Self.shortName(of: module)
        return AgentTool(
            name: action.name, title: action.title, description: action.description,
            inputSchema: AgentSchema.object(properties, required: action.required),
            annotations: action.changesView ? .view : .readOnly
        ) { call in
            try await self.runAction(action, identifier: identifier, title: title, short: short, call.arguments)
        }
    }

    private func runAction(_ action: ToolAgentAction, identifier: String, title: String, short: String,
                           _ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments)
        let tools = try place.onScreen().tools(reading: place.pane)
        guard tools.activeIdentifier == identifier, tools.boundPane === place.pane, let session = tools.session else {
            throw AgentToolError("The \(title) panel is not open on \(place.id). "
                + "Call `open_panel` with module \"\(short)\" first, or show the bytes with `reveal`.")
        }
        if action.changesView { desk.bringForward(place) }
        return try await action.run(session, arguments)
    }

    // MARK: - open_panel

    private nonisolated func openPanelTool(_ list: [any ToolModule.Type]) -> AgentTool {
        let names = list.map { Self.shortName(of: $0) }
        let catalogue = list.map { "\"\(Self.shortName(of: $0))\" (\($0.title))" }.joined(separator: ", ")
        return AgentTool(
            name: "open_panel",
            title: "Open a tool panel",
            description: """
                Opens a tool panel on a document, the way the Tools menu does: the panel down the left of \
                its tab switches to `module` and reads that document. The panel that was there keeps its \
                place for when the person returns to it, and the switch is a step of the navigation history. \
                Refused while the person is in the middle of something in that window — a dialog, a sheet. \
                Modules: \(catalogue).
                """,
            inputSchema: AgentSchema.object([
                "module": AgentSchema.choice(names, "Which panel."),
                "document": AgentSchema.string("The document's id from `documents`. Default: the focused one.")
            ], required: ["module"]),
            annotations: .view
        ) { call in
            try await self.openPanel(call.arguments, names: names)
        }
    }

    private func openPanel(_ arguments: AgentArguments, names: [String]) async throws -> AgentAnswer {
        let short = try arguments.choice("module", from: names)
        guard let module = modules().first(where: { Self.shortName(of: $0) == short }) else {
            throw AgentToolError("No module \"\(short)\" in this copy of ByteRipper.")
        }
        let place = try resolve(arguments)
        let controller = try place.onScreen()
        if let window = controller.view.window, window.attachedSheet != nil {
            throw AgentToolError("A dialog is open in that window. Ask the person to finish it first.")
        }
        let tools = controller.tools(reading: place.pane)
        let alreadyOpen = tools.activeIdentifier == module.identifier && tools.boundPane === place.pane
        if !alreadyOpen {
            desk.bringForward(place)
            controller.recordJump(in: place.pane)
            tools.activate(module.identifier)
            if tools.boundPane !== place.pane { tools.rebind(to: place.pane) }
            controller.refreshToolPanelHeader()
        }
        guard tools.activeIdentifier == module.identifier, tools.boundPane === place.pane else {
            throw AgentToolError("The \(module.title) panel could not be opened on \(place.id).")
        }
        return .json(["document": .string(place.id), "module": .string(short),
                      "panel": .string(module.title), "was_open": .bool(alreadyOpen)])
    }

    // MARK: - Documents

    private func resolve(_ arguments: AgentArguments) throws -> AgentDesk.Place {
        try resolve(id: arguments.optionalString("document"))
    }

    private func resolve(id: String?) throws -> AgentDesk.Place {
        do {
            return try desk.place(named: id)
        } catch let error as AgentDeskError {
            throw AgentToolError(error.description)
        }
    }
}
