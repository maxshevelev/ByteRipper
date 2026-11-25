import Foundation

// The shared registry of GUID names: one name for each GUID a review names in
// a module's code — a PPI, a protocol, a HOB, a variable's vendor GUID, an
// event group, a configuration table — kept once for every module. A name in
// a module's interface record, in a label on its bytes or in the app's code
// panel is the registry's, so two reviews cannot call one GUID two things.
//
// Names are EDK2's variable form, `gEfiPeiMemoryDiscoveredPpiGuid`, the form
// the `.dec` files declare and the UEFI pass labels with. Each entry says
// where its name comes from: a `.dec` file of the pinned EDK2 tag, or a
// review, with the module and the address where the code shows what the GUID
// is. The rule is the one types and the library registry keep: a new GUID is
// added; the same name is no change; a placeholder named properly is an
// addition; any other new name is a replacement, which only an administrator
// makes, with a reason the history keeps.
//
// The store holds it in `guids/registry.json`, history and all: a few
// thousand short entries, read whole by the server, the mirror and the app.
// Only the server writes it.

/// What a GUID identifies. A `.dec` file's `[Guids]` section says no more than
/// `guid`; a review says which of the rest it is.
public enum GuidKind: String, Codable, CaseIterable, Sendable {
    case ppi
    case `protocol`
    case hob
    case variable
    case event
    case table
    case guid
}

/// Where an entry's name comes from.
public struct GuidSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A `.dec` file of the EDK2 tag the registry was seeded from.
        case edk2
        /// A review: the module and the address where the code shows what the
        /// GUID is — the install with its descriptor, the call that uses it.
        case review
    }

    public var kind: Kind
    /// For `edk2`: the tag, and the `.dec` file and line, `MdePkg/MdePkg.dec:512`.
    public var tag: String?
    public var file: String?
    /// For `review`: the module and the address in it.
    public var module: SHA256Digest?
    public var address: String?

    public init(kind: Kind, tag: String? = nil, file: String? = nil, module: SHA256Digest? = nil,
                address: String? = nil) {
        self.kind = kind
        self.tag = tag
        self.file = file
        self.module = module
        self.address = address
    }

    public static func edk2(tag: String, file: String) -> GuidSource {
        GuidSource(kind: .edk2, tag: tag, file: file)
    }

    public static func review(module: SHA256Digest, address: String) -> GuidSource {
        GuidSource(kind: .review, module: module, address: address)
    }
}

/// One version of an entry, as the history keeps it.
public struct GuidVersion: Codable, Equatable, Sendable {
    public var version: Int
    public var name: String
    public var kind: GuidKind
    public var source: GuidSource
    public var note: String?
    /// Why an administrator gave this version over the one before; nil for any other.
    public var reason: String?
    public var by: String?
    public var at: String

    public init(version: Int, name: String, kind: GuidKind, source: GuidSource, note: String? = nil,
                reason: String? = nil, by: String? = nil, at: String) {
        self.version = version
        self.name = name
        self.kind = kind
        self.source = source
        self.note = note
        self.reason = reason
        self.by = by
        self.at = at
    }
}

/// A place a review named the GUID with the entry's name: evidence beside the
/// source, and the modules a rename would reach.
public struct GuidCitation: Codable, Equatable, Hashable, Sendable {
    public var module: SHA256Digest
    public var address: String

    public init(module: SHA256Digest, address: String) {
        self.module = module
        self.address = address
    }
}

/// A GUID's entry: its current version and every version before it.
public struct GuidEntry: Codable, Equatable, Sendable {
    public var name: String
    public var kind: GuidKind
    public var source: GuidSource
    public var note: String?
    public var version: Int
    /// Why an administrator gave this version over the one before; nil for any other.
    public var reason: String?
    public var by: String?
    public var at: String
    public var citations: [GuidCitation]?
    /// The versions before this one, oldest first.
    public var history: [GuidVersion]?

    public init(name: String, kind: GuidKind, source: GuidSource, note: String? = nil, version: Int = 1,
                reason: String? = nil, by: String? = nil, at: String, citations: [GuidCitation]? = nil,
                history: [GuidVersion]? = nil) {
        self.name = name
        self.kind = kind
        self.source = source
        self.note = note
        self.version = version
        self.reason = reason
        self.by = by
        self.at = at
        self.citations = citations
        self.history = history
    }

    /// The current version as the history will keep it.
    var asVersion: GuidVersion {
        GuidVersion(version: version, name: name, kind: kind, source: source, note: note, reason: reason,
                    by: by, at: at)
    }
}

