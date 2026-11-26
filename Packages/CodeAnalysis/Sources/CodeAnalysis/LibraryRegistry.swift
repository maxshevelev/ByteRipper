import Foundation

// The shared registry of library functions (`Design/LIBRARY_REGISTRY_PLAN.md`):
// a library function's review kept once, keyed by its body, for every module
// whose function has the same body. The store holds it under `library/`; the
// entries themselves are objects, as review documents are.

/// A function's body as Ghidra's Function ID hashes it: the code units, the
/// full hash (operands that are addresses masked) and the specific hash
/// (constants kept). Two bodies with the same key are the same code.
public struct LibraryBody: Codable, Hashable, Comparable, Sendable {
    public var size: Int
    public var full: String
    public var specific: String

    public init(size: Int, full: String, specific: String) {
        self.size = size
        self.full = full.lowercased()
        self.specific = specific.lowercased()
    }

    /// `<size>-<full>-<specific>`, the index's key for this body.
    public var key: String { "\(String(size, radix: 16))-\(full)-\(specific)" }

    /// A body under Function ID's four instructions, which it does not hash. The
    /// owner hashes its exact bytes instead. One `RET` is many functions, so
    /// bytes alone identify nothing: `full` is the bytes, shared as a shape by
    /// every entry holding them, and an entry's `specific` is its own at random,
    /// which makes the entry's id. A review binds a function to one by that id.
    public var isShort: Bool { size < Self.functionIDMinimum }
    public static let functionIDMinimum = 4

    /// Whether a body key is a short body's.
    public static func isShort(key: String) -> Bool {
        key.split(separator: "-").first.flatMap { Int($0, radix: 16) }.map { $0 < functionIDMinimum } ?? false
    }

    /// The body with a `specific` of its own, for a new short entry.
    func withOwnIdentity() -> LibraryBody {
        var body = self
        body.specific = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        return body
    }

    /// `<size>-<full>`: what bodies that differ only in constants share.
    public var shape: String { "\(String(size, radix: 16))-\(full)" }

    /// A body as the owner reports it: 64-bit hashes in hex, a size above 0.
    public var isValid: Bool {
        size > 0 && Self.isHash(full) && Self.isHash(specific)
    }

    static func isHash(_ text: String) -> Bool {
        text.count == 16 && text.allSatisfy { $0.isHexDigit }
    }

    public static func < (left: Self, right: Self) -> Bool { left.key < right.key }
}

/// Who published a version of an entry: the module, the function's address
/// in it, the revision of the module's reading, and who published it. A
/// record of the history, not an owner — every module whose function has the
/// body holds the entry alike.
public struct LibrarySource: Codable, Equatable, Sendable {
    public var module: SHA256Digest
    public var address: String
    public var rev: Int?
    public var by: String?

    public init(module: SHA256Digest, address: String, rev: Int?, by: String?) {
        self.module = module
        self.address = address
        self.rev = rev
        self.by = by
    }
}

/// A module global a body reads, by the offset of the instruction that names
/// it from the function's entry: the name a review gave it, for a reader, and
/// its type. A library function may read a global of a shared type — one the
/// EDK2 archive or the shared review archive holds, of the same shape — and the
/// type is what it reads there: in another module, the function is the entry's
/// only where its global at that instruction has the same type (issue 5b6ade08).
/// `shared` is the owner's verdict on the type; an artifact does not give it.
public struct LibraryGlobal: Codable, Equatable, Sendable {
    public var offset: String
    public var name: String?
    public var type: String?
    public var shared: Bool?
    /// Where the global is in the module that offers the body: what a refusal
    /// shows. Never kept on an entry, since another module's is elsewhere.
    public var address: String?
    /// For a global typed `EFI_GUID`: its value, `8-4-4-4-12`. A GUID global
    /// is a known constant, so it reads like a shared global only under the
    /// GUID registry's name for that value (`admittingGuids`).
    public var guid: String?
    /// The GUID registry's name for `guid`, where it is not the global's own
    /// name: what the refusal tells the reviewer to name it. Never kept.
    public var registryName: String?
    /// For a string the body reads: its bytes, terminator included, as hex.
    /// In an `amd` or `intel` body a string is part of the entry's data and
    /// is compared byte for byte (`admittingStrings`); in an `edk2` one it
    /// stays a data reference that needs a citation.
    public var text: String?

    public init(offset: String, name: String? = nil, type: String? = nil, shared: Bool? = nil,
                address: String? = nil, guid: String? = nil, registryName: String? = nil, text: String? = nil) {
        self.text = text
        self.offset = offset
        self.name = name
        self.type = type
        self.shared = shared
        self.address = address
        self.guid = guid
        self.registryName = registryName
    }

    /// What a variant keeps of the globals a proposal reads: those of a shared
    /// type, without the verdict. Nil when there are none.
    static func kept(_ globals: [LibraryGlobal]?) -> [LibraryGlobal]? {
        let kept = (globals ?? []).filter { $0.shared == true }.map {
            LibraryGlobal(offset: $0.offset, name: $0.name, type: $0.type, guid: $0.guid, text: $0.text)
        }
        return kept.isEmpty ? nil : kept
    }

    /// A global the owner reported as a GUID (`guid` set).
    public var isGuid: Bool { guid != nil }

    /// How a refusal names the datum: `0x7850 gEfiPcdProtocolGuid (EFI_GUID) at +0x20`.
    public var said: String {
        "\(address ?? "a datum") \(name ?? "unnamed") (\(type ?? "untyped")) at +\(offset)"
    }
}

extension LibraryProposal {
    /// The person's rule for GUID globals (issue d92d6b88): a GUID global is
    /// a known constant — EDK2's AutoGen gives every module its own copy of a
    /// value the package `.dec` fixes — so a body that reads one does the same
    /// in every module, provided the global carries the GUID registry's name
    /// for its value. Such a global becomes a shared one and leaves
    /// `dataReferences`; one under another name, or of a value the registry
    /// does not hold, stays a data reference and says what the registry calls it.
    public func admittingGuids(_ registry: GuidRegistry?) -> LibraryProposal {
        guard let registry, let globals, globals.contains(where: \.isGuid) else { return self }
        var proposal = self
        var admitted: Set<String> = []
        proposal.globals = globals.map { global in
            guard let guid = global.guid else { return global }
            var global = global
            let held = registry.name(of: guid)
            if let held, held == global.name {
                global.shared = true
                admitted.insert(global.offset)
            } else {
                global.shared = false
                global.registryName = held
            }
            return global
        }
        proposal.dataReferences = dataReferences?.filter { !admitted.contains($0) }
        return proposal
    }

    /// Libraries with no public source to cite a string's line in.
    public static let uncitedStringKinds: Set<String> = [LibraryKind.amd.rawValue, LibraryKind.intel.rawValue,
                                                         LibraryKind.ite.rawValue, LibraryKind.toolchain.rawValue]

    /// The person's rule for strings (2026-11-26): an `amd` or `intel` body
    /// has no public source to cite, so a string it reads — a debug message
    /// it prints — enters the entry as part of its data, its bytes compared
    /// byte for byte when another module's function is linked
    /// (`LibraryIndex.globalsDiffer`). Such a string leaves `dataReferences`.
    /// An `edk2` body's string stays a data reference: its citation is
    /// required.
    public func admittingStrings() -> LibraryProposal {
        guard Self.uncitedStringKinds.contains(kind), let globals,
              globals.contains(where: { $0.text != nil && $0.guid == nil }) else { return self }
        var proposal = self
        var admitted: Set<String> = []
        proposal.globals = globals.map { global in
            guard global.text != nil, global.guid == nil else { return global }
            var global = global
            global.shared = true
            admitted.insert(global.offset)
            return global
        }
        proposal.dataReferences = dataReferences?.filter { !admitted.contains($0) }
        return proposal
    }
}

/// One body an entry covers. An entry starts with one; bodies that differ
/// from it only in assert codes are added as variants, each with the codes
/// it carries.
public struct LibraryVariant: Codable, Equatable, Sendable {
    public var body: LibraryBody
    public var module: SHA256Digest
    /// The assert codes this body holds where the entry's first body holds
    /// others; nil for the first body.
    public var codes: [String]?
    /// The digest of what this body's data references point at, as its module
    /// reported it. Nil for a body with none, and until its module publishes
    /// under an exporter that reports it.
    public var referenceBytes: String?
    /// The body's code (`LibraryCode`): the one place its instructions are kept.
    public var code: SHA256Digest?
    /// What the body calls, written in its code: the registry numbers of its
    /// callees, sorted (`LibraryProposal.calls`). The same bytes calling
    /// another function are another function. Nil from before this was
    /// recorded; the code says it then, where the registry has the code.
    public var callees: [String]?
    /// The module globals of a shared type the body reads (`LibraryGlobal`).
    /// Nil for a body that reads none, and for one recorded before this was.
    public var globals: [LibraryGlobal]?

    public init(body: LibraryBody, module: SHA256Digest, codes: [String]? = nil, referenceBytes: String? = nil,
                code: SHA256Digest? = nil, callees: [String]? = nil, globals: [LibraryGlobal]? = nil) {
        self.globals = globals
        self.code = code
        self.callees = callees
        self.body = body
        self.module = module
        self.codes = codes
        self.referenceBytes = referenceBytes
    }

    private enum CodingKeys: String, CodingKey {
        case body, module, codes, code, callees, globals
        case referenceBytes = "reference_bytes"
    }
}

/// An entry as the index lists it: its current version and the object that
/// holds it, the name and kind a reader looks for, and its bodies.
public struct LibraryIndexEntry: Codable, Equatable, Sendable {
    public var version: Int
    public var entry: SHA256Digest
    public var name: String
    public var kind: String
    public var source: LibrarySource
    public var variants: [LibraryVariant]
    /// `assert` for an assert routine: the codes it is called with make
    /// variants of its callers' entries. Nil for any other function.
    public var role: String?

    public init(version: Int, entry: SHA256Digest, name: String, kind: String, source: LibrarySource,
                variants: [LibraryVariant], role: String? = nil) {
        self.version = version
        self.entry = entry
        self.name = name
        self.kind = kind
        self.source = source
        self.variants = variants
        self.role = role
    }
}

/// One library the registry holds, and the libraries it stands on.
public struct LibraryDefinition: Codable, Equatable, Sendable {
    public var dependsOn: [String]

    public init(dependsOn: [String] = []) {
        self.dependsOn = dependsOn
    }

    private enum CodingKeys: String, CodingKey {
        case dependsOn = "depends_on"
    }
}

