import AgentKit
import ToolModuleKit

/// A tool-module's query as a tool of a host: the `document` argument added,
/// resolved by the host's rule, the query run on that document's read host,
/// and the answer saying which document it was about
/// (`Design/SERVER_HEADLESS_PLAN.md` §4.1).
public enum ToolQueryTools {
    /// What a host wraps around a query's run — the app's node links name
    /// the same node in a part and its parent. `body` runs the query.
    public typealias Around = @MainActor @Sendable (
        _ document: any AgentDocument, _ body: () async throws -> AgentAnswer
    ) async throws -> AgentAnswer

    /// - Parameter document: what the schema says of the `document`
    ///   argument, which is the host's rule in words.
    public static func tool(for query: ToolAgentQuery, documents: any AgentDocumentSet, document: String,
                            around: Around? = nil) -> AgentTool {
        var properties = query.properties
        properties["document"] = AgentSchema.string(document)
        return AgentTool(
            name: query.name, title: query.title, description: query.description,
            inputSchema: AgentSchema.object(properties, required: query.required)
        ) { call in
            try await run(query, documents: documents, around: around, call.arguments)
        }
    }

    @MainActor
    static func run(_ query: ToolAgentQuery, documents: any AgentDocumentSet, around: Around?,
                    _ arguments: AgentArguments) async throws -> AgentAnswer {
        let document = try documents.resolve(arguments.optionalString("document"))
        let host = document.readHost()
        let body = { try await query.run(host, arguments) }
        let answer: AgentAnswer
        if let around {
            answer = try await around(document, body)
        } else {
            answer = try await body()
        }
        return stamped(answer, with: document)
    }

    /// `answer` with `document` in it, and `disk` beside it when the file on
    /// disk is no longer the one read: an agent calls `documents` once and
    /// works in the other tools after, so that is where it must see the mark.
    public static func stamped(_ answer: AgentAnswer, with document: any AgentDocument) -> AgentAnswer {
        guard case .json(.object(var members)) = answer else { return answer }
        members["document"] = .string(document.id)
        if let disk = document.disk { members["disk"] = .string(disk) }
        return .json(.object(members))
    }
}