/// The registry: entries by GUID, `0AE8CE5D-E448-4437-A8D7-EBF5F194F731`.
public struct GuidRegistry: Codable, Equatable, Sendable {
    public var schema: Int
    public var entries: [String: GuidEntry]

    public static let currentSchema = 1

    public init(entries: [String: GuidEntry] = [:]) {
        self.schema = Self.currentSchema
        self.entries = entries
    }

    /// The registry's name for a GUID, in any spelling the GUID is written in.
    /// The entry for `guid`, written in any case.
    public func entry(of guid: String) -> GuidEntry? {
        GuidName.canonicalGUID(guid).flatMap { entries[$0] }
    }

    public func name(of guid: String) -> String? {
        GuidName.canonicalGUID(guid).flatMap { entries[$0]?.name }
    }

    /// The GUIDs holding a name, any case: a name should belong to one GUID.
    public func guids(named name: String) -> [String] {
        entries.filter { $0.value.name.caseInsensitiveCompare(name) == .orderedSame }.keys.sorted()
    }
}

/// The spelling rules of the registry's GUIDs and names.
public enum GuidName {
    /// `0ae8ce5d-e448-4437-a8d7-ebf5f194f731` or with braces → upper case,
    /// 8-4-4-4-12; nil for anything else.
    public static func canonicalGUID(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "{} \t"))
        let groups = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12],
              groups.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return trimmed.uppercased()
    }

    /// Whether a name is in the registry's form: `g`, a capital, letters,
    /// digits and underscores, `Guid` at the end.
    public static func isRegistryName(_ name: String) -> Bool {
        guard name.count > 5, name.hasPrefix("g"), name.hasSuffix("Guid") else { return false }
        let chars = Array(name)
        guard chars[1].isUppercase else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// A name a review gave for want of a better one: `gUnknown…`, `gUnnamed…`, or one that
    /// carries the GUID's first group, as reviews wrote them before the
    /// registry (`gAmdSocInfoPpiGuid07C09B9CGuid`).
    public static func isPlaceholder(_ name: String, guid: String? = nil) -> Bool {
        if name.hasPrefix("gUnknown") || name.hasPrefix("gUnnamed") { return true }
        guard let guid, let data1 = canonicalGUID(guid)?.prefix(8) else { return false }
        return name.uppercased().contains(data1)
    }

    /// The placeholder for a GUID whose role is known but whose name is not:
    /// `gUnknownPpi9C98130AGuid`.
    public static func placeholder(kind: GuidKind, guid: String) -> String {
        let data1 = String(guid.prefix(8)).uppercased()
        let word = kind == .protocol ? "Protocol" : kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()
        return "gUnknown\(word)\(data1)Guid"
    }

    /// A name written another way, in the registry's form: the type's name
    /// (`EFI_PEI_MEMORY_DISCOVERED_PPI` → `gEfiPeiMemoryDiscoveredPpiGuid`),
    /// the UEFITool catalogue's (`EfiPciIoProtocolGuid` → `gEfiPciIoProtocolGuid`),
    /// or the registry's own. Nil when nothing of a name is left.
    public static func registryForm(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
              let first = name.first, first.isLetter else { return nil }
        if isRegistryName(name) { return name }
        var stem: String
        let letters = name.filter(\.isLetter)
        if name.contains("_") && letters == letters.uppercased() {
            // A type's name: words between underscores.
            stem = name.split(separator: "_").map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }.joined()
        } else {
            stem = name.replacingOccurrences(of: "_", with: "")
            let chars = Array(stem)
            if chars.count > 1, chars[0] == "g", chars[1].isUppercase {
                stem.removeFirst()
            }
            stem = stem.prefix(1).uppercased() + stem.dropFirst()
        }
        if stem.hasSuffix("Guid") { stem.removeLast(4) }
        guard !stem.isEmpty else { return nil }
        return "g\(stem)Guid"
    }

    /// Why a review's name does not fit its kind, or nil when it does: a PPI's
    /// name says `Ppi`, a protocol's `Protocol`, as EDK2 spells them.
    public static func kindMismatch(name: String, kind: GuidKind) -> String? {
        switch kind {
        case .ppi where !name.contains("Ppi"):
            return "a PPI's name says `Ppi` (\(name))"
        case .protocol where !name.contains("Protocol"):
            return "a protocol's name says `Protocol` (\(name))"
        default:
            return nil
        }
    }
}