/// `library/index.json`: every entry by its id, and every body of every entry
/// by its key, so an exact match is one lookup.
public struct LibraryIndex: Codable, Equatable, Sendable {
    public var schema = 1
    /// The libraries and how they depend on each other: EDK2 is the base, AMD and
    /// Intel stand on it and not on each other. Nil only in an index from before
    /// this was written down, which reads as the standard set.
    public var libraries: [String: LibraryDefinition]?
    public var entries: [String: LibraryIndexEntry] = [:]
    public var bodies: [String: String] = [:]
    /// The other entries holding a body `bodies` names, each calling other
    /// functions than the first: the body key leaves out where a call goes,
    /// and the same bytes calling another function are another function
    /// (issue df8c0e9c). Their ids are the key and a digest of what they
    /// call (`calleeID`). Nil while there are none.
    public var sameBody: [String: [String]]?
    /// Bodies given back to their modules, by key. Nil while there are none.
    public var takenOut: [String: LibraryTakenOut]?
    /// Where a body's constant is defined in its library's source, by key.
    public var sources: [String: LibraryCitation]?
    /// The citations later calls replaced or removed, by key. Nil while none.
    public var sourceChanges: [String: [LibraryCitationChange]]?
    public init() {
        libraries = Self.standardLibraries
    }

    public static let standardLibraries: [String: LibraryDefinition] = [
        LibraryKind.edk2.rawValue: LibraryDefinition(),
        LibraryKind.amd.rawValue: LibraryDefinition(dependsOn: [LibraryKind.edk2.rawValue]),
        LibraryKind.intel.rawValue: LibraryDefinition(dependsOn: [LibraryKind.edk2.rawValue]),
        // An EC module's: ITE's code may call the toolchain's runtime; neither
        // calls EDK2.
        LibraryKind.ite.rawValue: LibraryDefinition(dependsOn: [LibraryKind.toolchain.rawValue]),
        LibraryKind.toolchain.rawValue: LibraryDefinition()
    ]

    /// The declared libraries.
    public var declaredLibraries: [String: LibraryDefinition] { libraries ?? Self.standardLibraries }

    /// Whether a function of library `caller` may call one of library `callee`:
    /// its own, or one its library depends on, directly or through another.
    public func mayCall(_ caller: String, _ callee: String) -> Bool {
        let declared = declaredLibraries
        guard declared[caller] != nil else { return false }
        var seen: Set<String> = [], waiting = [caller]
        while let next = waiting.popLast() {
            guard seen.insert(next).inserted else { continue }
            if next == callee { return true }
            waiting += declared[next]?.dependsOn ?? []
        }
        return false
    }

    /// Whether a body's data references point at other bytes than the entry
    /// holds for it. Either side not knowing says nothing.
    public func bytesDiffer(id: String, body: String, referenceBytes: String?) -> Bool {
        // An entry that has not learned them decides nothing yet; once it has, a
        // function that says none is in doubt, and doubt stays the module's.
        guard let held = entries[id]?.variants.first(where: { $0.body.key == body })?.referenceBytes else { return false }
        return held != referenceBytes
    }

    /// Why a function's globals are not the ones the entry's body reads, nil
    /// when they are: each global of a shared type the entry reads must be,
    /// in this module, a global of the same type at the same instruction. An
    /// entry that records none decides nothing; once it does, a function that
    /// says nothing of its globals is in doubt, and doubt stays the module's.
    public func globalsDiffer(id: String, body: String, globals: [LibraryGlobal]?) -> String? {
        guard let held = entries[id]?.variants.first(where: { $0.body.key == body })?.globals, !held.isEmpty
        else { return nil }
        for expected in held {
            // A string an `amd` or `intel` body reads is the entry's only with
            // the same bytes (`LibraryProposal.admittingStrings`).
            if let text = expected.text, expected.guid == nil {
                let reads = "the entry reads the string \(Self.quoted(text)) at +\(expected.offset)"
                guard let globals else { return reads + ", and this function's globals are not known: publish its module again" }
                guard let here = globals.first(where: { $0.offset == expected.offset }) else {
                    return reads + ", and this function reads no datum there"
                }
                if here.text != text {
                    return reads + ": here it reads " + (here.text.map { "\(Self.quoted($0)), other bytes" } ?? "no string")
                        + ". Only the same string, byte for byte, is the entry's"
                }
                continue
            }
            // A GUID is the same constant only under the same registry name
            // and value: its type says nothing (issue d92d6b88).
            if let guid = expected.guid {
                let name = expected.name ?? "?"
                let reads = "the entry reads GUID \(name) (\(guid)) at +\(expected.offset)"
                guard let globals else { return reads + ", and this function's globals are not known: publish its module again" }
                guard let here = globals.first(where: { $0.offset == expected.offset }) else {
                    return reads + ", and this function reads no global there"
                }
                let otherValue = here.guid.map { GuidName.canonicalGUID($0) != GuidName.canonicalGUID(guid) } ?? false
                if here.name != expected.name || otherValue {
                    return reads + ": here it reads \(here.name ?? "an unnamed global")"
                        + (here.guid.map { " (\($0))" } ?? " (\(here.type ?? "untyped"))")
                        + ", another GUID or not the registry's name for it. Only a global of the same GUID under "
                        + "the GUID registry's name is the entry's"
                }
                continue
            }
            let type = expected.type ?? "?"
            let reads = "the entry reads a global of type \(type) at +\(expected.offset)"
                + (expected.name.map { " (\($0) where it was reviewed)" } ?? "")
            guard let globals else { return reads + ", and this function's globals are not known: publish its module again" }
            guard let here = globals.first(where: { $0.offset == expected.offset }) else {
                return reads + ", and this function reads no global there"
            }
            let named = here.name ?? "the global"
            if here.type == nil {
                return reads + ": \(named) here is untyped. Type \(named) as \(type) first"
            }
            if here.type != expected.type || here.shared == false {
                return reads + ": \(named) here is \(here.type ?? "untyped")"
                    + (here.type == expected.type ? ", not the shared archive's type of that name" : "")
                    + ". Type \(named) as \(type) first"
            }
        }
        return nil
    }

    /// A string's hex bytes as a reader sees them, quoted; the hex where
    /// they are not text.
    static func quoted(_ hex: String) -> String {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return hex }
            bytes.append(byte)
            index = next
        }
        let wide = bytes.count >= 4 && bytes[1] == 0
        let text = wide
            ? String(decoding: stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }, as: UTF16.self)
            : String(decoding: bytes, as: UTF8.self)
        return "\"" + text.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) + "\""
    }

    private enum CodingKeys: String, CodingKey {
        case schema, entries, bodies, sources, libraries
        case takenOut = "taken_out"
        case sourceChanges = "source_changes"
        case sameBody = "same_body"
    }

    /// Every entry holding a body: the first, then those calling other functions.
    public func holders(of key: String) -> [String] {
        (bodies[key].map { [$0] } ?? []) + (sameBody?[key] ?? [])
    }

    /// Records that entry `id` holds the body `key`.
    public mutating func hold(_ key: String, by id: String) {
        guard let first = bodies[key] else { bodies[key] = id; return }
        guard first != id, !(sameBody?[key] ?? []).contains(id) else { return }
        var others = sameBody ?? [:]
        others[key, default: []].append(id)
        sameBody = others
    }

    /// Records that entry `id` no longer holds the body `key`: another entry
    /// holding it becomes the first.
    public mutating func release(_ key: String, from id: String) {
        var others = sameBody?[key] ?? []
        if bodies[key] == id {
            bodies[key] = others.isEmpty ? nil : others.removeFirst()
        } else {
            others.removeAll { $0 == id }
        }
        var all = sameBody ?? [:]
        all[key] = others.isEmpty ? nil : others
        sameBody = all.isEmpty ? nil : all
    }

    /// The id of an entry holding a body another entry holds already: the key,
    /// and a digest of what this one calls.
    public static func calleeID(body key: String, callees: [String]) -> String {
        let digest = SHA256Digest(data: Data(callees.sorted().joined(separator: ",").utf8)).hex
        return "\(key)-\(digest.prefix(8))"
    }

    /// The body key an entry id is made of: the id itself, or the key it adds
    /// a callee digest to.
    public static func bodyKey(ofEntry id: String) -> String {
        id.split(separator: "-").prefix(3).joined(separator: "-")
    }

    /// What entry `id`'s body `key` calls, as its variant records it or its
    /// code says; nil when neither does.
    public func callees(ofEntry id: String, body key: String, object: (SHA256Digest) throws -> Data) -> [String]? {
        guard let variant = entries[id]?.variants.first(where: { $0.body.key == key }) ?? entries[id]?.variants.first
        else { return nil }
        // Never itself: a recursive call stays inside its body's code, and an
        // entry recorded before that was said may list it.
        let own: Set<String> = [id, key]
        let coded = variant.code.flatMap { try? object($0) }.map { LibraryCode.callees(code: $0) }
        // A tail jump is a callee too: the code names its target, while an
        // owner from before that listed only calls (issue cbffc53d), so what
        // the variant records is read together with what its code names.
        guard let named = variant.callees.map({ Set(recordedCallees($0, coded: coded, module: variant.module)).union(coded ?? []) }) ?? coded
        else { return nil }
        return named.subtracting(own).sorted()
    }

    /// What a variant records it calls, a short callee read as the entry it
    /// became. A publish before issue 38a7f82b recorded a new short callee by
    /// the key the owner gave it, while the entry took an identity of its own:
    /// that key is no entry and no entry holds it, and the code — written
    /// after the entries — names the entry of the same bytes. A variant with
    /// no code reads the one entry of those bytes its own module wrote.
    func recordedCallees(_ recorded: [String], coded: Set<String>?, module: SHA256Digest) -> [String] {
        recorded.compactMap { key in
            guard LibraryBody.isShort(key: key), entries[key] == nil, holders(of: key).isEmpty else { return key }
            let shape = Self.shape(ofKey: key)
            let became = coded.map { $0.filter { entries[$0] != nil && Self.shape(ofKey: $0) == shape } }
                ?? Set(entries.filter { id, entry in
                    Self.shape(ofKey: id) == shape && entry.variants.contains { $0.module == module }
                }.keys)
            return became.count == 1 ? became.first : key
        }
    }

    static func shape(ofKey key: String) -> String {
        key.split(separator: "-").prefix(2).joined(separator: "-")
    }

    /// The entry a body belongs to.
    public func entry(for body: LibraryBody) -> (id: String, entry: LibraryIndexEntry)? {
        guard let id = bodies[body.key], let entry = entries[id] else { return nil }
        return (id, entry)
    }
}

