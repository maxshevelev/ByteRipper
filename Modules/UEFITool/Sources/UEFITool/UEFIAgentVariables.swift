import AgentKit
import Foundation
import ToolModuleKit
import UEFIImage

/// The NVRAM variables of an image for an agent, and two images' variables set
/// side by side (`Design/AGENT_PLAN.md`, stage 6).
///
/// A variable is what the firmware reads, not an entry of a store: the copy
/// that stands for it — the current one, or for a deleted variable the copy it
/// was deleted as (`NvramVariableHistory.variables`) — with the number of
/// copies the store keeps. Every store of VSS, VSS2, NVAR, Dell DVAR and GPNV
/// entries in the image is read, those inside compressed sections too, in the
/// tree's order.
///
/// Two images are compared by what a variable is, never by where it is: its
/// name and GUID, and — for a name and GUID the image keeps more than once, a
/// board's defaults beside its live store — which time it is met, in the
/// tree's order.
@MainActor
public enum UEFIAgentVariables {
    nonisolated public static var queries: [ToolAgentQuery] { [variables] }
    nonisolated public static var comparisons: [ToolAgentComparison] { [compare] }

    /// One variable, with the reader its bytes are in.
    struct Variable {
        var store: UEFINode
        var name: String
        var guid: EFIGUID?
        var entry: UEFINode
        var value: Range<UInt64>
        var attributes: UInt32
        var isDeleted: Bool
        var copies: Int
        var reader: ImageReader

        func bytes(limit: UInt64 = .max) -> [UInt8]? {
            guard UInt64(value.count) <= limit else { return nil }
            return reader.bytes(value)
        }

        /// What a variable is across images: its name and GUID, and which
        /// time the image meets that pair.
        struct Key: Hashable {
            var name: String
            var guid: String
            var occurrence: Int
        }
    }

    // MARK: - variables

