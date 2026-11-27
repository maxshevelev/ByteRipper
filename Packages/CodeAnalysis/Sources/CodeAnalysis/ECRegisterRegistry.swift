import ECImage
import Foundation

// The shared registry of an EC chip's registers and interrupts: one name for
// each register address and each interrupt number, kept once for every review
// of that chip's firmware, so two reviews cannot call one register two things.
//
// One file per chip model, `registers/<chip>.json`, registers and interrupts
// together. The file carries a `version` that rises by one with every change,
// and each entry keeps its `current` state, stamped with the version it took
// effect in (`changedIn`), and its `history`: every earlier state, stamped
// with the version it was replaced in. So the map as it stood at any version
// can be rebuilt — a review that cites `it8227e@12` reads the names it used.
//
// The rule an offer meets (`ECRegisterOfferResult.Outcome`):
// - an address the registry does not hold is added;
// - the same name and nothing new is no change;
// - the same name with a description, bits, block or width the entry lacked
//   is refined; with a stronger status (guess → firmware) it is confirmed;
// - a name with evidence replaces an `unverified` name at once, and a
//   firmware name replaces a guess; the old name stays in the history;
// - anything else that differs from a `firmware` or `published` entry is a
//   conflict, answered with the entry as it stands — a guard against an
//   accidental overwrite. Any writer may replace it on purpose: `replace`
//   with a reason, which the history keeps.
// A guess gives its evidence; a firmware name gives the module and the code
// addresses that show it. Only the server and `byteripper-cas` write the file.

/// Whether an entry is a register, by address, or an interrupt, by number.
public enum ECRegisterKind: String, Codable, CaseIterable, Sendable {
    case register
    case irq
}

/// How far an entry's name is known.
public enum ECRegisterStatus: String, Codable, CaseIterable, Sendable {
    /// Published for the chip (Chromium EC's `registers.h`, a datasheet), confirmed for this model.
    case published
    /// Shown by this model's firmware: the module and the code that use it.
    case firmware
    /// A review's reading of the code, with its evidence, not yet shown.
    case guess
    /// A published name for a related chip, not checked for this model.
    case unverified

    /// How strong a name of this status is: a stronger one may confirm a weaker.
    public var rank: Int {
        switch self {
        case .unverified: return 0
        case .guess: return 1
        case .firmware: return 2
        case .published: return 3
        }
    }
}

/// A field of a register: bits `lsb ..< lsb + width`.
public struct ECRegisterBit: Codable, Equatable, Sendable {
    public var lsb: Int
    public var width: Int
    public var name: String
    public var meaning: String?

    public init(lsb: Int, width: Int = 1, name: String, meaning: String? = nil) {
        self.lsb = lsb
        self.width = width
        self.name = name
        self.meaning = meaning
    }
}

/// What shows a name: the module and the code addresses in it, or a text — a
/// published source's line, a table's derivation.
public struct ECRegisterEvidence: Codable, Equatable, Sendable {
    public var module: SHA256Digest?
    public var addresses: [String]?
    public var text: String?

    public init(module: SHA256Digest? = nil, addresses: [String]? = nil, text: String? = nil) {
        self.module = module
        self.addresses = addresses
        self.text = text
    }

