import Foundation

/// The GUID registry's first fill (`byteripper-cas guids-seed`): every GUID
/// the `.dec` files of an EDK2 checkout declare, and every name the stored
/// interface records give a GUID EDK2 does not have. What the sources disagree
/// on is listed for a person to settle and is not seeded: two `.dec` files
/// naming one GUID two ways, two reviews naming a vendor GUID two ways, a
/// record naming an EDK2 GUID otherwise than EDK2, and — when a catalogue is
/// given — the UEFITool catalogue naming a registry GUID otherwise. The
/// catalogue is compared only, never a source of names.
public struct GuidSeed: Codable, Equatable, Sendable {
    /// One GUID a `.dec` file declares.
    public struct Declared: Codable, Equatable, Sendable {
        public var guid: String
        public var name: String
        public var kind: GuidKind
        /// `MdePkg/MdePkg.dec:512`
        public var file: String
    }

    /// One name a stored interface record gives a GUID.
    public struct Recorded: Codable, Equatable, Sendable {
        public var guid: String
        /// In the registry's form.
        public var name: String
        /// As the record wrote it.
        public var written: String
        public var kind: GuidKind
        public var module: SHA256Digest
        public var moduleName: String?
        public var address: String
    }

    /// A GUID its sources name more than one way.
    public struct Disagreement: Codable, Equatable, Sendable {
        public var guid: String
        /// The registry's name, where it has one.
        public var registry: String?
        public var names: [Named]

        public struct Named: Codable, Equatable, Sendable {
            public var name: String
            /// `MdePkg/MdePkg.dec:512`, `PeiCore 0x9A05373`, `UEFITool catalogue`.
            public var places: [String]
        }
    }

    public var tag: String
    public var declared: Int
    public var recorded: Int
    /// What the seed adds, keeps or extends — or would, without `--apply`.
    public var added: Int
    public var same: Int
    public var additions: Int
    public var applied: Bool
    /// Two `.dec` files name a GUID two ways: the first by path is seeded.
    public var edk2Duplicates: [Disagreement]
    /// Reviews name a vendor GUID two ways: not seeded.
    public var recordConflicts: [Disagreement]
    /// A record names an EDK2 GUID otherwise than EDK2: EDK2's stands.
    public var recordsDifferFromEDK2: [Disagreement]
    /// The UEFITool catalogue names a registry GUID otherwise.
    public var catalogueDiffers: [Disagreement]?

    // MARK: - Reading the sources

