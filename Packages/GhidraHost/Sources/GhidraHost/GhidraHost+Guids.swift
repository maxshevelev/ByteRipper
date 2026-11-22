import AgentKit
import CodeAnalysis
import Foundation

extension GhidraHost {
    /// `ghidra_guid_add`'s question: a GUID, the name a review gives it, what
    /// it is, and where in a module the code shows that.
    public struct GuidAddRequest: Codable, Equatable, Sendable {
        public var guid: String
        public var name: String
        public var kind: GuidKind
        public var module: SHA256Digest
        public var address: String
        public var note: String?
        public var dryRun: Bool?

        public init(guid: String, name: String, kind: GuidKind, module: SHA256Digest, address: String,
                    note: String? = nil, dryRun: Bool? = nil) {
            self.guid = guid
            self.name = name
            self.kind = kind
            self.module = module
            self.address = address
            self.note = note
            self.dryRun = dryRun
        }

        enum CodingKeys: String, CodingKey {
            case guid, name, kind, module, address, note
            case dryRun = "dry_run"
        }
    }

    /// Offer a review's name for a GUID to the registry. The module must be
    /// one the server knows — its project here, or a revision in the store —
    /// so the place the name rests on can be read. A conflict is an answer,
    /// not an error: it names the registry's name and why it stands.
    public nonisolated func addGuid(_ request: GuidAddRequest, by holder: String) async throws -> Data {
        let known = FileManager.default.fileExists(
            atPath: GhidraProject(root: configuration.projectsRoot, module: request.module).folder.path)
        if !known, try await writer.latestRevision(module: request.module) == nil {
            throw GhidraHostError(.project, "module \(request.module.hex) is not one this server knows: "
                                  + "the name's place has to be in a module that can be read", status: 404)
        }
        let address = request.address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else {
            throw GhidraHostError(.refused, "`address` is where the code shows what the GUID is", status: 400)
        }
        let offer = GuidOffer(guid: request.guid, name: request.name, kind: request.kind,
                              source: .review(module: request.module, address: address), note: request.note)
        let result: GuidOfferResult
        do {
            result = try await writer.offerGuid(offer, by: holder, dryRun: request.dryRun == true)
        } catch let error as CodeAnalysisError {
            throw GhidraHostError(.refused, "\(error)", status: 400)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var answer = try JSONSerialization.jsonObject(with: encoder.encode(result)) as? [String: Any] ?? [:]
        if request.dryRun == true { answer["dry_run"] = true }
        return try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

extension GhidraTools {
    /// A review's name for a GUID, offered to the shared GUID registry.
    static func guidAddTool(_ backend: GhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_guid_add",
            title: "Name a GUID in the GUID registry",
            description: """
                Gives a GUID the registry does not hold its name, read from a module's code: a vendor \
                PPI or protocol, a HOB, a variable's vendor GUID, an event group, a configuration \
                table. `guid_registry` reads what the registry holds; a GUID it names is named so in \
                every review — in `ghidra_set_interfaces`, in a label on its bytes, in a comment. The \
                name is in EDK2's variable form, `g`, the name, `Guid` (`gAmdFabricTopologyPpiGuid`); a \
                PPI's says `Ppi` and a protocol's `Protocol`. `module` and `address` are where the code \
                shows what the GUID is — the install with its descriptor, the call that uses the \
                interface, the HOB's creation — not merely where its bytes lie; a name with no such \
                place is a placeholder, `gUnknownPpi9C98130AGuid`. The answer's `outcome`: `added`; \
                `same` (the registry already names it so: the place is cited); `addition` (a \
                placeholder named properly, or a plain GUID given its kind); `conflict` — the \
                registry names it otherwise and that name stands, `entry` and `why` say which and \
                from where. A conflict you believe is the registry's mistake goes to the person, \
                with the place that shows it: only an administrator renames. `dry_run` answers \
                and writes nothing.
                """,
            inputSchema: AgentSchema.object([
                "guid": AgentSchema.string("The GUID, 8-4-4-4-12: \"9C98130A-8921-45EB-86F3-16041C6BB7AD\"."),
                "name": AgentSchema.string("Its name: \"gAmdFactoryResetPpiGuid\"."),
                "kind": AgentSchema.choice(GuidKind.allCases.map(\.rawValue),
                                           "What it identifies; `guid` when none of the rest."),
                "module": moduleProperty,
                "address": AgentSchema.string("Where in the module the code shows what the GUID is."),
                "note": AgentSchema.string("A sentence on what it is, for the next reader, when the name alone does not say."),
                "dry_run": AgentSchema.boolean("Answer what it would do and write nothing.")
            ], required: ["guid", "name", "kind", "module", "address"])
        ) { call in
            let arguments = call.arguments
            let kindText = try arguments.string("kind")
            guard let kind = GuidKind(rawValue: kindText) else {
                throw AgentToolError("`kind` is one of \(GuidKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let request = GhidraHost.GuidAddRequest(
                guid: try arguments.string("guid"), name: try arguments.string("name"), kind: kind,
                module: try module(arguments), address: try arguments.string("address"),
                note: try arguments.optionalString("note"),
                dryRun: try arguments.bool("dry_run", default: false) ? true : nil)
            return try await answer { try await backend.addGuid(request) }
        }
    }
}

extension GhidraHost {
    /// A name a write gives a GUID is the GUID registry's (`GuidRegistry`): an
    /// interface record's entry, and a label on 16 bytes typed `EFI_GUID`.
    /// Refused otherwise, naming the registry's name, or saying the GUID must
    /// be added first. A store never seeded checks nothing.
    func checkGuidNames(_ path: String, body: Data, port: Int) async throws {
        let registry = try await writer.readGuidRegistry()
        guard !registry.entries.isEmpty else { return }
        if path == "/v1/set/interfaces" {
            // A body the owner will refuse anyway is left to its words.
            guard let record = try? JSONDecoder().decode(ModuleInterfaces.self, from: body) else { return }
            let wrong = record.misnamed(by: registry)
            guard !wrong.isEmpty else { return }
            throw GhidraHostError(.refused, "Every GUID is named as the GUID registry names it (`guid_registry`). "
                + wrong.map { "\($0.list): \($0.name) (\($0.guid)): \($0.why)" }.joined(separator: "; "),
                status: 409)
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let address = object["address"] as? String else { return }
        let type = (object["type"] as? String)?.trimmingCharacters(in: .whitespaces)
        if let type, !type.isEmpty, !Self.isGuidType(type) { return }
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? address
        guard let read = try? await Self.call(port, "GET", "/v1/guid-at?address=\(encoded)", timeout: 30).data,
              let at = try? JSONSerialization.jsonObject(with: read) as? [String: Any],
              let guid = at["guid"] as? String else { return }
        if type == nil || type?.isEmpty == true {
            // Only a name: the datum already there says whether it is a GUID.
            guard let held = at["datum_type"] as? String, Self.isGuidType(held) else { return }
        }
        if let entry = registry.entries[guid] {
            guard entry.name != name else { return }
            throw GhidraHostError(.refused, "The GUID at \(address) is \(guid), which the GUID registry names "
                + "\(entry.name) (`guid_registry`): name it so. A name you believe is the registry's mistake "
                + "goes to the person, with the place that shows it.", status: 409)
        }
        throw GhidraHostError(.refused, "The GUID at \(address) is \(guid), which the GUID registry does not "
            + "hold: add it with `ghidra_guid_add` at the place the code shows what it is, then name it as the "
            + "registry does.", status: 409)
    }

    static func isGuidType(_ type: String) -> Bool {
        let base = type.replacingOccurrences(of: " ", with: "")
        return base == "EFI_GUID" || base == "GUID" || base == "_EFI_GUID" || base == "_GUID"
    }
}

extension GhidraHost {
    /// An interface record as `ghidra_interfaces` answers it: each entry under
    /// the GUID registry's name, and `recorded_name` where the review wrote
    /// another. The record itself is not rewritten.
    nonisolated func namedByGuidRegistry(_ data: Data) async -> Data {
        guard let registry = try? await writer.readGuidRegistry(), !registry.entries.isEmpty,
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        for list in ["installs", "locates", "notifies"] {
            guard let entries = object[list] as? [[String: Any]] else { continue }
            object[list] = entries.map { entry -> [String: Any] in
                guard let guid = entry["guid"] as? String, let name = registry.name(of: guid) else { return entry }
                var entry = entry
                if let written = entry["name"] as? String, written != name { entry["recorded_name"] = written }
                entry["name"] = name
                return entry
            }
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? data
    }
}