    var isEmpty: Bool {
        module == nil && (addresses ?? []).isEmpty && (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// One state of an entry: the current one, or one the history keeps.
public struct ECRegisterState: Codable, Equatable, Sendable {
    public var name: String
    /// Further published names at the same address.
    public var aliases: [String]?
    /// In bytes, 1, 2 or 4; nil for an interrupt.
    public var width: Int?
    public var block: String?
    public var description: String?
    public var bits: [ECRegisterBit]?
    public var status: ECRegisterStatus
    public var evidence: ECRegisterEvidence?
    public var by: String?
    public var at: String
    /// Why a replacement gave this state over the one before; nil for any other.
    public var reason: String?
    /// The file version this state took effect in.
    public var changedIn: Int
    /// For a state the history keeps: the version it was replaced in.
    public var replacedIn: Int?

    public init(name: String, aliases: [String]? = nil, width: Int? = nil, block: String? = nil,
                description: String? = nil, bits: [ECRegisterBit]? = nil, status: ECRegisterStatus,
                evidence: ECRegisterEvidence? = nil, by: String? = nil, at: String, reason: String? = nil,
                changedIn: Int, replacedIn: Int? = nil) {
        self.name = name
        self.aliases = aliases
        self.width = width
        self.block = block
        self.description = description
        self.bits = bits
        self.status = status
        self.evidence = evidence
        self.by = by
        self.at = at
        self.reason = reason
        self.changedIn = changedIn
        self.replacedIn = replacedIn
    }

    /// The name and the aliases.
    public var names: [String] { [name] + (aliases ?? []) }

    /// Whether the state stood at `version`.
    func stood(at version: Int) -> Bool {
        changedIn <= version && (replacedIn.map { version < $0 } ?? true)
    }
}

/// A register's or an interrupt's entry: its current state and every one before it.
public struct ECRegisterEntry: Codable, Equatable, Sendable {
    public var current: ECRegisterState
    /// The states before the current one, oldest first.
    public var history: [ECRegisterState]?
    /// The version an operator removed the entry in; nil while it stands.
    public var removedIn: Int?

    public init(current: ECRegisterState, history: [ECRegisterState]? = nil, removedIn: Int? = nil) {
        self.current = current
        self.history = history
        self.removedIn = removedIn
    }

    /// The state that stood at `version`; nil before the entry was added or after it was removed.
    public func state(at version: Int) -> ECRegisterState? {
        if let removedIn, version >= removedIn { return nil }
        if current.stood(at: version) { return current }
        return (history ?? []).last { $0.stood(at: version) }
    }

    /// Every name the entry has had, current first, then the history's newest first.
    public var everNames: [String] {
        var seen: [String] = []
        for state in [current] + (history ?? []).reversed() {
            for name in state.names where !seen.contains(name) { seen.append(name) }
        }
        return seen
    }
}

/// A chip model the registry keeps a file for.
public struct ECRegisterChip: Equatable, Sendable {
    public let id: String
    public let family: ECChipFamily

    /// Where the chip's registers lie.
    public var window: Range<UInt64> { family.registers }

    public static let it8227e = ECRegisterChip(id: "it8227e", family: .iteNDS32)
    public static let all: [ECRegisterChip] = [.it8227e]

    public static func named(_ id: String) -> ECRegisterChip? {
        all.first { $0.id == id.lowercased() }
    }
}

/// One chip's file.
public struct ECRegisterFile: Codable, Equatable, Sendable {
    public var schema: Int
    public var chip: String
    /// Rises by one with every change.
    public var version: Int
    /// By address, `0x00F01C00`.
    public var registers: [String: ECRegisterEntry]
    /// By number, `160`.
    public var irqs: [String: ECRegisterEntry]

    public static let currentSchema = 1

    public init(chip: String, version: Int = 0, registers: [String: ECRegisterEntry] = [:],
                irqs: [String: ECRegisterEntry] = [:]) {
        self.schema = Self.currentSchema
        self.chip = chip
        self.version = version
        self.registers = registers
        self.irqs = irqs
    }

    /// `it8227e@12`: what a review cites for the map it read.
    public var stamp: String { "\(chip)@\(version)" }

    public func entries(_ kind: ECRegisterKind) -> [String: ECRegisterEntry] {
        kind == .register ? registers : irqs
    }

    /// The entries that stand now.
    public func standing(_ kind: ECRegisterKind) -> [String: ECRegisterEntry] {
        entries(kind).filter { $0.value.removedIn == nil }
    }

    public func entry(_ kind: ECRegisterKind, _ key: String) -> ECRegisterEntry? {
        entries(kind)[key]
    }

    /// The state of one entry at `version`.
    public func state(_ kind: ECRegisterKind, _ key: String, at version: Int) -> ECRegisterState? {
        entries(kind)[key]?.state(at: version)
    }

    /// The whole map as it stood at `version`.
    public func map(_ kind: ECRegisterKind, at version: Int) -> [String: ECRegisterState] {
        entries(kind).compactMapValues { $0.state(at: version) }
    }

    /// The keys that have ever carried `name`, as a name or an alias.
    public func everName(_ name: String, kind: ECRegisterKind) -> [String] {
        entries(kind).filter { $0.value.everNames.contains(name) }.keys.sorted()
    }

    /// The key of a register's address, `0x00F01C00`, or an interrupt's number.
    public static func key(_ kind: ECRegisterKind, _ value: UInt64) -> String {
        kind == .register ? String(format: "0x%08llX", value) : String(value)
    }

    /// A key written another way — `0xf01c00`, `F01C00h`, `160` — in the file's form.
    public static func key(_ kind: ECRegisterKind, parsing text: String) -> String? {
        var body = text.trimmingCharacters(in: .whitespaces)
        if kind == .irq { return UInt64(body).map { key(.irq, $0) } }
        if body.lowercased().hasPrefix("0x") { body.removeFirst(2) }
        if body.lowercased().hasSuffix("h") { body.removeLast() }
        return UInt64(body, radix: 16).map { key(.register, $0) }
    }
}

/// A count of one chip's file, as the served list gives it.
public struct ECRegisterChipSummary: Codable, Equatable, Sendable {
    public var chip: String
    public var version: Int
    public var registers: Int
    public var irqs: Int

    public init(chip: String, version: Int, registers: Int, irqs: Int) {
        self.chip = chip
        self.version = version
        self.registers = registers
        self.irqs = irqs
    }
}

/// An offer for one entry.
public struct ECRegisterOffer: Codable, Equatable, Sendable {
    public var kind: ECRegisterKind
    /// The register's address, or the interrupt's number.
    public var number: UInt64
    public var name: String
    public var aliases: [String]?
    public var width: Int?
    public var block: String?
    public var description: String?
    public var bits: [ECRegisterBit]?
    public var status: ECRegisterStatus
    public var evidence: ECRegisterEvidence?

    public init(kind: ECRegisterKind, number: UInt64, name: String, aliases: [String]? = nil, width: Int? = nil,
                block: String? = nil, description: String? = nil, bits: [ECRegisterBit]? = nil,
                status: ECRegisterStatus, evidence: ECRegisterEvidence? = nil) {
        self.kind = kind
        self.number = number
        self.name = name
        self.aliases = aliases
        self.width = width
        self.block = block
        self.description = description
        self.bits = bits
        self.status = status
        self.evidence = evidence
    }

    public var key: String { ECRegisterFile.key(kind, number) }
}

/// What an offer did, or would do.
public struct ECRegisterOfferResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The registry did not hold the address: it does now.
        case added
        /// The same name and nothing new: nothing changed.
        case same
        /// The same name with what the entry lacked, or a weak entry's details corrected.
        case refined
        /// The same name with a stronger status — a guess shown by the firmware.
        case confirmed
        /// Another name over an unverified one or a guess, or a deliberate replacement with a reason.
        case replaced
        /// Another name or other details than a firmware or published entry's, without `replace`: refused.
        case conflict
    }

    public var kind: ECRegisterKind
    public var key: String
    public var outcome: Outcome
    /// The entry as it stands after the offer — the registry's own on a conflict.
    public var entry: ECRegisterEntry
    /// The file's version after the offer.
    public var version: Int
    /// For a conflict: what was offered, and why it is refused.
    public var offered: String?
    public var why: String?
}

/// What a removal took away.
public struct ECRegisterRemoval: Codable, Equatable, Sendable {
    public var kind: ECRegisterKind
    public var key: String
    public var entry: ECRegisterEntry
    public var reason: String
    public var applied: Bool
    public var version: Int
}

/// The spelling rules of the registry's names.
public enum ECRegisterName {
    /// A C identifier: a letter or `_`, then letters, digits and `_`.
    public static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

extension ContentStore {
    public var registersURL: URL { root.appendingPathComponent("registers", isDirectory: true) }