/// One version of an entry as its history keeps it.
public struct LibraryVersion: Codable, Equatable, Sendable {
    public var version: Int
    public var entry: SHA256Digest
    public var source: LibrarySource
    /// Why this version differs: what an agent said on taking a review the
    /// entry's current version was not the base of, or the function's reason for
    /// a signature that changed. Nil for the first version and for a change
    /// nobody gave a reason for.
    public var reason: String?
    public var recordedAt: String
    /// The module this row's change was asked from, when `source` still names
    /// the review's author and so is not it. Nil from a build that predates it,
    /// and on a row whose `source` is the module that made the change.
    public var changedFrom: SHA256Digest? = nil

    private enum CodingKeys: String, CodingKey {
        case version, entry, source, reason
        case recordedAt = "recorded_at"
        case changedFrom = "changed_from"
    }
}

/// `library/history/<id>.json`: every version of one entry, oldest first.
public struct LibraryHistory: Codable, Equatable, Sendable {
    public var id: String
    public var versions: [LibraryVersion]
}

/// Which conflicts a publish takes — none, every one, or those it names, each
/// with the reason the history keeps. A review made on the entry's current
/// version needs no decision; this decides the others.
public struct LibraryTake: Codable, Equatable, Sendable {
    /// Take every conflicting entry, with one reason.
    public var all: Bool
    /// The entries to take by id, each with a reason of its own.
    public var reasons: [String: String]
    /// The reason a take of every conflict keeps.
    public var reason: String?
    /// Why this publish adds to an entry, by entry id, in the review's own words.
    public var entryReasons: [String: String] = [:]

    public static let none = LibraryTake()

    public static func all(_ reason: String) -> LibraryTake {
        LibraryTake(all: true, reason: reason, reasons: [:])
    }

    /// Take the entries named, in the order of their reasons — each needs one.
    public static func these(_ reasons: [String: String]) -> LibraryTake {
        LibraryTake(all: false, reason: nil, reasons: reasons)
    }

    private init(all: Bool = false, reason: String? = nil, reasons: [String: String] = [:]) {
        self.all = all
        self.reason = reason
        self.reasons = reasons
    }

    /// This decision, with the reasons for the entries the publish moves.
    public func with(entryReasons: [String: String]) -> LibraryTake {
        var copy = self
        copy.entryReasons = entryReasons
        return copy
    }

    /// The ids this decision names.
    public var ids: Set<String> { Set(reasons.keys) }

    public var isEmpty: Bool { !all && reasons.isEmpty }

    /// The reason for an entry this decision takes, nil when it does not take it.
    public func reason(for id: String) -> String? {
        all ? reason : reasons[id]
    }
}

/// What a publish offers the registry: one tagged function reviewed to the
/// bar, its body, and its review as the canonical JSON object the entry is.
public struct LibraryProposal: Codable, Equatable, Sendable {
    public var body: LibraryBody
    public var name: String
    public var kind: String
    public var address: String
    /// The entry object's bytes: sorted keys, nothing of the module in it.
    public var entry: Data
    /// The entry this body was applied from as a variant, and the assert
    /// codes that made it one.
    public var variantOf: String?
    public var codes: [String]?
    /// `assert` for an assert routine.
    public var role: String?
    /// The entry and version the function was applied from or marked with
    /// at its last publish (its `ByteRipper.libraryEntry` mark): a change
    /// made on the entry's current version is its next version, from any
    /// module.
    public var basedOn: String?
    public var base: Int?
    /// The function carries the entry's mark and was not edited since.
    public var linked: Bool = false
    /// The digest of what the body's data references point at (`LibraryVariant`).
    public var referenceBytes: String?
    /// A linked function has no review to offer: this says only what its bytes are.
    public var teachesBytesOnly: Bool?
    /// The body's code, for a body the registry holds without it. Teaches only that.
    public var code: Data?
    /// Set by the host when other modules hold the entry: an edit of the
    /// body that only its C shows — a decompiler temporary named or typed —
    /// is not offered, and the publish takes the review as the entry's own.
    public var keepsEntryBody: Bool?
    /// What the body refers to, by offset from its entry, and what it calls:
    /// what decides whether it depends on a module. Nil from an owner that
    /// does not say. Beside the review, not part of it.
    public var dataReferences: [String]?
    public var callees: [LibraryCallee]?
    /// The module globals the body reads (`LibraryGlobal`), each with the
    /// owner's verdict on its type. Those of a shared type are no data
    /// reference: they stay out of `dataReferences`. Nil from an owner that
    /// does not say.
    public var globals: [LibraryGlobal]?

    public init(body: LibraryBody, name: String, kind: String, address: String, entry: Data,
                variantOf: String? = nil, codes: [String]? = nil, role: String? = nil,
                basedOn: String? = nil, base: Int? = nil,
                linked: Bool = false, dataReferences: [String]? = nil, callees: [LibraryCallee]? = nil,
                referenceBytes: String? = nil, teachesBytesOnly: Bool? = nil, globals: [LibraryGlobal]? = nil) {
        self.globals = globals
        self.teachesBytesOnly = teachesBytesOnly
        self.linked = linked
        self.referenceBytes = referenceBytes
        self.dataReferences = dataReferences
        self.callees = callees
        self.body = body
        self.name = name
        self.kind = kind
        self.address = address
        self.entry = entry
        self.variantOf = variantOf
        self.codes = codes
        self.role = role
        self.basedOn = basedOn
                self.base = base
    }
}

/// What a write did, entry by entry.
public struct LibraryWriteResult: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var version: Int
        /// For a publish's update: the review's fields it changes, so an entry
        /// gaining its recorded function is told from one whose text moves.
        public var changed: [String]?
        /// The names its C prints that this changes, each a reason answers for:
        /// `equate +NAME`, `equate -NAME`, `equate ~NAME` (its value or comment
        /// moved), `label +NAME`, `label -NAME`. Nil where there are none.
        public var names: [String]?
        /// The module whose publish or write made this change, and why it was
        /// made: what a reader of the answer checks. Nil on a row that changes
        /// nothing, and from a store that predates them.
        public var module: SHA256Digest?
        public var reason: String?
        /// On an unchanged row whose function was written on, why the write
        /// did not reach the entry; nil where the review is simply the entry's.
        public var why: String?
    }

    /// The entry for this body holds another review, and this module's was
    /// not made on its current version.
    public struct Conflict: Codable, Equatable, Sendable {
        public var id: String
        /// The name the entry holds and the name this module proposes.
        public var name: String
        public var proposedName: String
        /// Who published the entry's current version.
        public var heldBy: LibrarySource
        public var version: Int
        /// The version this module's review was made on; nil when the
        /// function never carried the entry.
        public var base: Int?
        /// The names its C prints that taking this would change (`Change.names`).
        public var names: [String]?
        /// What the review would replace, by field; nil from a store that does not say.
        public var changed: [String]?

        public init(id: String, name: String, proposedName: String, heldBy: LibrarySource, version: Int,
                    base: Int?, names: [String]? = nil, changed: [String]? = nil) {
            self.id = id
            self.name = name
            self.proposedName = proposedName
            self.heldBy = heldBy
            self.version = version
            self.base = base
            self.names = names
            self.changed = changed
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, version, base, names, changed
            case proposedName = "proposed_name"
            case heldBy = "held_by"
        }
    }

    public var added: [Change] = []
    public var updated: [Change] = []
    public var unchanged: [Change] = []
    public var conflicts: [Conflict] = []
    /// Bodies added to an entry as variants; nil from a store that has none.
    public var variants: [Change]?
    /// Functions refused because another entry holds the name: a different
    /// body is a different function, and the review gives it a narrower name.
    /// Nil from a store that has none.
    public var nameConflicts: [NameConflict]?
    /// Functions the registry did not take: they depend on a module, or were
    /// taken out. Nil from a store that has none.
    public var notLibrary: [NotLibrary]?
    /// What a change on the registry itself did; nil otherwise.
    public var takenOut: [Change]?
    /// The modules whose text of these bodies became links.
    public var relinked: [ContentStore.Relinked]?
    /// Why that could not be done; a later entry or `relink-modules` does it.
    public var relinkError: String?
    public var cited: [String]?
    public var citations: [LibraryCitationResult]?

    public struct NotLibrary: Codable, Equatable, Sendable {
        public var address: String
        public var name: String
        public var body: String
        /// `data`: a data reference no citation covers. `callee`: a call to a
        /// function the registry does not hold. `taken_out`: taken out before.
        /// `global`: a global of the entry's shared type is not of that type here.
        public var why: String
        public var reason: String?
        /// With `taken_out`: the review the reason was written about — the
        /// module and the function whose addresses it names, which need not
        /// be the module now offering the body.
        public var reasonOf: LibrarySource?
        public var data: [String]?
        /// With `data`: the globals at those offsets as the owner described
        /// them (`LibraryGlobal`), so a refusal names each datum by address,
        /// name and type. Nil where the owner said nothing of them.
        public var globals: [LibraryGlobal]?
        public var callees: [String]?

        public init(address: String, name: String, body: String, why: String, reason: String? = nil,
                    reasonOf: LibrarySource? = nil, data: [String]? = nil, callees: [String]? = nil,
                    globals: [LibraryGlobal]? = nil) {
            self.globals = globals
            self.address = address
            self.name = name
            self.body = body
            self.why = why
            self.reason = reason
            self.reasonOf = reasonOf
            self.data = data
            self.callees = callees
        }
    }

    public struct NameConflict: Codable, Equatable, Sendable {
        public var address: String
        public var name: String
        public var body: String
        public var heldBy: String
        public var heldVersion: Int

        public init(address: String, name: String, body: String, heldBy: String, heldVersion: Int) {
            self.address = address
            self.name = name
            self.body = body
            self.heldBy = heldBy
            self.heldVersion = heldVersion
        }

        private enum CodingKeys: String, CodingKey {
            case address, name, body
            case heldBy = "held_by"
            case heldVersion = "held_version"
        }
    }

    public init() {}

    /// A store that predates the rule leaves its rows without a module, and
    /// would take a change with no reason, whatever `entry_reasons` says.
    public var fromAStoreBeforeReasons: Bool {
        (added + updated + (variants ?? [])).contains { $0.module == nil }
    }

    /// What a publish is refused with before it is sent, nil when it goes.
    public var publishRefusal: String? {
        if fromAStoreBeforeReasons {
            return "the store predates the rule that a change to a library entry names its module and reason: "
                + "it would take this publish with no reason. Nothing was stored. Update the store's server first."
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case added, updated, unchanged, conflicts, variants
        case cited, citations
        case nameConflicts = "name_conflicts"
        case notLibrary = "not_library"
        case takenOut = "taken_out"
        case relinked
        case relinkError = "relink_error"
    }
}