/// A review's offer of a name for a GUID.
public struct GuidOffer: Codable, Equatable, Sendable {
    public var guid: String
    public var name: String
    public var kind: GuidKind
    public var source: GuidSource
    public var note: String?

    public init(guid: String, name: String, kind: GuidKind, source: GuidSource, note: String? = nil) {
        self.guid = guid
        self.name = name
        self.kind = kind
        self.source = source
        self.note = note
    }
}

/// What an offer did, or would do.
public struct GuidOfferResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The registry did not hold the GUID: it does now.
        case added
        /// It held the same name: the place is cited, nothing else changed.
        case same
        /// A placeholder named properly, or a plain GUID given its kind: the next version.
        case addition
        /// An administrator's new name over another: the next version, with its reason.
        case replaced
        /// Another name than the registry's: refused, the registry's stands.
        case conflict
    }

    public var guid: String
    public var outcome: Outcome
    /// The entry as it stands after the offer — the registry's own on a conflict.
    public var entry: GuidEntry
    /// For a conflict: what was offered, and why it is refused.
    public var offered: String?
    public var why: String?
}

extension ContentStore {
    public var guidsURL: URL { root.appendingPathComponent("guids", isDirectory: true) }
    var guidRegistryURL: URL { guidsURL.appendingPathComponent("registry.json", isDirectory: false) }

    /// The registry; empty while it was never seeded.
    public func guidRegistry() throws -> GuidRegistry {
        guard FileManager.default.fileExists(atPath: guidRegistryURL.path) else { return GuidRegistry() }
        do {
            return try decoder.decode(GuidRegistry.self, from: Data(contentsOf: guidRegistryURL))
        } catch {
            throw CodeAnalysisError.io("\(guidRegistryURL.path): \(error)")
        }
    }

    /// The registry as the server holds it, written into a mirror.
    public func mirrorGuids(_ registry: GuidRegistry) throws {
        try withLock {
            let data = try encoder.encode(registry)
            if (try? Data(contentsOf: guidRegistryURL)) != data {
                try atomicWrite(data, to: guidRegistryURL)
            }
        }
    }

    /// Offer a review's name for a GUID (`GuidRegistry`'s rule). `replace`
    /// with a `reason` is an administrator's: it makes a new name the next
    /// version over the registry's. `dryRun` answers and writes nothing.
    public func offerGuid(_ offer: GuidOffer, by: String?, replace: Bool = false, reason: String? = nil,
                          dryRun: Bool = false, now: Date = Date()) throws -> GuidOfferResult {
        guard let guid = GuidName.canonicalGUID(offer.guid) else {
            throw CodeAnalysisError.invalidName("\(offer.guid) is no GUID: 8-4-4-4-12 hex digits")
        }
        guard GuidName.isRegistryName(offer.name) else {
            let hint = GuidName.registryForm(offer.name).map { " — `\($0)`" } ?? ""
            throw CodeAnalysisError.invalidName(
                "\(offer.name) is not in the registry's form: `g`, the name, `Guid`\(hint)")
        }
        if offer.source.kind == .review {
            guard offer.source.module != nil,
                  !(offer.source.address ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CodeAnalysisError.invalidName(
                    "a review's name gives the module and the address where the code shows what the GUID is")
            }
            if !GuidName.isPlaceholder(offer.name, guid: offer.guid), let mismatch = GuidName.kindMismatch(name: offer.name, kind: offer.kind) {
                throw CodeAnalysisError.invalidName(mismatch)
            }
        }
        if replace, (reason ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw CodeAnalysisError.invalidName("a replacement gives its reason")
        }
        let at = ISO8601DateFormatter().string(from: now)
        return try withLock {
            var registry = try guidRegistry()
            let result = Self.apply(offer, guid: guid, to: &registry, by: by, replace: replace, reason: reason, at: at)
            if !dryRun, result.outcome != .conflict {
                try atomicWrite(try encoder.encode(registry), to: guidRegistryURL)
            }
            return result
        }
    }

    /// Seed or extend the registry with many entries at once, each by the
    /// rule of `offerGuid` without a replacement. One write.
    public func offerGuids(_ offers: [GuidOffer], by: String?, dryRun: Bool = false,
                           now: Date = Date()) throws -> [GuidOfferResult] {
        let at = ISO8601DateFormatter().string(from: now)
        return try withLock {
            var registry = try guidRegistry()
            var results: [GuidOfferResult] = []
            for offer in offers {
                guard let guid = GuidName.canonicalGUID(offer.guid), GuidName.isRegistryName(offer.name) else { continue }
                results.append(Self.apply(offer, guid: guid, to: &registry, by: by, replace: false, reason: nil, at: at))
            }
            if !dryRun {
                let data = try encoder.encode(registry)
                if (try? Data(contentsOf: guidRegistryURL)) != data {
                    try atomicWrite(data, to: guidRegistryURL)
                }
            }
            return results
        }
    }

