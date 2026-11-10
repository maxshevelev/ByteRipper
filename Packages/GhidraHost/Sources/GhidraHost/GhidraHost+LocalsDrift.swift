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

        public init(apply: Bool = false, recipe: String? = nil, functions: [String] = []) {
            self.apply = apply
            self.recipe = recipe
            self.functions = functions
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
}