extension LibraryProposal {
    /// The top-level fields of a review that differ between two entry objects.
    public static func changedFields(from old: Data, to new: Data) -> [String] {
        func fields(_ data: Data) -> [String: NSObject] {
            ((try? JSONSerialization.jsonObject(with: data)) as? [String: NSObject]) ?? [:]
        }
        let (before, after) = (fields(old), fields(new))
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }

    /// The named labels a C prints. `LAB_<address>` is the decompiler's, no name.
    private static func labels(in c: String) -> Set<String> {
        guard let pattern = try? NSRegularExpression(pattern: #"\bgoto\s+([A-Za-z_][A-Za-z0-9_]*)\s*;"#) else { return [] }
        let text = c as NSString
        let found = pattern.matches(in: c, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range(at: 1)) }
        return Set(found.filter { !$0.hasPrefix("LAB_") })
    }

    private static func prints(_ name: String, in c: String) -> Bool {
        c.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .regularExpression) != nil
    }

    /// The names an entry's C prints that an offer changes. Where either side
    /// holds no C there is nothing to compare. An entry from before entries
    /// recorded their equates, printing the name, has not changed by saying so.
    static func nameChanges(from held: Data, to offered: Data) -> [String] {
        func read(_ data: Data) -> (object: [String: Any], c: String)? {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let c = (object["function"] as? [String: Any])?["c"] as? String else { return nil }
            return (object, c)
        }
        guard let old = read(held), let new = read(offered) else { return [] }
        func facts(_ object: [String: Any]) -> [String: String] {
            var found: [String: String] = [:]
            for row in object["equates"] as? [[String: Any]] ?? [] {
                guard let name = row["name"] as? String else { continue }
                found[name] = "\(row["value"] ?? "")\u{0}\(row["comment"] ?? "")"
            }
            return found
        }
        let before = facts(old.object), after = facts(new.object)
        let recorded = old.object["equates"] != nil
        var rows: [String] = []
        for (name, fact) in after.sorted(by: { $0.key < $1.key }) {
            if let was = before[name] {
                if was != fact { rows.append("equate ~\(name)") }
            } else if recorded || !prints(name, in: old.c) {
                rows.append("equate +\(name)")
            }
        }
        for name in before.keys.sorted() where after[name] == nil { rows.append("equate -\(name)") }
        let (was, now) = (labels(in: old.c), labels(in: new.c))
        rows += now.subtracting(was).sorted().map { "label +\($0)" }
        rows += was.subtracting(now).sorted().map { "label -\($0)" }
        return rows
    }

    /// Whether an offered review only adds to the one the entry holds: everything
    /// the entry says is still said, word for word, and what is new stands where
    /// the entry said nothing — a comment or a plate it did not have, a name or a
    /// type in place of a Ghidra placeholder, an equate or a label it did not
    /// name. The function's name, its return type, its convention, a parameter's
    /// type or written name and any written text are the entry's: a review that
    /// moves one of them replaces it.
    public static func onlyAdds(to held: Data, offered: Data) -> Bool {
        guard let old = (try? JSONSerialization.jsonObject(with: held)) as? [String: Any],
              let new = (try? JSONSerialization.jsonObject(with: offered)) as? [String: Any] else { return false }
        // What `sameReview` leaves out is no part of a review. Those compared
        // here are the review's own, and any field no rule covers must stand.
        let compared: Set<String> = ["body", "constants", "function", "equates", "params", "signature", "locals",
                                     "plate", "comments"]
        func rest(_ object: [String: Any]) -> NSDictionary {
            object.filter { !compared.contains($0.key) } as NSDictionary
        }
        guard rest(old).isEqual(rest(new)) else { return false }
        guard nameChanges(from: held, to: offered).allSatisfy({ $0.hasPrefix("equate +") || $0.hasPrefix("label +") })
        else { return false }
        // The plate.
        let plate = old["plate"] as? String ?? ""
        guard plate.isEmpty || plate == new["plate"] as? String else { return false }
        // Comments: each the entry holds stands; others may join.
        func comment(_ row: [String: Any]) -> String {
            "\(row["offset"] ?? "")\u{0}\(row["kind"] ?? "")\u{0}\(row["text"] ?? "")"
        }
        let offeredComments = Set((new["comments"] as? [[String: Any]] ?? []).map(comment))
        guard (old["comments"] as? [[String: Any]] ?? []).allSatisfy({ offeredComments.contains(comment($0)) })
        else { return false }
        // Parameters: same number and types; a placeholder may take a name.
        let oldParams = old["params"] as? [[String: Any]] ?? [], newParams = new["params"] as? [[String: Any]] ?? []
        guard oldParams.count == newParams.count else { return false }
        var signature = old["signature"] as? String ?? ""
        for (was, now) in zip(oldParams, newParams) {
            guard was["type"] as? String == now["type"] as? String,
                  was["storage"] as? String == now["storage"] as? String else { return false }
            let (oldName, newName) = (was["name"] as? String, now["name"] as? String)
            guard oldName != newName else { continue }
            guard LibraryEntryReview.isPlaceholder(oldName), let oldName, let newName else { return false }
            signature = signature.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: oldName))\\b", with: newName, options: .regularExpression)
        }
        guard signature == new["signature"] as? String ?? "" else { return false }
        // Locals: a written name and a known type stand, by their place.
        func place(_ row: [String: Any]) -> String { "\(row["storage"] ?? "")\u{0}\(row["first_use"] ?? "")" }
        var offeredLocals: [String: [String: Any]] = [:]
        for row in new["locals"] as? [[String: Any]] ?? [] { offeredLocals[place(row)] = row }
        for row in old["locals"] as? [[String: Any]] ?? [] {
            let name = row["name"] as? String, type = row["type"] as? String
            if LibraryEntryReview.isPlaceholder(name), LibraryEntryReview.isUndefined(type) { continue }
            guard let now = offeredLocals[place(row)] else { return false }
            if !LibraryEntryReview.isPlaceholder(name), name != now["name"] as? String { return false }
            if !LibraryEntryReview.isUndefined(type), type != now["type"] as? String { return false }
        }
        return true
    }

    /// Whether two entry objects are the same review: equal but for the body
    /// they were read from, its constants, and the function as that module
    /// published it — what the variants of one entry share, and what another
    /// module's addresses and callee names would otherwise make a new version.
    /// A name the C prints is the review's: an equate or a named label that
    /// differs is another review, whatever else stands equal.
    public static func sameReview(_ left: Data, _ right: Data) -> Bool {
        func review(_ data: Data) -> NSDictionary? {
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            object["body"] = nil
            object["constants"] = nil
            object["function"] = nil
            object["equates"] = nil
            return object as NSDictionary
        }
        guard let reviewed = review(left), let other = review(right) else { return false }
        return reviewed.isEqual(other) && nameChanges(from: left, to: right).isEmpty
    }

    /// The held entry with its function's C as its own module prints it now,
    /// or nil when that is no mere printing. Only the module the C came from,
    /// at the same address, reprints it, so every address in it stays that
    /// module's; and the text must read the same but for a zero pointer's
    /// `NULL`, line breaks, and the warning of a convention nobody names. Any
    /// other difference is a review's, and goes as one. All else of the
    /// function stays the entry's, its reasons with it.
    static func reprinting(_ proposal: Data, in held: Data, heldSource: LibrarySource, source: LibrarySource) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: held)) as? [String: Any],
              var function = object["function"] as? [String: Any], let old = function["c"] as? String,
              let offered = ((try? JSONSerialization.jsonObject(with: proposal)) as? [String: Any])?["function"] as? [String: Any],
              let new = offered["c"] as? String, old != new else { return nil }
        let origin = function["source"] as? [String: Any]
        guard (origin?["module"] as? String ?? heldSource.module.hex) == source.module.hex,
              (origin?["address"] as? String ?? heldSource.address) == source.address,
              samePrinting(old, new) else { return nil }
        for key in ["c", "c_spans", "c_sites", "c_fields", "c_unreachable"] { function[key] = offered[key] }
        object["function"] = function
        return try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    /// Whether the module the entry's C came from, at the same address, now
    /// prints a body that reads otherwise than a reprinting allows: a review's
    /// edit below the head that the review's fields cannot show — a decompiler
    /// temporary (`HASH:…`) named or typed is the module's own and never one of
    /// the entry's `locals`, so only the C carries it.
    public static func editsBody(_ proposal: Data, in held: Data, heldSource: LibrarySource, source: LibrarySource) -> Bool {
        bodyPrint(proposal, in: held, heldSource: heldSource, source: source) == .fromOrigin
    }

    enum BodyPrint { case same, fromOrigin, fromElsewhere }

    /// Whether the offered C reads otherwise than the entry's, beyond a
    /// reprinting, and whether it comes from the module and address the
    /// entry's C came from.
    static func bodyPrint(_ proposal: Data, in held: Data, heldSource: LibrarySource, source: LibrarySource) -> BodyPrint {
        guard let object = (try? JSONSerialization.jsonObject(with: held)) as? [String: Any],
              let function = object["function"] as? [String: Any], let old = function["c"] as? String,
              let offered = ((try? JSONSerialization.jsonObject(with: proposal)) as? [String: Any])?["function"] as? [String: Any],
              let new = offered["c"] as? String, old != new, !samePrinting(old, new) else { return .same }
        let origin = function["source"] as? [String: Any]
        let fromOrigin = (origin?["module"] as? String ?? heldSource.module.hex) == source.module.hex
            && (origin?["address"] as? String ?? heldSource.address) == source.address
        return fromOrigin ? .fromOrigin : .fromElsewhere
    }

    /// Why a function written on left its entry unchanged, for the row that
    /// says so; nil when nothing was written that the entry could take.
    static func unchangedWhy(_ proposal: LibraryProposal, id: String, held: Data?, heldSource: LibrarySource,
                             source: LibrarySource) -> String? {
        if proposal.keepsEntryBody == true {
            return "kept in this module: other modules hold the entry, so a temporary's name stays here"
        }
        if proposal.linked {
            return "not edited since it was bound to the entry: a write that changes nothing, as a re-send "
                + "of the same name, leaves it bound"
        }
        guard proposal.basedOn == id, let held,
              bodyPrint(proposal.entry, in: held, heldSource: heldSource, source: source) == .fromElsewhere else { return nil }
        return "not this entry's source module: a name on a temporary changes the entry only from the module "
            + "its C came from (\(heldSource.module.hex.prefix(8))… at \(heldSource.address))"
    }

    /// The held entry with the equates its C prints, or nil when it has them
    /// already, or this is not the module its C came from. All else stays.
    static func fillingEquates(_ proposal: Data, in held: Data, heldSource: LibrarySource, source: LibrarySource) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: held)) as? [String: Any], object["equates"] == nil,
              let function = object["function"] as? [String: Any],
              let equates = ((try? JSONSerialization.jsonObject(with: proposal)) as? [String: Any])?["equates"] else { return nil }
        let origin = function["source"] as? [String: Any]
        guard (origin?["module"] as? String ?? heldSource.module.hex) == source.module.hex,
              (origin?["address"] as? String ?? heldSource.address) == source.address else { return nil }
        object["equates"] = equates
        return try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    /// Whether two prints of one function differ only as `reprinting` allows.
    /// A byte constant reads as a character, `FALSE`/`TRUE` or a number, and
    /// these are one printing: EDK2 types revision 5 turned `BOOLEAN` into an
    /// enum and `UINT8`/`INT8` into byte numbers, so `'\0'` came to print as
    /// `FALSE` or `0` and `'\xff'` as `0xff`.
    public static func samePrinting(_ old: String, _ new: String) -> Bool {
        func read(_ text: String) -> String {
            numbersOfLiterals(text.replacingOccurrences(of: #"/\*\s*WARNING: Unknown calling convention.*?\*/"#, with: "",
                                      options: .regularExpression)
                .replacingOccurrences(of: #"\([^()]*\)0x0\b"#, with: "NULL", options: .regularExpression))
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        }
        return read(old) == read(new)
    }

    /// The text with every character literal, hex number, `FALSE` and `TRUE`
    /// written as its decimal value.
    static func numbersOfLiterals(_ text: String) -> String {
        func replacing(_ pattern: String, in text: String, _ value: (String) -> String?) -> String {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
            let source = text as NSString
            var out = ""
            var last = 0
            for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                out += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let found = source.substring(with: match.range)
                let inner = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                    ? source.substring(with: match.range(at: 1)) : found
                out += value(inner) ?? found
                last = match.range.location + match.range.length
            }
            return out + source.substring(from: last)
        }
        let escapes: [String: UInt32] = ["n": 10, "t": 9, "r": 13, "a": 7, "b": 8, "f": 12, "v": 11,
                                         "\\": 92, "'": 39, "\"": 34, "?": 63]
        var text = replacing(#"'(\\x[0-9A-Fa-f]{1,2}|\\[0-7]{1,3}|\\.|[^'\\])'"#, in: text) { inner in
            if inner.hasPrefix("\\x") { return UInt32(inner.dropFirst(2), radix: 16).map(String.init) }
            if inner.hasPrefix("\\"), let octal = UInt32(inner.dropFirst(), radix: 8) { return String(octal) }
            if inner.hasPrefix("\\") { return escapes[String(inner.dropFirst())].map(String.init) }
            return inner.unicodeScalars.first.map { String($0.value) }
        }
        text = replacing(#"\b0x([0-9A-Fa-f]+)\b"#, in: text) { UInt64($0, radix: 16).map(String.init) }
        text = replacing(#"\bFALSE\b"#, in: text) { _ in "0" }
        return replacing(#"\bTRUE\b"#, in: text) { _ in "1" }
    }

    /// The held entry object with the proposal's function added, saying which
    /// module's reading it is; nothing else of the proposal comes with it.
    static func recording(_ proposal: Data, in held: Data, source: LibrarySource) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: held) as? [String: Any],
              let offered = try JSONSerialization.jsonObject(with: proposal) as? [String: Any],
              var function = offered["function"] as? [String: Any] else { return proposal }
        var origin: [String: Any] = ["module": source.module.hex, "address": source.address]
        origin["rev"] = source.rev
        function["source"] = origin
        object["function"] = function
        object["equates"] = offered["equates"]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The fields of a review that its function's head line prints: what a
    /// review may change of an entry and still leave its body's C the entry's.
    public static let headFields: Set<String> = ["calling_convention", "signature", "return_type", "params"]

    /// The held entry with only the proposal's head: its convention, signature,
    /// return type and parameters, and in the C its prototype line, with the
    /// warning of a convention nobody names gone when the proposal's C has
    /// none. Everything below the head — the body's C as the entry's module
    /// printed it, the temporaries that module could name apart, its labels,
    /// constants, equates and instructions — stays the entry's, and the C says
    /// it is still that module's reading (`function.source`). Nil when the
    /// review changes anything but the head, which is then a body's edit and
    /// goes as the module offers it, or when the head is the entry's already.
    public static func keepingEntryText(_ proposal: Data, in held: Data, heldSource: LibrarySource) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: held)) as? [String: Any],
              let offered = (try? JSONSerialization.jsonObject(with: proposal)) as? [String: Any],
              var function = object["function"] as? [String: Any], let old = function["c"] as? String,
              let offeredFunction = offered["function"] as? [String: Any], let new = offeredFunction["c"] as? String
        else { return nil }
        let changed = Set(changedFields(from: held, to: proposal)).subtracting(["body", "constants", "function", "equates"])
        guard !changed.isEmpty, changed.isSubset(of: headFields), nameChanges(from: held, to: proposal).isEmpty,
              let heldHead = CHead(old), let offeredHead = CHead(new) else { return nil }
        let text = old as NSString
        var removed: NSRange?
        if !offeredHead.warns, let warning = heldHead.warning { removed = warning }
        let prototype = (new as NSString).substring(with: offeredHead.prototype)
        let shrink = removed?.length ?? 0
        let start = heldHead.prototype.location - shrink
        let delta = prototype.utf16.count - heldHead.prototype.length - shrink
        var c = text.replacingCharacters(in: heldHead.prototype, with: prototype)
        if let removed { c = (c as NSString).replacingCharacters(in: removed, with: "") }
        // Each place the C names — a span, a call site, a field, the folded
        // warning — moves with the text: those of the prototype come from the
        // proposal's line, those of the removed warning go, the rest shift.
        func moved(_ held: Any?, offered: Any?) -> [[Any]]? {
            guard held != nil || offered != nil else { return nil }
            var rows: [[Any]] = []
            for row in held as? [[Any]] ?? [] {
                guard let at = row.first as? Int else { continue }
                if let removed, NSLocationInRange(at, removed) { continue }
                if NSLocationInRange(at, heldHead.prototype) { continue }
                var row = row
                if at >= NSMaxRange(heldHead.prototype) {
                    row[0] = at + delta
                } else if let removed, at >= NSMaxRange(removed) {
                    row[0] = at - shrink
                }
                rows.append(row)
            }
            for row in offered as? [[Any]] ?? [] {
                guard let at = row.first as? Int, NSLocationInRange(at, offeredHead.prototype) else { continue }
                var row = row
                row[0] = at - offeredHead.prototype.location + start
                rows.append(row)
            }
            return rows.sorted { ($0.first as? Int ?? 0) < ($1.first as? Int ?? 0) }
        }
        function["c"] = c
        for key in ["c_spans", "c_sites", "c_fields"] {
            function[key] = moved(function[key], offered: offeredFunction[key])
        }
        if var folded = function["c_unreachable"] as? [Any], let at = folded.first as? Int {
            if at >= NSMaxRange(heldHead.prototype) {
                folded[0] = at + delta
            } else if let removed, at >= NSMaxRange(removed) {
                folded[0] = at - shrink
            }
            function["c_unreachable"] = folded
        }
        function["signature"] = offeredFunction["signature"]
        if function["source"] == nil {
            var origin: [String: Any] = ["module": heldSource.module.hex, "address": heldSource.address]
            origin["rev"] = heldSource.rev
            function["source"] = origin
        }
        object["function"] = function
        for key in headFields { object[key] = offered[key] }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Where a function's C has its head: the prototype line just above the
    /// body's opening brace, and the line warning that no convention is named.
    /// Ranges in UTF-16 units, as the exporter counts the C's places.
    struct CHead {
        let prototype: NSRange
        let warning: NSRange?
        var warns: Bool { warning != nil }

        init?(_ c: String) {
            let text = c as NSString
            let brace = text.range(of: "\n{\n")
            guard brace.location != NSNotFound else { return nil }
            var end = brace.location
            while end > 0, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: end - 1)) ?? " ") {
                end -= 1
            }
            var line = text.lineRange(for: NSRange(location: max(end - 1, 0), length: 0))
            // A long prototype the printer wrapped goes on indented.
            while line.location > 0, line.length > 0, [0x20, 0x09].contains(text.character(at: line.location)) {
                line = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
            }
            guard end > line.location else { return nil }
            prototype = NSRange(location: line.location, length: end - line.location)
            let head = NSRange(location: 0, length: line.location)
            let pattern = try? NSRegularExpression(pattern: #"(?m)^[ \t]*/\*\s*WARNING: Unknown calling convention[^\n]*\*/[ \t]*\n"#)
            warning = pattern?.firstMatch(in: c, range: head)?.range
        }
    }

    /// Whether the entry object holds the function a reader is shown.
    static func hasFunction(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["function"] != nil
    }

    /// Whether an entry object holds the function with its C.
    public static func hasFunctionText(_ data: Data) -> Bool {
        (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["function"] as? [String: Any])?["c"] is String
    }

    /// Whether the entry object records the body's constants.
    static func hasConstants(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["constants"] != nil
    }
}