    /// What still uses a registry entry: a module's interface record that
    /// holds its GUID or its name, a library body that reads a GUID global of
    /// its value or under its name. An entry anything uses is not removed.
    public struct GuidReference: Codable, Equatable, Sendable {
        /// `module` or `library`.
        public var kind: String
        /// The module's digest, or the library entry's id.
        public var at: String
        /// The module's name, or the library entry's.
        public var name: String?
        public var guid: String
        public var written: String?
        public var address: String?
    }

    public struct GuidRemoval: Codable, Equatable, Sendable {
        public var guid: String
        /// The entry as it stood, history and all — what the removal takes away.
        public var entry: GuidEntry
        public var reason: String
        public var applied: Bool
    }

    /// Everything in the store that uses `guid` or `name`.
    public func guidReferences(guid: String, name: String) throws -> [GuidReference] {
        var found: [GuidReference] = []
        for item in try GuidSeed.recorded(in: self)
        where item.guid == guid || item.name == name || item.written == name {
            found.append(GuidReference(kind: "module", at: item.module.hex, name: item.moduleName, guid: item.guid,
                                       written: item.written, address: item.address))
        }
        let index = try libraryIndex()
        for (id, entry) in index.entries.sorted(by: { $0.key < $1.key }) {
            for variant in entry.variants {
                for global in variant.globals ?? [] {
                    let value = global.guid.flatMap { GuidName.canonicalGUID($0) }
                    guard value == guid || (global.guid != nil && global.name == name) else { continue }
                    found.append(GuidReference(kind: "library", at: id, name: entry.name, guid: value ?? guid,
                                               written: global.name, address: "+\(global.offset)"))
                }
            }
        }
        return found
    }