    func registerFileURL(_ chip: String) -> URL {
        registersURL.appendingPathComponent("\(chip).json", isDirectory: false)
    }

    /// The chips whose file the store holds.
    public func registerChips() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: registersURL.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
            .filter { ECRegisterChip.named($0) != nil }.sorted()
    }

    /// Each file's version and counts.
    public func registerSummaries() throws -> [ECRegisterChipSummary] {
        try registerChips().map { chip in
            let file = try registerFile(chip)
            return ECRegisterChipSummary(chip: chip, version: file.version, registers: file.standing(.register).count,
                                         irqs: file.standing(.irq).count)
        }
    }

    /// A chip's file; empty at version 0 while it was never seeded.
    public func registerFile(_ chip: String) throws -> ECRegisterFile {
        let model = try Self.registerChip(chip)
        let url = registerFileURL(model.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return ECRegisterFile(chip: model.id) }
        do {
            return try decoder.decode(ECRegisterFile.self, from: Data(contentsOf: url))
        } catch {
            throw CodeAnalysisError.io("\(url.path): \(error)")
        }
    }

    /// A chip's file as the server holds it, written into a mirror.
    public func mirrorRegisters(_ file: ECRegisterFile) throws {
        let model = try Self.registerChip(file.chip)
        let url = registerFileURL(model.id)
        try withLock {
            let data = try encoder.encode(file)
            if (try? Data(contentsOf: url)) != data {
                try atomicWrite(data, to: url)
            }
        }
    }