extension ContentStore {
    public var libraryURL: URL { root.appendingPathComponent("library", isDirectory: true) }
    var libraryIndexURL: URL { libraryURL.appendingPathComponent("index.json", isDirectory: false) }

    func libraryHistoryURL(_ id: String) -> URL {
        libraryURL.appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent("\(id).json", isDirectory: false)
    }

    /// The registry's index; empty while nothing was ever offered.
    public func libraryIndex() throws -> LibraryIndex {
        guard FileManager.default.fileExists(atPath: libraryIndexURL.path) else { return LibraryIndex() }
        do {
            var index = try decoder.decode(LibraryIndex.self, from: Data(contentsOf: libraryIndexURL))
            // Written down with the index's next write.
            index.libraries = index.declaredLibraries
            return index
        } catch {
            throw CodeAnalysisError.io("\(libraryIndexURL.path): \(error)")
        }
    }

    /// One entry's history, nil for an id the registry does not hold.
    public func libraryHistory(id: String) throws -> LibraryHistory? {
        guard SafeName.isSafe(id) else { throw CodeAnalysisError.invalidName(id) }
        let url = libraryHistoryURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(LibraryHistory.self, from: Data(contentsOf: url))
        } catch {
            throw CodeAnalysisError.io("\(url.path): \(error)")
        }
    }

    /// Offer a published module's library functions to the registry.
    ///
    /// A body the registry does not hold is a new entry, its id the body's
    /// key. A body it holds: the same review is no change; another review made
    /// on the entry's current version — the function carried it — is the
    /// next version, whichever module publishes it; any other review is a
    /// conflict, and the entry stays — unless `take` names it, when it becomes
    /// the next version with the reason `take` carries, which the history
    /// keeps and which every entry taken requires. No module holds an entry
    /// more than another.
    /// `dryRun` answers what the offer would do — the same result, the same
    /// refusals — and writes nothing: not the objects, not the index, not a
    /// history. A publish's preview is read with it.
    @discardableResult
    public func putLibraryEntries(module: SHA256Digest, rev: Int?, by: String?,
                                  proposals: [LibraryProposal], take: LibraryTake = .none,
                                  dryRun: Bool = false) throws -> LibraryWriteResult {
        var result = try writeLibraryEntries(module: module, rev: rev, by: by, proposals: proposals,
                                             take: take, dryRun: dryRun)
        // A body the registry holds has no other place: every module holding it
        // links to the entry now. Short bodies link by a review's decision only.
        // A body links once the registry holds its code.
        let bodies = Set(proposals.filter { $0.code != nil && $0.body.isValid }.map(\.body.key))
        if !dryRun, !bodies.isEmpty {
            do {
                let relinked = try relinkModules(bodies: bodies)
                if !relinked.isEmpty { result.relinked = relinked }
            } catch {
                result.relinkError = "\(error)"
            }
        }
        return result
    }

    private func writeLibraryEntries(module: SHA256Digest, rev: Int?, by: String?,
                                     proposals: [LibraryProposal], take: LibraryTake,
                                     dryRun: Bool) throws -> LibraryWriteResult {
        let allReason = take.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if take.all, allReason?.isEmpty ?? true {
            throw CodeAnalysisError.analysisMismatch("taking a library conflict needs a reason")
        }
        let reasons = take.reasons.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (id, reason) in reasons where reason.isEmpty {
            throw CodeAnalysisError.analysisMismatch("taking the library entry \(id) needs a reason")
        }
        let entryReasons = take.entryReasons.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let id = entryReasons.first(where: { $0.value.isEmpty })?.key {
            throw CodeAnalysisError.analysisMismatch("the reason given for the library entry \(id) is empty")
        }
        for proposal in proposals {
            guard proposal.body.isValid else {
                throw CodeAnalysisError.analysisMismatch("\(proposal.name): \(proposal.body.key) is not a body key")
            }
            guard LibraryKind(rawValue: proposal.kind) != nil else {
                throw CodeAnalysisError.analysisMismatch("\(proposal.name): \(proposal.kind) is not a library kind")
            }
        }
        // The objects first, as a publish stores its document before the
        // revision that names it — a preview names them without storing them.
        let stored = dryRun
            ? proposals.map { SHA256Digest(data: $0.entry) }
            : try proposals.map { try putObject($0.entry) }
        return try withLock {
            var index = try libraryIndex()
            // A decision that names an entry this publish does not offer is a
            // typo, not a take: refused before anything is written.
            let named = take.ids.union(entryReasons.keys)
            if let unknown = named.subtracting(Self.offeredIds(proposals, index)).sorted().first {
                throw CodeAnalysisError.analysisMismatch(
                    "no proposal in this publish carries the library entry \(unknown)")
            }
            var result = LibraryWriteResult()
            var histories: [String: LibraryHistory] = [:]
            var changedIndex = false
            // What the decision named actually came up a conflict: an entry
            // already settled is not taken silently, and a variant's conflict
            // cannot be the entry's next version.
            var conflicting: Set<String> = []
            // What this publish moves to a next version of its review: only
            // these can be given a reason of their own.
            var moving: Set<String> = []
            var variantConflicts: Set<String> = []
            var variantOf: [String: LibraryProposal] = [:]
            var settled: [String: String] = [:]
            let now = Timestamps.now()
            let admitted = LibraryProposal.admitted(proposals, in: index)
            // A new short body's identity, drawn before any proposal is read:
            // a caller in this publish names the callee by the key the owner
            // gave, and must record the entry it becomes, whichever of the two
            // the loop reaches first (issue 38a7f82b).
            var ownIdentity: [String: LibraryBody] = [:]
            // A short body bound to an entry, with the entry's instructions
            // and only its references' addresses other, reaching data of the
            // same names: another variant of the entry (issue 33cc22d2). It
            // comes as its code (`ModuleFormat.shortVariants`).
            func joinsShort(_ proposal: LibraryProposal) throws -> String? {
                guard proposal.teachesBytesOnly == true, let code = proposal.code,
                      let based = proposal.basedOn, let held = index.entries[based],
                      !held.variants.contains(where: { $0.body.key == proposal.body.key }),
                      let ours = LibraryShortShape.shape(ofCode: code) else { return nil }
                let labels = LibraryShortShape.labels(ofCode: code)
                let coded = held.variants.compactMap { $0.code }.compactMap { try? object($0) }
                if !coded.isEmpty {
                    return coded.contains {
                        LibraryShortShape.shape(ofCode: $0) == ours && LibraryShortShape.labels(ofCode: $0) == labels
                    } ? based : nil
                }
                // No body of the entry has its code yet: the function its review holds.
                func names(_ globals: [LibraryGlobal]?) -> [String] { (globals ?? []).compactMap(\.name).sorted() }
                guard LibraryShortShape.shape(ofEntry: try object(held.entry)) == ours,
                      held.variants.contains(where: { names($0.globals) == names(proposal.globals) }) else { return nil }
                return based
            }
            var shortJoins: [String: String] = [:]
            for proposal in proposals where proposal.body.isShort {
                if let based = proposal.basedOn,
                   index.entries[based]?.variants.contains(where: { $0.body.shape == proposal.body.shape }) == true {
                    continue
                }
                if let id = try joinsShort(proposal) {
                    shortJoins[proposal.body.key] = id
                    continue
                }
                ownIdentity[proposal.body.key] = proposal.body.withOwnIdentity()
            }
            // The same bytes offered twice are two functions: neither is the
            // one a caller's key names.
            for (key, count) in Dictionary(proposals.map { ($0.body.key, 1) }, uniquingKeysWith: +) where count > 1 {
                ownIdentity[key] = nil
            }
            for (offered, digest) in zip(proposals, stored).sorted(by: { $0.0.body < $1.0.body }) {
                // A short body is the entry its review was made on, or one of
                // its own: its bytes alone say nothing of which.
                var proposal = offered
                if proposal.body.isShort {
                    if let based = proposal.basedOn,
                       let held = index.entries[based]?.variants.first(where: { $0.body.shape == proposal.body.shape }) {
                        proposal.body = held.body
                    } else if let id = shortJoins[proposal.body.key], var held = index.entries[id] {
                        // Its own body, held by the entry beside the others, with its code.
                        held.variants.append(LibraryVariant(body: proposal.body, module: module,
                                                            referenceBytes: proposal.referenceBytes,
                                                            code: dryRun ? nil : try proposal.code.map(putObject),
                                                            callees: proposal.calls(in: index),
                                                            globals: LibraryGlobal.kept(proposal.globals)))
                        index.entries[id] = held
                        index.hold(proposal.body.key, by: id)
                        let joined = "the short body \(proposal.body.key) joins the entry as a variant: "
                            + "the same instructions, its globals at other addresses"
                        result.variants = (result.variants ?? []) + [.init(
                            id: id, name: held.name, version: held.version, module: module, reason: joined)]
                        var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                        history.versions.append(LibraryVersion(
                            version: held.version, entry: held.entry,
                            source: LibrarySource(module: module, address: proposal.address, rev: rev, by: by),
                            reason: joined, recordedAt: now))
                        histories[id] = history
                        settled[id] = "this publish joins it as a variant of version \(held.version)"
                        changedIndex = true
                        continue
                    } else {
                        proposal.body = ownIdentity[proposal.body.key] ?? proposal.body.withOwnIdentity()
                    }
                    proposal.variantOf = nil
                }
                let source = LibrarySource(module: module, address: proposal.address, rev: rev, by: by)
                // The entry this body is: of those holding its key, the one
                // calling what it calls. The same bytes calling another function
                // are another function (issue df8c0e9c), so a body none of them
                // calls like is a new entry. An entry that does not say what it
                // calls, or a proposal that does not, decides as the key alone.
                let calls = proposal.calls(in: index).map { numbers in
                    Array(Set(numbers.map { ownIdentity[$0]?.key ?? $0 })).sorted()
                }
                func callsAgree(_ id: String) -> Bool {
                    guard let calls, let theirs = index.callees(ofEntry: id, body: proposal.body.key, object: object)
                    else { return true }
                    return theirs == calls
                }
                func holder() -> (id: String, entry: LibraryIndexEntry)? {
                    // The entry the function was made on or is marked with, when it
                    // holds the body: what a module teaches an entry of its code
                    // names it so, and says nothing of its callees.
                    let holders = index.holders(of: proposal.body.key)
                    if let based = proposal.basedOn, holders.contains(based), callsAgree(based),
                       let entry = index.entries[based] {
                        return (based, entry)
                    }
                    for id in holders where callsAgree(id) {
                        if let entry = index.entries[id] { return (id, entry) }
                    }
                    return nil
                }
                // Only a new body is judged here: what the registry already
                // holds is put in order by a review, entry by entry.
                if holder() == nil, let refusal = proposal.refusal(in: index, admitted: admitted, admittedKinds: Dictionary(proposals.map { ($0.body.key, $0.kind) }, uniquingKeysWith: { first, _ in first })) {
                    result.notLibrary = (result.notLibrary ?? []) + [refusal]
                    continue
                }
                // A body applied as a variant joins its entry when the review
                // is the entry's and the body differs only in its constants:
                // one review, another body. Another shape is other code — a
                // function cut again since it took the entry — never a variant.
                if holder() == nil, let id = proposal.variantOf, callsAgree(id),
                   var held = index.entries[id] {
                    if proposal.body.shape == held.variants.first?.body.shape,
                       LibraryProposal.sameReview(try object(held.entry), proposal.entry) {
                        held.variants.append(LibraryVariant(body: proposal.body, module: module,
                                                            codes: proposal.codes,
                                                            referenceBytes: proposal.referenceBytes, callees: calls,
                                                            globals: LibraryGlobal.kept(proposal.globals)))
                        index.entries[id] = held
                        index.hold(proposal.body.key, by: id)
                        let joined = "the body \(proposal.body.key) joins the entry as a variant"
                        result.variants = (result.variants ?? []) + [.init(
                            id: id, name: held.name, version: held.version, module: module, reason: joined)]
                        var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                        history.versions.append(LibraryVersion(version: held.version, entry: held.entry, source: source,
                                                               reason: joined, recordedAt: now))
                        histories[id] = history
                        settled[id] = "this publish joins it as a variant of version \(held.version)"
                        changedIndex = true
                    } else if let taken = take.all ? allReason : reasons[id],
                              !held.variants.isEmpty, held.variants.allSatisfy({ $0.module == module }) {
                        // The entry's every body is this module's, and the
                        // function was cut again — a block decoded that was
                        // bytes: the body it has now is the entry's, by the
                        // decision that took it (issue 3b9b96b0). The old
                        // body goes; no module holds it.
                        conflicting.insert(id)
                        moving.insert(id)
                        let heldObject = try object(held.entry)
                        for old in held.variants { index.release(old.body.key, from: id) }
                        held.variants = [LibraryVariant(body: proposal.body, module: module,
                                                        referenceBytes: proposal.referenceBytes, callees: calls,
                                                        globals: LibraryGlobal.kept(proposal.globals))]
                        index.hold(proposal.body.key, by: id)
                        held.version += 1
                        held.entry = digest
                        held.name = proposal.name
                        held.kind = proposal.kind
                        held.role = proposal.role
                        held.source = source
                        index.entries[id] = held
                        let why = entryReasons[id] ?? taken
                        var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                        history.versions.append(LibraryVersion(version: held.version, entry: digest, source: source,
                                                               reason: "its body cut again, \(proposal.body.key): " + why,
                                                               recordedAt: now))
                        histories[id] = history
                        result.updated.append(.init(id: id, name: proposal.name, version: held.version,
                                                    changed: ["body"] + LibraryProposal.changedFields(
                                                        from: heldObject, to: proposal.entry).filter { $0 != "body" },
                                                    module: module, reason: why))
                        settled[id] = "its body is this module's, cut again, at version \(held.version)"
                        changedIndex = true
                    } else {
                        conflicting.insert(id)
                        variantConflicts.insert(id)
                        variantOf[id] = proposal
                        result.conflicts.append(.init(id: id, name: held.name, proposedName: proposal.name,
                                                      heldBy: held.source, version: held.version,
                                                      base: proposal.basedOn == id ? proposal.base : nil,
                                                      changed: LibraryProposal.changedFields(
                                                          from: try object(held.entry), to: proposal.entry)))
                    }
                    continue
                }
                // A library function's name is one function's: another body
                // under it is another function, and needs a narrower name.
                func namedOtherwise(than own: String?) -> LibraryWriteResult.NameConflict? {
                    guard let (other, entry) = index.entries.first(where: { $0.key != own && $0.value.name == proposal.name })
                    else { return nil }
                    return .init(address: proposal.address, name: proposal.name, body: proposal.body.key,
                                 heldBy: other, heldVersion: entry.version)
                }
                guard let (id, found) = holder() else {
                    if let conflict = namedOtherwise(than: nil) {
                        result.nameConflicts = (result.nameConflicts ?? []) + [conflict]
                        continue
                    }
                    // A key another entry holds, calling other functions: an id of its own.
                    let id = index.holders(of: proposal.body.key).isEmpty && index.entries[proposal.body.key] == nil
                        ? proposal.body.key : LibraryIndex.calleeID(body: proposal.body.key, callees: calls ?? [])
                    index.entries[id] = LibraryIndexEntry(
                        version: 1, entry: digest, name: proposal.name, kind: proposal.kind, source: source,
                        variants: [LibraryVariant(body: proposal.body, module: module,
                                                  referenceBytes: proposal.referenceBytes, callees: calls,
                                                  globals: LibraryGlobal.kept(proposal.globals))],
                        role: proposal.role)
                    index.hold(proposal.body.key, by: id)
                    histories[id] = LibraryHistory(id: id, versions: [
                        LibraryVersion(version: 1, entry: digest, source: source, reason: nil, recordedAt: now)
                    ])
                    result.added.append(.init(id: id, name: proposal.name, version: 1, module: module))
                    settled[id] = "this publish adds it as a new entry, version 1"
                    continue
                }
                // A short callee recorded by the owner's key, from before
                // issue 38a7f82b, is re-pointed at the entry it became.
                if let position = found.variants.firstIndex(where: { $0.body.key == proposal.body.key }),
                   let recorded = found.variants[position].callees {
                    let coded = found.variants[position].code.flatMap { try? object($0) }.map { LibraryCode.callees(code: $0) }
                    let repointed = index.recordedCallees(recorded, coded: coded, module: found.variants[position].module)
                    if repointed != recorded {
                        index.entries[id]?.variants[position].callees = repointed
                        changedIndex = true
                    }
                }
                // One key, other data: another function, which the entry does not
                // take and whose review says nothing of it.
                if index.bytesDiffer(id: id, body: proposal.body.key, referenceBytes: proposal.referenceBytes) {
                    result.notLibrary = (result.notLibrary ?? []) + [.init(
                        address: proposal.address, name: proposal.name, body: proposal.body.key, why: "reference_bytes",
                        reason: "its data references point at other bytes than the entry \(id) holds for this body")]
                    settled[id] = "this function's data references point at other bytes, so it is not this entry's"
                    continue
                }
                // The entry reads a global of a shared type that this module's
                // global is not: the function is the entry's once it is.
                if proposal.globals != nil,
                   let why = index.globalsDiffer(id: id, body: proposal.body.key, globals: proposal.globals) {
                    result.notLibrary = (result.notLibrary ?? []) + [.init(
                        address: proposal.address, name: proposal.name, body: proposal.body.key, why: "global",
                        reason: "entry \(id): " + why)]
                    settled[id] = "this function's global is not of the type the entry reads, so it is not this entry's yet"
                    continue
                }
                // The module the body came from says what its bytes are: an entry
                // from before this learns them, with no version moving.
                if let bytes = proposal.referenceBytes,
                   let position = found.variants.firstIndex(where: { $0.body.key == proposal.body.key }),
                   found.variants[position].referenceBytes == nil, found.variants[position].module == module {
                    index.entries[id]?.variants[position].referenceBytes = bytes
                    changedIndex = true
                }
                if let code = proposal.code, proposal.teachesBytesOnly == true {
                    if let position = found.variants.firstIndex(where: { $0.body.key == proposal.body.key }) ?? (found.variants.isEmpty ? nil : 0),
                       found.variants[position].code == nil, !dryRun {
                        index.entries[id]?.variants[position].code = try putObject(code)
                        changedIndex = true
                    }
                }
                if proposal.teachesBytesOnly == true {
                    settled[id] = "this publish only tells the entry what its data references point at"
                    continue
                }
                let held = index.entries[id] ?? found
                if held.entry == digest {
                    result.unchanged.append(.init(id: id, name: held.name, version: held.version,
                                                  why: LibraryProposal.unchangedWhy(proposal, id: id, held: nil,
                                                                                    heldSource: held.source, source: source)))
                    settled[id] = "its review is the entry's own, at version \(held.version)"
                    continue
                }
                // The same review from another body of the entry — a variant
                // — is no change; so is it from the entry's own body, unless
                // it records the constants the held object lacks.
                let heldObject = try object(held.entry)
                // Only the same review completes an entry with its function: a
                // review that differs is a change, and stays a conflict.
                let lacksFunction = !LibraryProposal.hasFunction(heldObject) && LibraryProposal.hasFunction(proposal.entry)
                    && LibraryProposal.sameReview(heldObject, proposal.entry)
                let completes = lacksFunction || (!LibraryProposal.hasConstants(heldObject)
                    && LibraryProposal.hasConstants(proposal.entry) && proposal.body == held.variants.first?.body)
                // The entry's own module, written on since it bound the body,
                // printing it otherwise: the body's review moved, though every
                // field the review lists and every name its C prints stands. It changes what the entry
                // says, so it goes as a replacement.
                let editsBody = proposal.basedOn == id && !proposal.linked && proposal.keepsEntryBody != true
                    && LibraryProposal.sameReview(heldObject, proposal.entry)
                    && LibraryProposal.editsBody(proposal.entry, in: heldObject, heldSource: held.source, source: source)
                if LibraryProposal.sameReview(heldObject, proposal.entry), !completes, !editsBody {
                    // An entry from before entries recorded their equates learns
                    // them from the module its C came from: no version moves.
                    if let filled = LibraryProposal.fillingEquates(proposal.entry, in: heldObject,
                                                                   heldSource: held.source, source: source) {
                        var next = held
                        next.entry = dryRun ? SHA256Digest(data: filled) : try putObject(filled)
                        index.entries[id] = next
                        var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                        let recorded = "the equates its C prints recorded by its module"
                        history.versions.append(LibraryVersion(version: held.version, entry: next.entry, source: held.source,
                                                               reason: recorded, recordedAt: now,
                                                               changedFrom: module))
                        histories[id] = history
                        result.updated.append(.init(id: id, name: held.name, version: held.version, changed: ["equates"],
                                                    module: module, reason: recorded))
                        settled[id] = "its review is the entry's own, at version \(held.version)"
                        continue
                    }
                    // Its C printed anew by the module it came from is no change
                    // of the review: no version moves, and no copy is behind.
                    if let reprinted = LibraryProposal.reprinting(proposal.entry, in: heldObject,
                                                                  heldSource: held.source, source: source) {
                        var next = held
                        next.entry = dryRun ? SHA256Digest(data: reprinted) : try putObject(reprinted)
                        index.entries[id] = next
                        var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                        let printed = "the function's C printed again by its module"
                        history.versions.append(LibraryVersion(version: held.version, entry: next.entry, source: held.source,
                                                               reason: printed, recordedAt: now,
                                                               changedFrom: module))
                        histories[id] = history
                        result.updated.append(.init(id: id, name: held.name, version: held.version, changed: ["function"],
                                                    module: module, reason: printed))
                        settled[id] = "its review is the entry's own, at version \(held.version)"
                        continue
                    }
                    result.unchanged.append(.init(id: id, name: held.name, version: held.version,
                                                  why: LibraryProposal.unchangedWhy(proposal, id: id, held: heldObject,
                                                                                    heldSource: held.source, source: source)))
                    settled[id] = "its review is the entry's own, at version \(held.version)"
                    continue
                }
                if proposal.name != held.name, let conflict = namedOtherwise(than: id) {
                    result.nameConflicts = (result.nameConflicts ?? []) + [conflict]
                    continue
                }
                let base = proposal.basedOn == id ? proposal.base : nil
                // A review that differs reaches here. What only adds to the entry
                // is its next version, from any module and on any version it was
                // made on; anything else replaces what the entry says, which only
                // an agreed proposal takes.
                conflicting.insert(id)
                let taken = take.all ? allReason : reasons[id]
                let recordsOnly = !editsBody && LibraryProposal.sameReview(heldObject, proposal.entry)
                let adds = !editsBody && LibraryProposal.onlyAdds(to: heldObject, offered: proposal.entry)
                guard adds || (completes && recordsOnly) || taken != nil else {
                    let printed = LibraryProposal.nameChanges(from: heldObject, to: proposal.entry)
                    result.conflicts.append(.init(id: id, name: held.name, proposedName: proposal.name,
                                                  heldBy: held.source, version: held.version, base: base,
                                                  names: printed.isEmpty ? nil : printed,
                                                  changed: LibraryProposal.changedFields(from: heldObject, to: proposal.entry)))
                    settled[id] = "this module's review replaces what the entry says: "
                        + "if the entry is the wrong one, propose this module's review with `ghidra_type_propose` — two "
                        + "other agents agreeing, or an administrator on the console's Proposals page, apply it at the next publish"
                    continue
                }
                // Past here sameReview means only what the review lacked gets
                // recorded. Anything else moves the review, and says why.
                let why: String
                if recordsOnly {
                    settled[id] = "this publish only records what its review lacked, which asks no reason"
                    why = entryReasons[id] ?? (lacksFunction ? "the function's C recorded" : "the body's constants recorded")
                } else {
                    moving.insert(id)
                    let added = LibraryProposal.changedFields(from: heldObject, to: proposal.entry)
                        .filter { !["body", "constants", "function"].contains($0) }
                    why = entryReasons[id] ?? taken ?? "added by this module: " + added.joined(separator: ", ")
                }
                var next = held
                // The function's C recorded in an entry is no change of its
                // review: no module's copy is behind for it, so none applies
                // the entry again and no module's revision moves.
                if !lacksFunction { next.version += 1 }
                // Recording what the review lacked does not make the module
                // that recorded it the review's author: `source` stays, and the
                // C says where it came from in its own `function.source`. Only
                // the function goes in: all else of the object stays the entry's.
                var recorded = digest
                var written = proposal.entry
                if lacksFunction {
                    written = try LibraryProposal.recording(proposal.entry, in: heldObject, source: source)
                    recorded = dryRun ? SHA256Digest(data: written) : try putObject(written)
                }
                next.entry = recorded
                next.name = proposal.name
                next.kind = proposal.kind
                next.role = proposal.role
                if !completes { next.source = source }
                index.entries[id] = next
                var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                let recordedWhy = lacksFunction
                    ? "the function's C recorded from \(source.module.hex) at \(source.address)" : why
                history.versions.append(LibraryVersion(version: next.version, entry: recorded,
                                                       source: completes ? held.source : source,
                                                       reason: recordedWhy, recordedAt: now,
                                                       changedFrom: completes ? module : nil))
                histories[id] = history
                result.updated.append(.init(id: id, name: proposal.name, version: next.version,
                                            changed: LibraryProposal.changedFields(from: heldObject, to: written),
                                            names: Optional(LibraryProposal.nameChanges(from: heldObject, to: written)).flatMap { $0.isEmpty ? nil : $0 },
                                            module: module, reason: recordedWhy))
            }
            // A decision that names an entry already settled — the same review,
            // the current version — would read as taken and be nothing: say so,
            // as the unknown id above is said, rather than pass in silence.
            if let id = take.ids.subtracting(conflicting).sorted().first {
                var text = "the entry \(id) is not in conflict in this publish"
                if let held = index.entries[id] {
                    text += ": \(held.name) is at version \(held.version), and "
                } else {
                    text += ": "
                }
                text += settled[id] ?? "this publish does not take it"
                throw CodeAnalysisError.analysisMismatch(text)
            }
            if let id = take.ids.intersection(variantConflicts).sorted().first {
                let proposal = variantOf[id]
                let function = proposal.map { "\($0.name) at \($0.address)" } ?? "this module's function"
                throw CodeAnalysisError.analysisMismatch(
                    "the entry \(id) is the entry of another body, and \(function) is not a variant of it: "
                        + "a variant's review cannot become the entry's. If the entry's bodies are all this "
                        + "module's, its author's correction takes the new body; otherwise refuse the entry for "
                        + "this function with `ghidra_library_apply` and `decline`, and review it on its own")
            }
            // A reason for an entry this publish does not move would read as
            // kept, and be nothing: said as a take of a settled entry is.
            if let id = Set(entryReasons.keys).subtracting(moving).sorted().first {
                var text = "the reason given for the entry \(id) has nothing to apply to"
                if let held = index.entries[id] { text += ": \(held.name) is at version \(held.version)" }
                text += ", and " + (settled[id] ?? "this publish does not change it")
                throw CodeAnalysisError.analysisMismatch(text)
            }
            guard !dryRun, !histories.isEmpty || changedIndex else { return result }
            for (id, history) in histories.sorted(by: { $0.key < $1.key }) {
                try atomicWrite(try encoder.encode(history), to: libraryHistoryURL(id))
            }
            try atomicWrite(try encoder.encode(index), to: libraryIndexURL)
            return result
        }
    }


    /// A review object under another name: its name, and the name in its
    /// signatures — what a split gives the body it makes an entry of.
    static func rename(_ review: inout [String: Any], from old: String, to name: String) {
        func renamed(_ signature: String) -> String {
            signature.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: old))\\b",
                                           with: name, options: .regularExpression)
        }
        review["name"] = name
        if let signature = review["signature"] as? String { review["signature"] = renamed(signature) }
        if var function = review["function"] as? [String: Any] {
            function["name"] = name
            if let signature = function["signature"] as? String { function["signature"] = renamed(signature) }
            renameInC(&function, from: old, to: name)
            review["function"] = function
        }
    }

    /// The stored C under the new name: the tokens that print the old one as a
    /// function, and every place written after them moved by as much. A comment
    /// that mentions the name is the review's text and stays.
    private static func renameInC(_ function: inout [String: Any], from old: String, to name: String) {
        guard let c = function["c"] as? String, let spans = function["c_spans"] as? [[Any]] else { return }
        var units = Array(c.utf16)
        let oldUnits = Array(old.utf16), newUnits = Array(name.utf16)
        let delta = newUnits.count - oldUnits.count
        // Old position → how far the text at or after it has moved.
        var moves: [(at: Int, by: Int)] = []
        let order = spans.indices.sorted { (spans[$0].first as? Int ?? 0) < (spans[$1].first as? Int ?? 0) }
        for index in order.reversed() {
            let span = spans[index]
            guard span.count >= 3, let start = span[0] as? Int, let length = span[1] as? Int, span[2] as? String == "function",
                  length == oldUnits.count, start + length <= units.count,
                  Array(units[start..<(start + length)]) == oldUnits else { continue }
            units.replaceSubrange(start..<(start + length), with: newUnits)
            moves.append((at: start + length, by: delta))
        }
        guard !moves.isEmpty else { return }
        func moved(_ position: Int) -> Int {
            position + moves.reduce(0) { $0 + ($1.at <= position ? $1.by : 0) }
        }
        func place(_ row: [Any]) -> [Any] {
            guard row.count >= 2, let start = row[0] as? Int, let length = row[1] as? Int else { return row }
            var row = row
            row[0] = moved(start)
            row[1] = moved(start + length) - moved(start)
            return row
        }
        function["c"] = String(decoding: units, as: UTF16.self)
        function["c_spans"] = spans.map(place)
        for key in ["c_sites", "c_fields", "c_unreachable"] {
            if let rows = function[key] as? [[Any]] { function[key] = rows.map(place) }
        }
    }

    /// The entry ids a publish's proposals may conflict with: the entry their
    /// body belongs to, the id of a body the registry does not hold yet, and
    /// the entry a variant was applied from.
    private static func offeredIds(_ proposals: [LibraryProposal], _ index: LibraryIndex) -> Set<String> {
        var ids: Set<String> = []
        for proposal in proposals {
            ids.insert(proposal.body.key)
            ids.formUnion(index.holders(of: proposal.body.key))
            if let calls = proposal.calls(in: index), !index.holders(of: proposal.body.key).isEmpty {
                ids.insert(LibraryIndex.calleeID(body: proposal.body.key, callees: calls))
            }
            if let variantOf = proposal.variantOf { ids.insert(variantOf) }
            if proposal.body.isShort, let based = proposal.basedOn { ids.insert(based) }
        }
        return ids
    }

    /// Make the registry's index what a served store holds: a mirror's copy.
    /// An unchanged index is not written again, as a manifest is not.
    public func mirrorLibrary(_ index: LibraryIndex) throws {
        try withLock {
            let data = try encoder.encode(index)
            if (try? Data(contentsOf: libraryIndexURL)) != data {
                try atomicWrite(data, to: libraryIndexURL)
            }
        }
    }

    /// Every object the registry names: each entry's current object and every
    /// version its history keeps.
    func libraryObjects() -> Set<SHA256Digest> {
        guard let index = try? libraryIndex() else { return [] }
        var objects = Set(index.entries.values.map(\.entry))
        // A body taken out keeps its text: its modules take it at their next open.
        objects.formUnion((index.takenOut ?? [:]).values.map(\.entry))
        // The bodies' code: the only place a linked function's instructions are.
        objects.formUnion(index.entries.values.flatMap(\.variants).compactMap(\.code))
        objects.formUnion((index.takenOut ?? [:]).values.compactMap(\.variant.code))
        for id in Set(index.entries.keys).union((index.takenOut ?? [:]).values.map(\.id)) {
            if let history = try? libraryHistory(id: id) {
                objects.formUnion(history.versions.map(\.entry))
            }
        }
        return objects
    }
}
