import CodeAnalysis
import Foundation

/// A library function reaches a reader through the registry and no other way: a
/// test writes `review_level: library` on a row, with `library_kind` and `codes`
/// when it needs them, and this makes it an entry and a link, in a store of its
/// own, and reads the artifact back as the panel gets it.
func throughARegistry(_ json: String) throws -> CodeArtifact {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RegistryFixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ContentStore(root: directory)
    let module = SHA256Digest(data: Data("registry fixture".utf8))
    guard var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          var rows = object["functions"] as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
    for position in rows.indices where rows[position]["review_level"] as? String == "library" {
        let row = rows[position]
        let name = row["name"] as? String ?? ""
        let kind = row["library_kind"] as? String
        var fields: [String: Any] = ["schema": 1, "name": name]
        fields["kind"] = kind
        let entry = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
        func body(_ salt: Int) -> LibraryBody {
            LibraryBody(size: 0x10, full: String(format: "%016x", position + 1), specific: String(format: "%016x", salt))
        }
        let first = body(0)
        // The instructions are the registry's: the link holds none.
        let code = try JSONSerialization.data(withJSONObject: [
            "base": row["entry"] ?? "0x0",
            "instructions": row["instructions"] ?? [] as [[String: Any]]
        ] as [String: Any], options: .sortedKeys)
        _ = try store.putLibraryEntries(module: module, rev: 1, by: "test", proposals: [
            LibraryProposal(body: first, name: name, kind: kind ?? "edk2", address: row["entry"] as? String ?? "", entry: entry)
        ])
        var held = first
        if let codes = row["codes"] as? [String] {
            let variant = body(1)
            _ = try store.putLibraryEntries(module: module, rev: 1, by: "test", proposals: [
                LibraryProposal(body: variant, name: name, kind: kind ?? "edk2", address: row["entry"] as? String ?? "",
                                entry: entry, variantOf: first.key, codes: codes)
            ])
            held = variant
        }
        var teaching = LibraryProposal(body: held, name: name, kind: kind ?? "edk2",
                                       address: row["entry"] as? String ?? "", entry: entry,
                                       basedOn: first.key, teachesBytesOnly: true)
        teaching.code = code
        _ = try store.putLibraryEntries(module: module, rev: 1, by: "test", proposals: [teaching])
        var link: [String: Any] = ["entry": row["entry"] ?? "", "registry": first.key, "body": held.key]
        rows[position] = link
    }
    object["functions"] = rows
    let data = try JSONSerialization.data(withJSONObject: object)
    return store.throughRegistry(try JSONDecoder().decode(CodeArtifact.self, from: data))
}