    static func registerChip(_ chip: String) throws -> ECRegisterChip {
        guard let model = ECRegisterChip.named(chip) else {
            throw CodeAnalysisError.invalidName(
                "no register registry for chip \(chip): known are \(ECRegisterChip.all.map(\.id).joined(separator: ", "))")
        }
        return model
    }

    /// Offer one entry (the rule at the head of this file). `replace` with
    /// a `reason` puts a name or details over a firmware or published
    /// entry's on purpose. `dryRun`
    /// answers and writes nothing.
    public func offerRegister(chip: String, _ offer: ECRegisterOffer, by: String?,
                              replace: Bool = false, reason: String? = nil, dryRun: Bool = false,
                              now: Date = Date()) throws -> ECRegisterOfferResult {
        let model = try Self.registerChip(chip)
        try Self.validate(offer, chip: model)
        if replace {
            guard !(reason ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CodeAnalysisError.invalidName("a replacement gives its reason")
            }
        }
        let at = ISO8601DateFormatter().string(from: now)
        return try withLock {
            var file = try registerFile(model.id)
            try Self.checkNameFree(offer, in: file)
            let result = Self.apply(offer, to: &file, by: by, replace: replace, reason: reason, at: at)
            if !dryRun, result.outcome != .conflict, result.outcome != .same {
                try atomicWrite(try encoder.encode(file), to: registerFileURL(model.id))
            }
            return result
        }
    }

    /// Remove a wrong entry, with a reason (an operator's, `register-remove`). The entry keeps
    /// its history and is marked removed, so the map at an earlier version
    /// still holds it; an offer at its address later starts it again.
    public func removeRegister(chip: String, kind: ECRegisterKind, key keyText: String, reason: String,
                               expectName: String? = nil, dryRun: Bool = false) throws -> ECRegisterRemoval {
        let model = try Self.registerChip(chip)
        guard !reason.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CodeAnalysisError.invalidName("a removal gives its reason")
        }
        guard let key = ECRegisterFile.key(kind, parsing: keyText) else {
            throw CodeAnalysisError.invalidName("\(keyText) is no \(kind == .register ? "address" : "interrupt number")")
        }
        return try withLock {
            var file = try registerFile(model.id)
            guard var entry = file.entries(kind)[key], entry.removedIn == nil else {
                throw CodeAnalysisError.invalidName("the \(model.id) registry has no \(kind.rawValue) \(key)")
            }
            if let expectName, entry.current.name != expectName {
                throw CodeAnalysisError.analysisMismatch(
                    "the registry names \(key) \(entry.current.name), not \(expectName): nothing removed")
            }
            let removed = entry
            if !dryRun {
                file.version += 1
                entry.removedIn = file.version
                entry.current.replacedIn = file.version
                Self.set(entry, kind: kind, key: key, in: &file)
                try atomicWrite(try encoder.encode(file), to: registerFileURL(model.id))
            }
            return ECRegisterRemoval(kind: kind, key: key, entry: removed, reason: reason, applied: !dryRun,
                                     version: file.version)
        }
    }

