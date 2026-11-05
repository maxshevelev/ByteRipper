import CodeAnalysis
import Foundation

/// `ghidra_function` and `ghidra_functions` while the registry reads through:
/// a function still at its entry answers the entry's text, so a review reads
/// what every other reader reads. What it has edited since is its own draft and
/// answers as Ghidra holds it. Parameters, locals and their storage stay the
/// project's: they are what a write names them by. Nothing here is stored.
extension GhidraHost {
    private static let entryUnreadable = "the registry entry could not be read: this is the project's text"

    public func throughRegistry(_ data: Data, module: SHA256Digest, call: String) async -> Data {
        let oneFunction = call.hasPrefix("function/") && !call.dropFirst("function/".count).contains("/")
        guard call == "functions" || oneFunction,
              let index = try? await writer.readLibraryIndex(),
              var answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        if oneFunction {
            answer = await functionThroughRegistry(answer, module: module, index: index)
        } else if let rows = answer["functions"] as? [[String: Any]] {
            answer["functions"] = await rows.asyncMap { await rowThroughRegistry($0, index: index) }
        }
        return (try? JSONSerialization.data(withJSONObject: answer, options: .sortedKeys)) ?? data
    }

    /// The entry a function's mark holds it to; a mark on what the registry no
    /// longer holds is no mark, and comes off the answer.
    static func heldEntry(_ answer: inout [String: Any], index: LibraryIndex) -> (id: String, row: LibraryIndexEntry)? {
        guard let mark = answer["library_entry"] as? [String: Any], let id = mark["id"] as? String else { return nil }
        guard let row = index.entries[id] else {
            answer["library_entry"] = nil
            return nil
        }
        guard mark["state"] as? String == "entry" else { return nil }
        // Marked, and its data is not the entry's: another function, as in the plan.
        if let key = answer["body_key"] as? String,
           index.bytesDiffer(id: id, body: key, referenceBytes: answer["reference_bytes"] as? String) {
            var other = mark
            other["state"] = "reference_bytes"
            answer["library_entry"] = other
            return nil
        }
        // No text in the project: the link is all this module holds.
        if answer["stored_copy"] == nil {
            var linked = mark
            linked["state"] = "linked"
            // What it reads is the entry's current version, whatever it was linked at.
            linked["version"] = row.version
            answer["library_entry"] = linked
        }
        return (id, row)
    }

    private func rowThroughRegistry(_ row: [String: Any], index: LibraryIndex) async -> [String: Any] {
        var row = row
        guard let held = Self.heldEntry(&row, index: index) else { return row }
        guard let object = try? await writer.readObject(held.row.entry),
              let entry = LibraryView.Entry(object: object, id: held.id, version: held.row.version) else {
            row["text_unavailable"] = Self.entryUnreadable
            return row
        }
        row["name"] = entry.name
        if let signature = entry.function?.signature ?? entry.signature { row["signature"] = signature }
        row["text"] = "registry"
        return row
    }

    private func functionThroughRegistry(_ answer: [String: Any], module: SHA256Digest,
                                         index: LibraryIndex) async -> [String: Any] {
        var answer = answer
        guard let held = Self.heldEntry(&answer, index: index),
              let text = answer["entry"] as? String, let address = CodeAddress(hex: text) else { return answer }
        guard let read = try? await writer.functionAsRead(module: module, entry: address) else {
            answer["text_unavailable"] = "this store has no reading of the function to render the entry on: "
                + "this is the project's text"
            return answer
        }
        guard read.textFromRegistry else {
            // What the registry gave back by body, the mark's id still held.
            if read.libraryEntry == nil {
                answer["library_entry"] = nil
            } else {
                answer["text_unavailable"] = Self.entryUnreadable
            }
            return answer
        }
        answer["name"] = read.name
        if let signature = read.signature { answer["signature"] = signature }
        if answer["c"] != nil, let c = read.c { answer["c"] = c }
        answer["text"] = "registry"
        if !read.publisherAddresses.isEmpty { answer["publisher_addresses"] = read.publisherAddresses }
        if let object = try? await writer.readObject(held.row.entry),
           let fields = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any] {
            answer["plate"] = fields["plate"]
            // The project keeps no local's name: the C prints the entry's.
            if let locals = fields["locals"] as? [[String: Any]] {
                let held = answer["locals"] as? [[String: Any]] ?? []
                let named = locals.map { local -> [String: Any] in
                    var row = local
                    if let same = held.first(where: { $0["storage"] as? String == local["storage"] as? String }) {
                        row["first_use"] = same["first_use"]
                    }
                    row["named"] = true
                    return row
                }
                // Temporaries are the decompiler's, and the entry holds none.
                answer["locals"] = named + held.filter { row in
                    !locals.contains { $0["storage"] as? String == row["storage"] as? String }
                }
            }
            if let comments = fields["comments"] as? [[String: Any]] {
                answer["comments"] = comments.compactMap { comment -> [String: Any]? in
                    guard let offset = (comment["offset"] as? String).flatMap({ CodeAddress(hex: $0) }) else { return nil }
                    var carried = comment
                    carried["offset"] = nil
                    carried["address"] = CodeAddress(address.value &+ offset.value).description
                    return carried
                }
            }
        }
        return answer
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        out.reserveCapacity(count)
        for element in self { out.append(await transform(element)) }
        return out
    }
}