    /// Every `g… = { … }` under a `[Guids]`, `[Ppis]` or `[Protocols]`
    /// section of a `.dec` file, any architecture's, in file order.
    public static func declarations(in text: String, file: String) -> [Declared] {
        var kind: GuidKind?
        var found: [Declared] = []
        let pattern = #"^\s*(g\w+)\s*=\s*\{\s*0x([0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)\s*,\s*\{([^}]*)\}\s*\}"#
        let regex = try? NSRegularExpression(pattern: pattern)
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let section = line.dropFirst().prefix { $0 != "]" }.lowercased()
                let names = section.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if names.allSatisfy({ $0.hasPrefix("guids") }) { kind = .guid }
                else if names.allSatisfy({ $0.hasPrefix("ppis") }) { kind = .ppi }
                else if names.allSatisfy({ $0.hasPrefix("protocols") }) { kind = .protocol }
                else { kind = nil }
                continue
            }
            guard let kind, let regex,
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { continue }
            func group(_ i: Int) -> String { String(raw[Range(match.range(at: i), in: raw)!]) }
            let rest = group(5).components(separatedBy: "0x").dropFirst().compactMap { part -> UInt8? in
                let digits = part.prefix { $0.isHexDigit }
                return digits.isEmpty ? nil : UInt8(truncatingIfNeeded: UInt64(digits, radix: 16) ?? 0)
            }
            guard rest.count == 8, let a = UInt32(group(2), radix: 16), let b = UInt16(group(3), radix: 16),
                  let c = UInt16(group(4), radix: 16) else { continue }
            let guid = String(format: "%08X-%04X-%04X-%02X%02X-", a, b, c, rest[0], rest[1])
                + rest[2...].map { String(format: "%02X", $0) }.joined()
            found.append(Declared(guid: guid, name: group(1), kind: kind, file: "\(file):\(index + 1)"))
        }
        return found
    }

    /// Every `.dec` file under an EDK2 checkout, by its path in the checkout.
    public static func declarations(checkout: URL) throws -> [Declared] {
        guard let walker = FileManager.default.enumerator(at: checkout, includingPropertiesForKeys: nil) else {
            throw CodeAnalysisError.io("\(checkout.path): cannot be read")
        }
        var files: [String] = []
        let base = checkout.standardizedFileURL.path
        for case let url as URL in walker where url.pathExtension == "dec" {
            let path = url.standardizedFileURL.path
            files.append(path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path)
        }
        return try files.sorted(by: { (rank($0), $0) < (rank($1), $1) }).flatMap { file in
            let text = try String(contentsOf: checkout.appendingPathComponent(file), encoding: .utf8)
            return declarations(in: text, file: file)
        }
    }

    /// MdePkg first, then MdeModulePkg, then the rest by path: a GUID two
    /// packages declare takes the base package's name. Within MdePkg two names
    /// for one GUID are the SMM and the newer MM spelling, and the file's
    /// first is kept; both are listed.
    static func rank(_ file: String) -> Int {
        file.hasPrefix("MdePkg/") ? 0 : file.hasPrefix("MdeModulePkg/") ? 1 : 2
    }

    /// The names the newest review of every module records for its
    /// interfaces.
    public static func recorded(in store: ContentStore) throws -> [Recorded] {
        var names: [SHA256Digest: String] = [:]
        for manifest in store.analyses() { names[manifest.module.sha256] = manifest.module.name }
        var found: [Recorded] = []
        for module in store.modules().sorted() {
            guard let last = try store.reviewHistory(module: module)?.revisions.last,
                  let document = try? store.object(last.review),
                  let record = ModuleInterfaces.of(reviewDocument: document) else { continue }
            for entry in (record.installs ?? []) + (record.locates ?? []) + (record.notifies ?? []) {
                guard let guid = GuidName.canonicalGUID(entry.guid),
                      let name = GuidName.registryForm(entry.name) else { continue }
                found.append(Recorded(guid: guid, name: name, written: entry.name,
                                      kind: entry.kind == .ppi ? .ppi : .protocol,
                                      module: module, moduleName: names[module], address: entry.address))
            }
        }
        return found
    }

    /// The UEFITool catalogue's `GUID,Name` lines, names in the registry's form.
    public static func catalogue(_ text: String) -> [String: String] {
        var names: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",", maxSplits: 1)
            guard parts.count == 2, let guid = GuidName.canonicalGUID(String(parts[0])),
                  let name = GuidName.registryForm(String(parts[1])), names[guid] == nil else { continue }
            names[guid] = name
        }
        return names
    }

    // MARK: - The seed

    /// Work out the seed and, with `apply`, write it.
    public static func run(store: ContentStore, declared: [Declared], recorded: [Recorded], tag: String,
                           catalogue: [String: String]?, apply: Bool, now: Date = Date()) throws -> GuidSeed {
        var offers: [GuidOffer] = []
        var edk2: [String: Declared] = [:]
        var duplicates: [String: [Declared]] = [:]
        for item in declared {
            if let first = edk2[item.guid] {
                if first.name != item.name { duplicates[item.guid, default: [first]].append(item) }
                continue
            }
            edk2[item.guid] = item
            offers.append(GuidOffer(guid: item.guid, name: item.name, kind: item.kind,
                                    source: .edk2(tag: tag, file: item.file)))
        }
        func place(_ record: Recorded) -> String { "\(record.moduleName ?? String(record.module.hex.prefix(8))) \(record.address)" }
        func named(_ records: [Recorded]) -> [Disagreement.Named] {
            Dictionary(grouping: records, by: \.name).sorted { $0.key < $1.key }.map {
                Disagreement.Named(name: $0.key, places: $0.value.map(place).sorted())
            }
        }
        var conflicts: [Disagreement] = []
        var differ: [Disagreement] = []
        for (guid, records) in Dictionary(grouping: recorded, by: \.guid).sorted(by: { $0.key < $1.key }) {
            let names = Set(records.map(\.name))
            if let declaredName = edk2[guid]?.name {
                // Cited where the record agrees; listed where it does not.
                for record in records where record.name == declaredName {
                    offers.append(GuidOffer(guid: guid, name: record.name, kind: record.kind,
                                            source: .review(module: record.module, address: record.address)))
                }
                if names != [declaredName] {
                    differ.append(Disagreement(guid: guid, registry: declaredName,
                                               names: named(records.filter { $0.name != declaredName })))
                }
                continue
            }
            // A placeholder beside one real name is that name not yet known
            // there: the real name is seeded, as a later offer would add it.
            let real = names.filter { !GuidName.isPlaceholder($0, guid: guid) }
            guard names.count == 1 || real.count == 1 else {
                conflicts.append(Disagreement(guid: guid, registry: nil, names: named(records)))
                continue
            }
            for record in records where names.count == 1 || real.contains(record.name) {
                offers.append(GuidOffer(guid: guid, name: record.name, kind: record.kind,
                                        source: .review(module: record.module, address: record.address)))
            }
        }
        let results = try store.offerGuids(offers, by: "seed", dryRun: !apply, now: now)
        var catalogueDiffers: [Disagreement]?
        if let catalogue {
            var seeded: [String: String] = [:]
            for result in results { seeded[result.guid] = result.entry.name }
            catalogueDiffers = seeded.keys.sorted().compactMap { guid in
                guard let theirs = catalogue[guid], let ours = seeded[guid], theirs != ours else { return nil }
                return Disagreement(guid: guid, registry: ours,
                                    names: [.init(name: theirs, places: ["UEFITool catalogue"])])
            }
        }
        return GuidSeed(
            tag: tag, declared: declared.count, recorded: recorded.count,
            added: results.filter { $0.outcome == .added }.count,
            same: results.filter { $0.outcome == .same }.count,
            additions: results.filter { $0.outcome == .addition }.count,
            applied: apply,
            edk2Duplicates: duplicates.sorted { $0.key < $1.key }.map { guid, items in
                Disagreement(guid: guid, registry: items.first?.name,
                             names: Dictionary(grouping: items, by: \.name).sorted { $0.key < $1.key }.map {
                                 .init(name: $0.key, places: $0.value.map(\.file))
                             })
            },
            recordConflicts: conflicts, recordsDifferFromEDK2: differ, catalogueDiffers: catalogueDiffers)
    }
}
