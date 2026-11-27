import AgentKit
import CodeAnalysis
import Foundation

extension CodeReadings {
    /// The shared registry of an EC chip's register and interrupt names
    /// (`ECRegisterFile`): its entries, or one entry with its history.
    public nonisolated var registerTool: AgentTool {
        AgentTool(
            name: "register_registry",
            title: "Read the EC register registry",
            description: """
                The shared registry of an EC chip model's register and interrupt names: one name for each \
                register address and each interrupt number, kept once for every review of that chip's \
                firmware. The file has a `version` that rises with every change; cite it as `stamp` \
                (`it8227e@12`). Each entry's `status` says how far its name is known: `published` (the \
                chip's published headers, confirmed for this model), `firmware` (shown by this model's \
                firmware: module and code addresses in `evidence`), `guess` (a review's reading, with its \
                evidence) or `unverified` (a related chip's published name, not checked for this model). \
                Without `address` or `irq`: the entries — `kind`, `key`, `name`, `aliases`, `width`, \
                `block`, `status`, `changed_in` — narrowed by `kind`, `search` (a part of a name, any case), \
                `status`, `block` and `since_version` (changed in that version or later), sorted by key, \
                paged by `limit` and `after`. With `address` or `irq`: that entry whole — its `current` \
                state with description, bits and evidence, and its `history`, each earlier state stamped \
                with the version it took effect in and the one it was replaced in.
                """,
            inputSchema: AgentSchema.object([
                "chip": AgentSchema.string("The chip model. Default \"it8227e\"."),
                "address": AgentSchema.string("A register's address in hex, \"0xF01C00\", for its entry."),
                "irq": AgentSchema.integer("An interrupt's number, for its entry."),
                "kind": AgentSchema.choice(ECRegisterKind.allCases.map(\.rawValue), "Only registers, or only interrupts."),
                "search": AgentSchema.string("Only entries with a name or alias that holds this text, any case."),
                "status": AgentSchema.choice(ECRegisterStatus.allCases.map(\.rawValue), "Only entries of this status."),
                "block": AgentSchema.string("Only registers of this block, \"SMB\"."),
                "since_version": AgentSchema.integer("Only entries changed in this version or later."),
                "limit": AgentSchema.limit(default: 200, maximum: 1000),
                "after": AgentSchema.string("The `next` of the page before.")
            ])
        ) { call in
            .json(try await self.registers(call.arguments))
        }
    }

    private func registers(_ arguments: AgentArguments) async throws -> JSONValue {
        let root = await store()
        let chip = try arguments.optionalString("chip") ?? ECRegisterChip.it8227e.id
        guard ECRegisterChip.named(chip) != nil else {
            throw AgentToolError("No register registry for chip \(chip): known are "
                                 + ECRegisterChip.all.map(\.id).joined(separator: ", ") + ".")
        }
        let address = try arguments.optionalString("address")
        let irq = arguments.has("irq") ? try arguments.integer("irq") : nil
        let kindText = try arguments.optionalString("kind")
        let search = try arguments.optionalString("search")?.lowercased()
        let statusText = try arguments.optionalString("status")
        let block = try arguments.optionalString("block")
        let since = arguments.has("since_version") ? Int(try arguments.integer("since_version")) : nil
        let limit = try arguments.limit(default: 200, maximum: 1000)
        if address != nil, irq != nil { throw AgentToolError("Name an `address` or an `irq`, not both.") }
        if let kindText, ECRegisterKind(rawValue: kindText) == nil {
            throw AgentToolError("`kind` is one of \(ECRegisterKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        if let statusText, ECRegisterStatus(rawValue: statusText) == nil {
            throw AgentToolError("`status` is one of \(ECRegisterStatus.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return try await Task.detached(priority: .userInitiated) { () throws -> JSONValue in
            let file = (try? ContentStore(root: root, create: false)).flatMap { try? $0.registerFile(chip) }
                ?? ECRegisterFile(chip: chip)
            func json<T: Encodable>(_ value: T) throws -> JSONValue {
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
            }
            let head: [String: JSONValue] = ["chip": .string(file.chip), "version": .int(Int64(file.version)),
                                             "stamp": .string(file.stamp)]
            if address != nil || irq != nil {
                let kind: ECRegisterKind = address != nil ? .register : .irq
                guard let key = address.map({ ECRegisterFile.key(.register, parsing: $0) })
                        ?? irq.flatMap({ $0 >= 0 ? ECRegisterFile.key(.irq, UInt64($0)) : nil }) else {
                    throw AgentToolError(address != nil ? "`address` is a hex address." : "`irq` is a number from 0.")
                }
                guard let entry = file.entries(kind)[key] else {
                    throw AgentToolError("The \(file.chip) registry has no \(kind.rawValue) \(key): "
                                         + "`register_registry` without `address` or `irq` lists what it holds.")
                }
                var object = head
                object["kind"] = .string(kind.rawValue)
                object["key"] = .string(key)
                if case .object(let fields) = try json(entry) {
                    object.merge(fields) { $1 }
                }
                return .object(object)
            }
            let kinds = kindText.flatMap(ECRegisterKind.init(rawValue:)).map { [$0] } ?? ECRegisterKind.allCases
            var rows: [JSONValue] = []
            for kind in kinds {
                let matching = file.standing(kind).filter { _, entry in
                    let state = entry.current
                    return (statusText == nil || state.status.rawValue == statusText)
                        && (block == nil || state.block?.caseInsensitiveCompare(block!) == .orderedSame)
                        && (since == nil || state.changedIn >= since!)
                        && (search == nil || state.names.contains { $0.lowercased().contains(search!) })
                }
                let sorted = matching.sorted { lhs, rhs in
                    kind == .irq ? (Int(lhs.key) ?? 0) < (Int(rhs.key) ?? 0) : lhs.key < rhs.key
                }
                for (key, entry) in sorted {
                    let state = entry.current
                    var row: [String: JSONValue] = ["kind": .string(kind.rawValue), "key": .string(key),
                                                    "name": .string(state.name), "status": .string(state.status.rawValue),
                                                    "changed_in": .int(Int64(state.changedIn))]
                    if let aliases = state.aliases { row["aliases"] = .array(aliases.map { .string($0) }) }
                    if let width = state.width { row["width"] = .int(Int64(width)) }
                    if let block = state.block { row["block"] = .string(block) }
                    rows.append(.object(row))
                }
            }
            let page = try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
                [chip, kindText, search, statusText, block, since.map(String.init), String(file.version)]),
                                     changed: "The registry changed since that page, or the question did; ask again without `after`.")
            var counts = head
            counts["total"] = .count(rows.count)
            return try page.answer(counts, key: "entries", items: Array(rows.dropFirst(page.first).prefix(limit)),
                                   total: rows.count, bound: arguments.answerBound)
        }.value
    }
}