    // MARK: - The rule

    static func validate(_ offer: ECRegisterOffer, chip: ECRegisterChip) throws {
        for name in [offer.name] + (offer.aliases ?? []) where !ECRegisterName.isIdentifier(name) {
            throw CodeAnalysisError.invalidName("\(name) is no identifier: a letter or `_`, then letters, digits, `_`")
        }
        switch offer.kind {
        case .register:
            guard chip.window.contains(offer.number) else {
                throw CodeAnalysisError.invalidName(String(
                    format: "0x%llX lies outside the %@ register window 0x%llX..<0x%llX", offer.number, chip.id,
                    chip.window.lowerBound, chip.window.upperBound))
            }
            guard let width = offer.width, [1, 2, 4].contains(width) else {
                throw CodeAnalysisError.invalidName("a register's width is 1, 2 or 4 bytes, not \(offer.width.map(String.init) ?? "none")")
            }
            var taken = 0 as UInt64
            for bit in offer.bits ?? [] {
                guard ECRegisterName.isIdentifier(bit.name) else {
                    throw CodeAnalysisError.invalidName("bit field \(bit.name) is no identifier")
                }
                guard bit.lsb >= 0, bit.width >= 1, bit.lsb + bit.width <= width * 8 else {
                    throw CodeAnalysisError.invalidName(
                        "bit field \(bit.name) (\(bit.lsb), width \(bit.width)) does not fit a \(width)-byte register")
                }
                let mask = (bit.width >= 64 ? UInt64.max : (1 << UInt64(bit.width)) - 1) << UInt64(bit.lsb)
                guard taken & mask == 0 else {
                    throw CodeAnalysisError.invalidName("bit field \(bit.name) overlaps another")
                }
                taken |= mask
            }
        case .irq:
            guard offer.width == nil, offer.bits == nil else {
                throw CodeAnalysisError.invalidName("an interrupt has no width and no bits")
            }
        }
        let evidence = offer.evidence ?? ECRegisterEvidence()
        switch offer.status {
        case .guess:
            guard !evidence.isEmpty else {
                throw CodeAnalysisError.invalidName("a guess gives its evidence: the module and the code, or a text")
            }
        case .firmware:
            guard evidence.module != nil, !(evidence.addresses ?? []).isEmpty else {
                throw CodeAnalysisError.invalidName(
                    "a firmware name gives the module and the code addresses that show it")
            }
        case .published:
            guard !(evidence.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CodeAnalysisError.invalidName("a published name cites where it is published (`evidence.text`)")
            }
        case .unverified:
            break
        }
    }

    /// A name belongs to one address: refused when another standing entry
    /// carries it, unless that entry's name is itself unverified.
    static func checkNameFree(_ offer: ECRegisterOffer, in file: ECRegisterFile) throws {
        let key = offer.key
        for name in [offer.name] + (offer.aliases ?? []) {
            for (other, entry) in file.standing(offer.kind) where other != key && entry.current.status != .unverified {
                if entry.current.names.contains(name) {
                    throw CodeAnalysisError.invalidName("\(name) is already the name of \(offer.kind.rawValue) \(other)")
                }
            }
        }
    }

    static func set(_ entry: ECRegisterEntry, kind: ECRegisterKind, key: String, in file: inout ECRegisterFile) {
        switch kind {
        case .register: file.registers[key] = entry
        case .irq: file.irqs[key] = entry
        }
    }