    nonisolated static let variables = ToolAgentQuery(
        name: "variables",
        title: "NVRAM variables",
        description: """
            The NVRAM variables the image keeps, from every VSS, VSS2, NVAR, Dell DVAR and GPNV store — \
            those inside compressed sections too, so the first call on a large image takes a few seconds. \
            `stores` lists the stores the rows are in, with how many variables each holds. \
            One row per variable: the copy that stands for it now. `copies` above 1 says the store still \
            keeps earlier values (`uefi_node` on the entry lists them); `deleted: true` is a variable the \
            store no longer holds, listed only with `deleted`. Each row: name, GUID, the store's and the \
            entry's node ids, the value's bytes (`start`, `end`, `size`), and `value` — the value read as \
            its type (a number, text, a boot option, a device path, a signature list) or as hex when it \
            is short. Other stores (EVSA, Apple SysF, flash maps) are in `uefi_tree`. Pages: `limit` is \
            a ceiling — a page also stops before the answer passes the size bound and then says \
            `truncated: "size"`; pass `next` back as `after` until it is null. `total` counts every row. \
            A row too large alone comes without its `value`, marked `truncated: "item"`; `read` its bytes.
            """,
        properties: [
            "name": AgentSchema.string("Part of the variable's name, any case."),
            "guid": AgentSchema.string("The vendor GUID, exact."),
            "store": AgentSchema.string("Only this store's variables: its node id from an earlier answer."),
            "deleted": AgentSchema.boolean("Also list variables the store no longer holds. Default false."),
            "limit": AgentSchema.limit(default: 80, maximum: 300),
            "after": AgentSchema.after
        ]
    ) { host, arguments in
        let name = try arguments.optionalString("name")?.lowercased()
        let guid = try arguments.optionalString("guid")?.uppercased()
        let store = try arguments.optionalString("store").map(UEFIAgentQueries.nodeID)
        let deleted = try arguments.bool("deleted", default: false)
        let limit = try arguments.limit(default: 80, maximum: 300)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
            [host.contentVersion, name, guid, store?.description, deleted]))
        let tree = try await UEFIAgentQueries.readyTree(host)
        await UEFIAgentQueries.openEverything(in: tree)

        let all = variables(in: tree)
        let chosen = all.filter { variable in
            if !deleted, variable.isDeleted { return false }
            if let name, !variable.name.lowercased().contains(name) { return false }
            if let guid, variable.guid?.description.uppercased() != guid { return false }
            if let store, variable.store.id != store { return false }
            return true
        }
        // The stores the rows are in, each with all it holds: of every row
        // that may go on the page while the page is cut to fit, then of the
        // rows that did — fewer, so the answer only gets shorter.
        @MainActor func stores(_ rows: ArraySlice<Variable>) -> JSONValue {
            var stores: [NodeID: UEFINode] = [:]
            for variable in rows { stores[variable.store.id] = variable.store }
            return .array(stores.values.sorted { $0.id.path.lexicographicallyPrecedes($1.id.path) }.map { store in
                .object(storeSummary(store, variables: all.filter { $0.store.id == store.id }.count))
            })
        }
        let candidates = chosen.dropFirst(paging.first).prefix(limit)
        var envelope: [String: JSONValue] = ["total": .count(chosen.count), "stores": stores(candidates)]
        if all.isEmpty {
            envelope["note"] = "No VSS, NVAR, DVAR or GPNV store in this image."
        }
        var answer = try paging.answer(envelope, key: "variables", items: candidates.map { row($0) },
                                       total: chosen.count, bound: arguments.answerBound) { item in
            guard case .object(var members) = item, members["value"] != nil else { return nil }
            members["value"] = nil
            members["truncated"] = "item"
            return .object(members)
        }
        if case .object(var members) = answer {
            members["stores"] = stores(candidates.prefix(answer["variables"]?.arrayValue?.count ?? 0))
            answer = .object(members)
        }
        return .json(answer)
    }

    // MARK: - variables_compare

    nonisolated static let compare = ToolAgentComparison(
        name: "variables_compare",
        title: "Compare NVRAM variables",
        description: """
            Sets the NVRAM variables of two documents side by side — `document` and `against` — by name \
            and GUID, not by address, so two dumps of different boards or BIOS versions compare as well \
            as two of one board. A name and GUID kept twice in an image (live and default stores) is \
            paired by which time it is met. Answers the variables only in one of them, those whose values \
            differ — with both sizes, the bytes that differ as offsets into the value, and both values \
            read as their type — and how many are the same. Variables a store no longer holds are left \
            out. `survey` with this tool and a fixed `against` compares a folder of dumps with one. \
            Pages: the three lists are one sequence — `changed`, then `only_in_document`, then \
            `only_in_against` — and `limit` is the most items of it on one page, a ceiling: a page also \
            stops before the answer passes the size bound and then says `truncated: "size"`. Pass `next` \
            back as `after` until it is null; `counts` and `same` are of the whole comparison. A changed \
            variable too large alone comes without its values, marked `truncated: "item"`.
            """,
        properties: [
            "name": AgentSchema.string("Only variables whose name contains this, any case."),
            "limit": AgentSchema.limit(default: 40, maximum: 200),
            "after": AgentSchema.after
        ]
    ) { host, otherHost, arguments in
        let name = try arguments.optionalString("name")?.lowercased()
        let limit = try arguments.limit(default: 40, maximum: 200)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
            [host.contentVersion, otherHost.contentVersion, name]))
        let tree = try await UEFIAgentQueries.readyTree(host)
        let otherTree = try await UEFIAgentQueries.readyTree(otherHost)
        await UEFIAgentQueries.openEverything(in: tree)
        await UEFIAgentQueries.openEverything(in: otherTree)

        func keyed(_ list: [Variable]) -> [(Variable.Key, Variable)] {
            var seen: [String: Int] = [:]
            return list.filter { !$0.isDeleted && (name.map($0.name.lowercased().contains) ?? true) }.map { variable in
                let guid = variable.guid?.description ?? ""
                let pair = variable.name + "\u{0}" + guid
                let occurrence = seen[pair, default: 0]
                seen[pair] = occurrence + 1
                return (Variable.Key(name: variable.name, guid: guid, occurrence: occurrence), variable)
            }
        }
        let mine = keyed(variables(in: tree))
        let theirs = keyed(variables(in: otherTree))
        let theirsByKey = Dictionary(theirs.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        let mineKeys = Set(mine.map(\.0))

        var onlyHere: [Variable] = []
        var changed: [(Variable, [UInt8], Variable, [UInt8])] = []
        var same = 0
        for (key, variable) in mine {
            guard let other = theirsByKey[key] else {
                onlyHere.append(variable)
                continue
            }
            let a = variable.bytes() ?? []
            let b = other.bytes() ?? []
            if a == b {
                same += 1
                continue
            }
            changed.append((variable, a, other, b))
        }
        let onlyThere = theirs.filter { !mineKeys.contains($0.0) }.map(\.1)

        // The page's items, built only for the stretch of the sequence it
        // may hold.
        let total = changed.count + onlyHere.count + onlyThere.count
        var items: [(key: String, item: JSONValue)] = []
        for index in paging.first..<max(paging.first, min(total, paging.first + limit)) {
            if index < changed.count {
                let (variable, a, other, b) = changed[index]
                items.append(("changed", difference(variable, a, other, b)))
            } else if index < changed.count + onlyHere.count {
                items.append(("only_in_document", brief(onlyHere[index - changed.count])))
            } else {
                items.append(("only_in_against", brief(onlyThere[index - changed.count - onlyHere.count])))
            }
        }

        let envelope: [String: JSONValue] = [
            "same": .count(same),
            "counts": ["only_in_document": .count(onlyHere.count), "only_in_against": .count(onlyThere.count),
                       "changed": .count(changed.count)]
        ]
        return .json(try paging.answer(envelope, keys: ["changed", "only_in_document", "only_in_against"],
                                       items: items, total: total, bound: arguments.answerBound) { item in
            guard case .object(var members) = item,
                  members["value"] != nil || members["against_value"] != nil else { return nil }
            members["value"] = nil
            members["against_value"] = nil
            members["truncated"] = "item"
            return .object(members)
        })
    }

    // MARK: - Reading

    /// Every variable of every store in the tree as it is open now, in tree
    /// order.
    static func variables(in tree: LazyUEFITree) -> [Variable] {
        let readers = tree.spaceReaders
        var result: [Variable] = []
        for store in tree.image().allNodes where store.children.contains(where: isEntry) {
            guard let reader = readers.reader(for: store.space) else { continue }
            let entries = Dictionary(store.children.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for variable in NvramVariableHistory.variables(in: store, reader: reader) {
                guard let entry = entries[variable.entry] else { continue }
                result.append(Variable(
                    store: store, name: variable.name, guid: variable.guid, entry: entry,
                    value: variable.value, attributes: attributes(of: entry, in: store, reader: reader),
                    isDeleted: variable.state == .deleted, copies: variable.copies, reader: reader))
            }
        }
        return result
    }

    private static func isEntry(_ node: UEFINode) -> Bool {
        node.kind == .vssEntry || node.kind == .nvarEntry || node.kind == .dvarEntry || node.kind == .gpnvRecord
    }

    /// The attributes in VSS bits, which is what `NvramValue` reads a value
    /// by: a VSS entry's own, an NVAR entry's hardware error record flag, and
    /// none for the formats that keep none.
    private static func attributes(of entry: UEFINode, in store: UEFINode, reader: ImageReader) -> UInt32 {
        switch entry.kind {
        case .vssEntry:
            return VSSVariable.read(entry, inVss2: store.kind == .vss2Store, reader: reader)?.attributes ?? 0
        case .nvarEntry:
            return UEFITreeDisplay.nvarAttributes(entry, reader: reader)
        default:
            return 0
        }
    }

    // MARK: - Shapes

    /// The longest value read as its type; past it, only the size.
    static let valueReadLimit: UInt64 = 0x10000
    /// The longest value spelled out as hex when it reads as nothing else.
    static let hexLimit = 32

    /// The value read as its type, or as hex when it is short.
    static func valueText(_ variable: Variable, _ bytes: [UInt8]?) -> String? {
        guard let bytes else { return nil }
        let value = NvramValue.read(name: variable.name, guid: variable.guid,
                                    attributes: variable.attributes, value: bytes)
        if let text = NvramValueText.short(value) { return text }
        guard value.content == .bytes, bytes.count <= hexLimit else { return nil }
        return NvramValueText.hexBytes(bytes)
    }

    private static func row(_ variable: Variable) -> JSONValue {
        var entry = brief(variable)
        if case .object(var members) = entry {
            members["store"] = .string(variable.store.id.description)
            members["entry"] = .string(variable.entry.id.description)
            if variable.copies > 1 { members["copies"] = .count(variable.copies) }
            if variable.isDeleted { members["deleted"] = true }
            if let range = rangeInFile(variable) {
                members["start"] = .string(UEFIAgentQueries.hex(range.lowerBound))
                members["end"] = .string(UEFIAgentQueries.hex(range.upperBound))
            } else {
                members["in_compressed"] = true
            }
            entry = .object(members)
        }
        return entry
    }

    private static func brief(_ variable: Variable) -> JSONValue {
        var members: [String: JSONValue] = [
            "name": .string(variable.name),
            "size": .count(variable.value.count)
        ]
        if let guid = variable.guid { members["guid"] = .string(guid.description) }
        if let text = valueText(variable, variable.bytes(limit: valueReadLimit)) { members["value"] = .string(text) }
        return .object(members)
    }

    /// Where the value's bytes are in the file: nil inside a decompressed
    /// section, which has no file address.
    private static func rangeInFile(_ variable: Variable) -> Range<UInt64>? {
        variable.entry.space == .file ? variable.value : nil
    }

    private static func storeSummary(_ store: UEFINode, variables: Int) -> [String: JSONValue] {
        let type = UEFITreeDisplay.typeText(for: store)
        var members: [String: JSONValue] = [
            "id": .string(store.id.description),
            "type": .string(type),
            "variables": .count(variables)
        ]
        let name = UEFITreeDisplay.ownName(of: store) ?? store.name
        if name != type { members["name"] = .string(name) }
        if let range = store.fileRange {
            members["start"] = .string(UEFIAgentQueries.hex(range.lowerBound))
            members["end"] = .string(UEFIAgentQueries.hex(range.upperBound))
        }
        return members
    }

    /// The most runs of differing bytes one changed variable lists.
    static let runLimit = 16

    private static func difference(_ mine: Variable, _ a: [UInt8], _ theirs: Variable, _ b: [UInt8]) -> JSONValue {
        let runs = differingRuns(a, b)
        var members: [String: JSONValue] = [
            "name": .string(mine.name),
            "size": .count(a.count),
            "against_size": .count(b.count),
            "differing_bytes": .count(runs.reduce(0) { $0 + $1.count }),
            "runs": .array(runs.prefix(runLimit).map { run in
                .string(run.count == 1 ? UEFIAgentQueries.hex(UInt64(run.lowerBound))
                        : "\(UEFIAgentQueries.hex(UInt64(run.lowerBound)))–\(UEFIAgentQueries.hex(UInt64(run.upperBound)))")
            }),
            "entry": .string(mine.entry.id.description),
            "against_entry": .string(theirs.entry.id.description)
        ]
        if let guid = mine.guid { members["guid"] = .string(guid.description) }
        if runs.count > runLimit { members["runs_total"] = .count(runs.count) }
        if let text = valueText(mine, a.count <= valueReadLimit ? a : nil) { members["value"] = .string(text) }
        if let text = valueText(theirs, b.count <= valueReadLimit ? b : nil) { members["against_value"] = .string(text) }
        return .object(members)
    }

    /// The runs of offsets at which `a` and `b` differ, as half-open ranges
    /// into the value — over the length both have, then the tail only the
    /// longer one has as one run.
    nonisolated static func differingRuns(_ a: [UInt8], _ b: [UInt8]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        let common = min(a.count, b.count)
        for index in 0..<common {
            if a[index] != b[index] {
                if start == nil { start = index }
            } else if let open = start {
                runs.append(open..<index)
                start = nil
            }
        }
        if let open = start { runs.append(open..<common) }
        if a.count != b.count {
            let tail = common..<max(a.count, b.count)
            if let last = runs.last, last.upperBound == common {
                runs[runs.count - 1] = last.lowerBound..<tail.upperBound
            } else {
                runs.append(tail)
            }
        }
        return runs
    }
}
