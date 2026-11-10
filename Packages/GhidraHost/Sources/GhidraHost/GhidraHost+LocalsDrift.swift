import CodeAnalysis
import Foundation

/// The named locals a review document recorded, against the program as it
/// decompiles now (issue 4a9a4484). A local's name is bound to its storage,
/// and anything that lays a frame out again — revision 3's EFIAPI convention
/// on IA32, a callee's prototype, a type's size — leaves the name on the old
/// slot while the value moved. A first use, an instruction address, does not
/// move: the owner finds by it where each name belongs now, and with `apply`,
/// under the module's lease, puts it there. Nothing is published.
extension GhidraHost {
    public struct LocalsDriftRequest: Sendable, Equatable {
        /// Set the moved names on their locals; otherwise only say what moved.
        public var apply: Bool
        /// The recipe whose last publish is the reference; by default the
        /// module's recipe as it was before revision 3 of the types.
        public var recipe: String?
        /// Only these function entries; all of the document's when empty.
        public var functions: [String]
        /// Compare the registry's entries with this module's functions linked
        /// to them, instead of the review document: read only.
        public var registry: Bool

        public init(apply: Bool = false, recipe: String? = nil, functions: [String] = [], registry: Bool = false) {
            self.apply = apply
            self.recipe = recipe
            self.functions = functions
            self.registry = registry
        }
    }

    /// `recipe` as it read with the types before revision 3: `-types3-`
    /// becomes `-types2-`. Unchanged for a recipe that names no revision.
    static func recipeBeforeEFIAPI(_ recipe: String) -> String {
        guard let range = recipe.range(of: #"-types\d+-"#, options: .regularExpression) else { return recipe }
        return recipe.replacingCharacters(in: range, with: "-types2-")
    }

    public func driftOfLocals(_ module: SHA256Digest, _ request: LocalsDriftRequest,
                              holder: String?) async throws -> Data {
        if request.registry { return try await driftOfRegistryEntries(module, request, holder: holder) }
        let state = try project(module).state()
        guard let published = state.published else {
            throw GhidraHostError(.refused, "the module was never published: there is no review document to compare with",
                                  status: 409)
        }
        let recipe = request.recipe ?? Self.recipeBeforeEFIAPI(published.recipe)
        guard let manifest = try await writer.storedAnalysis(module: module, recipe: recipe) else {
            throw GhidraHostError(.refused, "no analysis of this module was published as \(recipe)", status: 404)
        }
        guard let review = manifest.reading?.review else {
            throw GhidraHostError(.refused, "the analysis published as \(recipe) records no review document", status: 404)
        }
        let document = try JSONSerialization.jsonObject(with: try await writer.readObject(review)) as? [String: Any] ?? [:]
        let functions = document["functions"] as? [String: Any] ?? [:]
        var body: [String: Any] = ["functions": functions]
        if !request.functions.isEmpty { body["only"] = request.functions }
        let data = try JSONSerialization.data(withJSONObject: body)
        let raw = request.apply
            ? try await write(module, "/v1/locals/remap", body: data, holder: holder)
            : try await preview(module, "/v1/locals/drift", body: data, holder: holder)
        var answer = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
        var baseline: [String: Any] = ["recipe": recipe, "review": review.hex]
        if let rev = manifest.reading?.rev { baseline["rev"] = rev }
        answer["baseline"] = baseline
        return try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
    }

    /// Issue 24c094eb: each registry entry's locals against the functions of
    /// this module linked to it. An entry records a local's storage and its
    /// first use as an offset from the function's entry; a frame laid out
    /// again keeps the first use and may move the storage, and an entry
    /// recorded before it then names a slot its linkers no longer use. The
    /// owner places each entry's locals at each linked function and answers,
    /// per local, `intact` (that storage starts there), `moved` (another
    /// storage does: `now`), `lost` or `ambiguous`. A linked function keeps
    /// its module's names, so names are not compared. Read only: an entry is
    /// put right by a registry proposal, not here.
    func driftOfRegistryEntries(_ module: SHA256Digest, _ request: LocalsDriftRequest,
                                holder: String?) async throws -> Data {
        guard !request.apply else {
            throw GhidraHostError(.refused, "a registry entry is put right by a registry proposal: `registry` is read only",
                                  status: 400)
        }
        let index = try await writer.readLibraryIndex()
        var entries: [String: Any] = [:]
        for (id, held) in index.entries {
            let object = try JSONSerialization.jsonObject(with: try await writer.readObject(held.entry)) as? [String: Any] ?? [:]
            guard let locals = object["locals"] as? [[String: Any]], !locals.isEmpty else { continue }
            entries[id] = ["version": held.version, "locals": locals] as [String: Any]
        }
        let body = try JSONSerialization.data(withJSONObject: ["entries": entries])
        let raw = try await preview(module, "/v1/locals/entries", body: body, holder: holder)
        var answer = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
        if !request.functions.isEmpty, let functions = answer["functions"] as? [[String: Any]] {
            let wanted = Set(request.functions.map { $0.lowercased() })
            answer["functions"] = functions.filter { wanted.contains(($0["entry"] as? String ?? "").lowercased()) }
        }
        answer["registry"] = ["entries_with_locals": entries.count] as [String: Any]
        return try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
    }
}