    static func apply(_ offer: ECRegisterOffer, to file: inout ECRegisterFile, by: String?, replace: Bool,
                      reason: String?, at: String) -> ECRegisterOfferResult {
        let key = offer.key
        let next = file.version + 1
        func fresh(reason: String?) -> ECRegisterState {
            ECRegisterState(name: offer.name, aliases: offer.aliases, width: offer.width, block: offer.block,
                            description: offer.description, bits: offer.bits, status: offer.status,
                            evidence: offer.evidence, by: by, at: at, reason: reason, changedIn: next)
        }
        func result(_ outcome: ECRegisterOfferResult.Outcome, _ entry: ECRegisterEntry,
                    why: String? = nil) -> ECRegisterOfferResult {
            ECRegisterOfferResult(kind: offer.kind, key: key, outcome: outcome, entry: entry, version: file.version,
                                  offered: outcome == .conflict ? offer.name : nil, why: why)
        }
        /// `state` becomes the current one, the old one goes to the history.
        func commit(_ entry: ECRegisterEntry, _ state: ECRegisterState, _ outcome: ECRegisterOfferResult.Outcome)
            -> ECRegisterOfferResult {
            var entry = entry
            var old = entry.current
            old.replacedIn = next
            entry.history = (entry.history ?? []) + [old]
            entry.current = state
            entry.removedIn = nil
            file.version = next
            set(entry, kind: offer.kind, key: key, in: &file)
            return result(outcome, entry)
        }

        guard let entry = file.entries(offer.kind)[key] else {
            let entry = ECRegisterEntry(current: fresh(reason: nil))
            file.version = next
            set(entry, kind: offer.kind, key: key, in: &file)
            return result(.added, entry)
        }
        if entry.removedIn != nil {
            return commit(entry, fresh(reason: nil), .added)
        }
        let held = entry.current
        let weak = held.status == .unverified || held.status == .guess

        if !held.names.contains(offer.name) {
            var state = fresh(reason: replace ? reason : nil)
            state.width = offer.width ?? held.width
            state.block = offer.block ?? held.block
            if replace { return commit(entry, state, .replaced) }
            if held.status == .unverified && offer.status.rank >= ECRegisterStatus.guess.rank
                || held.status == .guess && offer.status.rank >= ECRegisterStatus.firmware.rank {
                return commit(entry, state, .replaced)
            }
            let why = weak
                ? "the registry names it \(held.name) (\(held.status.rawValue)); another name takes a stronger status"
                : "the registry names it \(held.name) (\(held.status.rawValue)); another name is a replacement: `replace` with a reason"
            return result(.conflict, entry, why: why)
        }

        // The same name, or one of its aliases.
        func differs<T: Equatable>(_ offered: T?, _ kept: T?) -> Bool {
            offered != nil && kept != nil && offered != kept
        }
        func adds<T>(_ offered: T?, _ kept: T?) -> Bool { offered != nil && kept == nil }
        let differing = [
            differs(offer.width, held.width) ? "width" : nil,
            differs(offer.block, held.block) ? "block" : nil,
            differs(offer.description, held.description) ? "description" : nil,
            differs(offer.bits, held.bits) ? "bits" : nil
        ].compactMap { $0 }
        let newAliases = (offer.aliases ?? []).filter { !held.names.contains($0) }
        let adding = adds(offer.width, held.width) || adds(offer.block, held.block)
            || adds(offer.description, held.description) || adds(offer.bits, held.bits) || !newAliases.isEmpty
        let rises = offer.status.rank > held.status.rank

        var state = held
        state.aliases = (held.aliases ?? []) + newAliases
        if state.aliases?.isEmpty == true { state.aliases = nil }
        state.width = offer.width ?? held.width
        state.block = offer.block ?? held.block
        state.description = offer.description ?? held.description
        state.bits = offer.bits ?? held.bits
        state.by = by
        state.at = at
        state.reason = nil
        state.changedIn = next
        state.replacedIn = nil
        if rises {
            state.status = offer.status
            state.evidence = offer.evidence
        }

        if !differing.isEmpty {
            if replace {
                state.status = offer.status
                state.evidence = offer.evidence ?? held.evidence
                state.reason = reason
                return commit(entry, state, .replaced)
            }
            if weak && offer.status.rank >= held.status.rank {
                if !rises, offer.evidence != nil { state.evidence = offer.evidence }
                return commit(entry, state, rises ? .confirmed : .refined)
            }
            return result(.conflict, entry, why: "the registry's \(differing.joined(separator: ", ")) for \(held.name) "
                          + "(\(held.status.rawValue)) stands; another is a replacement: `replace` with a reason")
        }
        if rises { return commit(entry, state, .confirmed) }
        if adding { return commit(entry, state, .refined) }
        return result(.same, entry)
    }
}