    /// Remove a wrong entry completely, its history with it: an
    /// administrator's, with a reason, for an entry nothing uses. The reason
    /// is answered, not kept — nothing of the entry is to remain.
    /// `expectName` guards against the wrong GUID; `dryRun` writes nothing.
    public func removeGuid(_ guidText: String, reason: String, expectName: String? = nil,
                           dryRun: Bool = false) throws -> GuidRemoval {
        guard let guid = GuidName.canonicalGUID(guidText) else {
            throw CodeAnalysisError.invalidName("\(guidText) is no GUID: 8-4-4-4-12 hex digits")
        }
        guard !reason.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CodeAnalysisError.invalidName("a removal gives its reason")
        }
        func check(_ registry: GuidRegistry) throws -> GuidEntry {
            guard let entry = registry.entries[guid] else {
                throw CodeAnalysisError.invalidName("the registry has no \(guid)")
            }
            if let expectName, entry.name != expectName {
                throw CodeAnalysisError.analysisMismatch(
                    "the registry names \(guid) \(entry.name), not \(expectName): nothing removed")
            }
            let references = try guidReferences(guid: guid, name: entry.name)
            if !references.isEmpty {
                let list = references.map { ref in
                    "\(ref.kind) \(ref.at)\(ref.name.map { " (\($0))" } ?? "")"
                        + "\(ref.written.map { " as \($0)" } ?? "")\(ref.address.map { " at \($0)" } ?? "")"
                }
                throw CodeAnalysisError.analysisMismatch(
                    "\(entry.name) (\(guid)) is still referenced, nothing removed:\n  " + list.joined(separator: "\n  "))
            }
            return entry
        }
        // References are read before the lock: the readers take none, and a
        // nested lock on the same file would wait on itself.
        _ = try check(try guidRegistry())
        return try withLock {
            var registry = try guidRegistry()
            guard let entry = registry.entries[guid] else {
                throw CodeAnalysisError.invalidName("the registry has no \(guid)")
            }
            if let expectName, entry.name != expectName {
                throw CodeAnalysisError.analysisMismatch(
                    "the registry names \(guid) \(entry.name), not \(expectName): nothing removed")
            }
            if !dryRun {
                registry.entries[guid] = nil
                try atomicWrite(try encoder.encode(registry), to: guidRegistryURL)
            }
            return GuidRemoval(guid: guid, entry: entry, reason: reason, applied: !dryRun)
        }
    }

    static func apply(_ offer: GuidOffer, guid: String, to registry: inout GuidRegistry, by: String?,
                      replace: Bool, reason: String?, at: String) -> GuidOfferResult {
        let citation = offer.source.kind == .review
            ? offer.source.module.flatMap { module in offer.source.address.map { GuidCitation(module: module, address: $0) } }
            : nil
        guard var entry = registry.entries[guid] else {
            let entry = GuidEntry(name: offer.name, kind: offer.kind, source: offer.source, note: offer.note,
                                  by: by, at: at, citations: citation.map { [$0] })
            registry.entries[guid] = entry
            return GuidOfferResult(guid: guid, outcome: .added, entry: entry)
        }
        func cite() {
            guard let citation else { return }
            var list = entry.citations ?? []
            if !list.contains(citation) {
                list.append(citation)
                entry.citations = list
            }
        }
        /// The offer becomes the current version; `keepsSource` for a kind a
        /// review told, which does not move the name's source.
        func nextVersion(reason: String?, keepsSource: Bool = false) {
            entry.history = (entry.history ?? []) + [entry.asVersion]
            entry.version += 1
            entry.name = offer.name
            entry.kind = offer.kind
            if !keepsSource { entry.source = offer.source }
            entry.note = offer.note ?? entry.note
            entry.reason = reason
            entry.by = by
            entry.at = at
        }
        if entry.name == offer.name {
            // The same name; a review may tell a `.dec`'s plain GUID's kind.
            if entry.kind == .guid, offer.kind != .guid, entry.kind != offer.kind {
                nextVersion(reason: nil, keepsSource: true)
                cite()
                registry.entries[guid] = entry
                return GuidOfferResult(guid: guid, outcome: .addition, entry: entry)
            }
            if entry.note == nil, let note = offer.note { entry.note = note }
            cite()
            registry.entries[guid] = entry
            return GuidOfferResult(guid: guid, outcome: .same, entry: entry)
        }
        if GuidName.isPlaceholder(entry.name, guid: guid), !GuidName.isPlaceholder(offer.name, guid: guid) {
            nextVersion(reason: nil)
            entry.citations = nil
            cite()
            registry.entries[guid] = entry
            return GuidOfferResult(guid: guid, outcome: .addition, entry: entry)
        }
        if replace {
            nextVersion(reason: reason)
            entry.citations = nil
            cite()
            registry.entries[guid] = entry
            return GuidOfferResult(guid: guid, outcome: .replaced, entry: entry)
        }
        let why = entry.source.kind == .edk2
            ? "EDK2 names it \(entry.name) (\(entry.source.file ?? "a .dec file"))"
            : "the registry names it \(entry.name), from a review; a new name is an administrator's replacement"
        return GuidOfferResult(guid: guid, outcome: .conflict, entry: entry, offered: offer.name, why: why)
    }
}

extension ModuleInterfaces {
    /// The record as it reads: each entry under the registry's name for its
    /// GUID, where the registry holds one, whatever the review wrote then. A
    /// name kept with the record never drifts from the registry's, and a
    /// rename there needs no record rewritten.
    public func named(by registry: GuidRegistry) -> ModuleInterfaces {
        func renamed(_ list: [Interface]?) -> [Interface]? {
            list?.map { entry in
                var entry = entry
                if let name = registry.name(of: entry.guid) { entry.name = name }
                return entry
            }
        }
        return ModuleInterfaces(installs: renamed(installs), locates: renamed(locates), notifies: renamed(notifies))
    }

    /// The entries whose name the registry does not give them, each with why:
    /// a GUID it does not hold, or another name than its own. Empty when the
    /// registry holds nothing — a store never seeded checks nothing.
    public func misnamed(by registry: GuidRegistry) -> [(list: String, guid: String, name: String, why: String)] {
        guard !registry.entries.isEmpty else { return [] }
        var found: [(String, String, String, String)] = []
        for (list, entries) in [("installs", installs), ("locates", locates), ("notifies", notifies)] {
            for entry in entries ?? [] {
                guard let guid = GuidName.canonicalGUID(entry.guid) else { continue }
                if let held = registry.entries[guid] {
                    if held.name != entry.name {
                        found.append((list, guid, entry.name, "the GUID registry names it \(held.name)"))
                    }
                } else {
                    found.append((list, guid, entry.name,
                                  "the GUID registry does not hold it: add it with `ghidra_guid_add` at the place "
                                  + "that shows what it is, then name it as the registry does"))
                }
            }
        }
        return found
    }
}
