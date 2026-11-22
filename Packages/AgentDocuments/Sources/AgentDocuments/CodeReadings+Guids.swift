import AgentKit
import CodeAnalysis
import Foundation
import UEFIImage

extension CodeReadings {
    /// The shared registry of GUID names (`GuidRegistry`): its entries, or one
    /// entry with its versions and the places reviews cite it.
    public nonisolated var guidTool: AgentTool {
        AgentTool(
            name: "guid_registry",
            title: "Read the GUID name registry",
            description: """
                The shared registry of GUID names: one name for each GUID a review names in a module's \
                code — a PPI, a protocol, a HOB, a variable's vendor GUID, an event group, a configuration \
                table — in EDK2's variable form, `gEfiPeiMemoryDiscoveredPpiGuid`. Each entry says where \
                its name comes from (`source`): `edk2`, a `.dec` file of the pinned tag with its line, or \
                `review`, the module and the address where the code shows what the GUID is. A name \
                `gUnknown…` is a placeholder: the GUID's role is known, its name is not. Without `guid`: \
                the entries — `guid`, `name`, `kind`, `source`, `version` — narrowed by `search` (a part \
                of the name, or the start of the GUID), `kind` and `source`, sorted by name, paged by \
                `limit` and `after`. With `guid`: that entry, with its `note`, the `citations` (every \
                module and address a review named it with this name) and its `history`, each earlier \
                version with who replaced it and why. Name a GUID in a review as the registry does; a \
                GUID it does not hold is added with `ghidra_guid_add` where the server offers it.
                """,
            inputSchema: AgentSchema.object([
                "guid": AgentSchema.string("A GUID, 8-4-4-4-12, for its entry."),
                "search": AgentSchema.string("Only entries whose name holds this text, any case, or whose GUID starts with it."),
                "kind": AgentSchema.choice(GuidKind.allCases.map(\.rawValue), "Only entries of this kind."),
                "source": AgentSchema.choice(["edk2", "review"], "Only entries whose name comes from here."),
                "limit": AgentSchema.limit(default: 200, maximum: 1000),
                "after": AgentSchema.string("The `next` of the page before.")
            ])
        ) { call in
            .json(try await self.guids(call.arguments))
        }
    }

    /// The GUID registry of the store a call reads; empty when there is none.
    func guidRegistry() async -> GuidRegistry {
        let root = await store()
        return await Task.detached(priority: .userInitiated) {
            (try? ContentStore(root: root, create: false).guidRegistry()) ?? GuidRegistry()
        }.value
    }

    /// The catalogue with the registry's names over its own: a GUID the
    /// registry holds reads as every review names it.
    nonisolated static func catalogue(_ catalogue: GuidsCatalogue, overlaidBy registry: GuidRegistry) -> GuidsCatalogue {
        guard !registry.entries.isEmpty else { return catalogue }
        var names = catalogue.names
        for (key, entry) in registry.entries {
            if let guid = EFIGUID(key) { names[guid] = entry.name }
        }
        return GuidsCatalogue(names: names)
    }

    private func guids(_ arguments: AgentArguments) async throws -> JSONValue {
        let root = await store()
        let guid = try arguments.optionalString("guid")
        let search = try arguments.optionalString("search")?.lowercased()
        let kind = try arguments.optionalString("kind")
        let source = try arguments.optionalString("source")
        let limit = try arguments.limit(default: 200, maximum: 1000)
        if let kind, GuidKind(rawValue: kind) == nil {
            throw AgentToolError("`kind` is one of \(GuidKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return try await Task.detached(priority: .userInitiated) { () throws -> JSONValue in
            guard let store = try? ContentStore(root: root, create: false) else {
                return .object(["entries": .array([]), "total": .int(0)])
            }
            let registry = try store.guidRegistry()
            func json<T: Encodable>(_ value: T) throws -> JSONValue {
                try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
            }
            if let guid {
                guard let key = GuidName.canonicalGUID(guid) else {
                    throw AgentToolError("`guid` is 8-4-4-4-12 hex digits.")
                }
                guard let entry = registry.entries[key] else {
                    throw AgentToolError("The registry has no \(key): `guid_registry` without `guid` lists what it holds.")
                }
                var answer = try json(entry)
                if case .object(var object) = answer {
                    object["guid"] = .string(key)
                    answer = .object(object)
                }
                return answer
            }
            let matching = registry.entries
                .filter { key, entry in
                    (kind == nil || entry.kind.rawValue == kind)
                        && (source == nil || entry.source.kind.rawValue == source)
                        && (search == nil || entry.name.lowercased().contains(search!)
                            || key.lowercased().hasPrefix(search!))
                }
                .sorted { ($0.value.name, $0.key) < ($1.value.name, $1.key) }
            let rows: [JSONValue] = try matching.map { key, entry in
                .object(["guid": .string(key), "name": .string(entry.name), "kind": .string(entry.kind.rawValue),
                         "source": try json(entry.source), "version": .int(Int64(entry.version))])
            }
            let page = try AgentPage(arguments, fingerprint: AgentPage.fingerprint([search, kind, source, rows.count]),
                                     changed: "The registry changed since that page, or the question did; ask again without `after`.")
            return try page.answer(["total": .count(rows.count), "registry_total": .count(registry.entries.count)],
                                   key: "entries", items: Array(rows.dropFirst(page.first).prefix(limit)),
                                   total: rows.count, bound: arguments.answerBound)
        }.value
    }
}
