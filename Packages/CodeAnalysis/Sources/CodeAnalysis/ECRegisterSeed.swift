import ECImage
import Foundation

/// The register registry's first fill (`byteripper-cas registers-seed`): the
/// chip's register and interrupt tables (`Skills/ghidra-ec/reference/
/// it83xx-registers.tsv`, `it83xx-irqs.tsv`), already overlaid with what the
/// firmware showed. One entry per address: the first row at an address gives
/// the name, the others are its aliases. A table's `source` is the entry's
/// evidence text, its `status` is kept, and its `# replaced:` lines go into
/// the history as the names the overlay replaced (stamped from version 0 to
/// the seed's).
///
/// A seed only adds: an address the registry already holds is left as it is,
/// and listed when the table says something else. Without `apply` nothing is
/// written.
public enum ECRegisterSeed {
    public struct Difference: Codable, Equatable, Sendable {
        public var kind: ECRegisterKind
        public var key: String
        public var registry: String
        public var table: String
    }

    public struct Counts: Codable, Equatable, Sendable {
        public var added = 0
        public var same = 0
        public var differs = 0
        /// Rows folded into an entry as its aliases.
        public var aliases = 0
        /// `# replaced:` lines kept in the history.
        public var history = 0
    }

    public struct Report: Codable, Equatable, Sendable {
        public var chip: String
        public var versionBefore: Int
        public var versionAfter: Int
        public var registers: Counts
        public var irqs: Counts
        public var differences: [Difference]
        /// Names the tables give to more than one address, each with its keys.
        public var duplicateNames: [String: [String]]
        public var applied: Bool
    }

    struct Row {
        var key: String
        var name: String
        var width: Int?
        var block: String?
        var description: String?
        var source: String
        var status: ECRegisterStatus
    }

    static func status(_ text: String?) -> ECRegisterStatus {
        text.flatMap(ECRegisterStatus.init(rawValue:)) ?? .unverified
    }

    static func rows(_ map: ECRegisterMap) -> (current: [Row], replaced: [Row]) {
        func row(_ r: ECRegisterMap.Register) -> Row {
            Row(key: ECRegisterFile.key(.register, r.address), name: r.name, width: r.width,
                block: r.block.isEmpty ? nil : r.block, description: r.description, source: r.source,
                status: status(r.status))
        }
        return (map.registers.map(row), map.replaced.map(row))
    }

    static func rows(_ map: ECInterruptMap) -> (current: [Row], replaced: [Row]) {
        func row(_ e: ECInterruptMap.Entry) -> Row {
            Row(key: ECRegisterFile.key(.irq, UInt64(e.irq)), name: e.name, width: nil, block: nil,
                description: e.description, source: e.source, status: status(e.status))
        }
        return (map.entries.map(row), map.replaced.map(row))
    }

    /// Read both tables from `reference` and seed `chip`'s file.
    public static func run(store: ContentStore, chip: String, reference: URL, by: String = "seed",
                           apply: Bool, now: Date = Date()) throws -> Report {
        func text(_ name: String) throws -> String {
            let url = reference.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw CodeAnalysisError.io("\(url.path): cannot be read")
            }
            return text
        }
        let registers = try ECRegisterMap(tsv: try text("it83xx-registers.tsv"))
        let irqs = try ECInterruptMap(tsv: try text("it83xx-irqs.tsv"))
        return try run(store: store, chip: chip, registers: registers, irqs: irqs, by: by, apply: apply, now: now)
    }

    public static func run(store: ContentStore, chip: String, registers: ECRegisterMap, irqs: ECInterruptMap,
                           by: String = "seed", apply: Bool, now: Date = Date()) throws -> Report {
        let model = try ContentStore.registerChip(chip)
        let at = ISO8601DateFormatter().string(from: now)
        let registerRows = rows(registers)
        let irqRows = rows(irqs)
        // Every row is checked before anything is written.
        for row in registerRows.current + registerRows.replaced {
            guard ECRegisterName.isIdentifier(row.name) else {
                throw CodeAnalysisError.invalidName("\(row.name) at \(row.key) is no identifier")
            }
            guard let address = UInt64(row.key.dropFirst(2), radix: 16), model.window.contains(address) else {
                throw CodeAnalysisError.invalidName("\(row.name) at \(row.key) lies outside the register window")
            }
        }
        for row in irqRows.current + irqRows.replaced where !ECRegisterName.isIdentifier(row.name) {
            throw CodeAnalysisError.invalidName("\(row.name) at IRQ \(row.key) is no identifier")
        }
        return try store.withLock {
            var file = try store.registerFile(model.id)
            let before = file.version
            let next = before + 1
            var differences: [Difference] = []
            var duplicates: [String: [String]] = [:]

            func seed(_ kind: ECRegisterKind, _ rows: (current: [Row], replaced: [Row])) -> Counts {
                var counts = Counts()
                var order: [String] = []
                var grouped: [String: [Row]] = [:]
                for row in rows.current {
                    if grouped[row.key] == nil { order.append(row.key) }
                    grouped[row.key, default: []].append(row)
                }
                var keysByName: [String: Set<String>] = [:]
                for row in rows.current { keysByName[row.name, default: []].insert(row.key) }
                for (name, keys) in keysByName where keys.count > 1 {
                    duplicates[name] = keys.sorted()
                }
                for key in order {
                    let group = grouped[key]!
                    let first = group[0]
                    var aliases: [String] = []
                    for row in group.dropFirst() where row.name != first.name && !aliases.contains(row.name) {
                        aliases.append(row.name)
                    }
                    counts.aliases += aliases.count
                    let sources = group.map(\.source).filter { !$0.isEmpty }
                    let state = ECRegisterState(
                        name: first.name, aliases: aliases.isEmpty ? nil : aliases, width: first.width,
                        block: first.block, description: group.lazy.compactMap(\.description).first,
                        status: first.status,
                        evidence: sources.isEmpty ? nil : ECRegisterEvidence(text: sources.joined(separator: "; ")),
                        by: by, at: at, changedIn: next)
                    if let held = file.entries(kind)[key], held.removedIn == nil {
                        if held.current.names == state.names && held.current.description == state.description
                            && held.current.width == state.width && held.current.status == state.status {
                            counts.same += 1
                        } else {
                            counts.differs += 1
                            differences.append(Difference(kind: kind, key: key, registry: held.current.name,
                                                          table: state.name))
                        }
                        continue
                    }
                    let history: [ECRegisterState] = rows.replaced.filter { $0.key == key }.map { row in
                        ECRegisterState(name: row.name, width: row.width, block: row.block,
                                        description: row.description, status: row.status,
                                        evidence: row.source.isEmpty ? nil : ECRegisterEvidence(text: row.source),
                                        by: by, at: at, reason: "replaced by the \(model.id) overlay",
                                        changedIn: 0, replacedIn: next)
                    }
                    counts.history += history.count
                    counts.added += 1
                    ContentStore.set(ECRegisterEntry(current: state, history: history.isEmpty ? nil : history),
                                     kind: kind, key: key, in: &file)
                }
                return counts
            }

            let registerCounts = seed(.register, registerRows)
            let irqCounts = seed(.irq, irqRows)
            let changed = registerCounts.added + irqCounts.added > 0
            if changed { file.version = next }
            if apply, changed {
                try store.atomicWrite(try store.encoder.encode(file), to: store.registerFileURL(model.id))
            }
            return Report(chip: model.id, versionBefore: before, versionAfter: changed ? next : before,
                          registers: registerCounts, irqs: irqCounts,
                          differences: differences, duplicateNames: duplicates, applied: apply && changed)
        }
    }
}
