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
              let index = try? await writer.readLibraryIndex(), index.readThrough == true,
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
    private func heldEntry(_ answer: inout [String: Any], index: LibraryIndex) -> (id: String, row: LibraryIndexEntry)? {
        guard let mark = answer["library_entry"] as? [String: Any], let id = mark["id"] as? String else { return nil }
        guard let row = index.entries[id] else {
            answer["library_entry"] = nil
            return nil
        }
        return mark["state"] as? String == "entry" ? (id, row) : nil
    }

    private func rowThroughRegistry(_ row: [String: Any], index: LibraryIndex) async -> [String: Any] {
        var row = row
        guard let held = heldEntry(&row, index: index) else { return row }
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
        guard let held = heldEntry(&answer, index: index),
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
        // A name the project holds and the entry's C does not print: a
        // temporary is not of the description, so a publish did not carry it.
        let names = (answer["locals"] as? [[String: Any]] ?? []).compactMap { local -> String? in
            guard (local["storage"] as? String)?.hasPrefix("HASH") == true, local["named"] as? Bool == true,
                  let name = local["name"] as? String, read.c?.contains(name) != true else { return nil }
            return name
        }
        if !names.isEmpty {
            answer["project_names"] = names
            answer["project_names_note"] = "named in this project, not printed here: the C is the entry's, and a name on "
                + "a temporary reaches it only with a change to the review"
        }
        answer["text"] = "registry"
        if !read.publisherAddresses.isEmpty { answer["publisher_addresses"] = read.publisherAddresses }
        if let object = try? await writer.readObject(held.row.entry),
           let fields = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any] {
            answer["plate"] = fields["plate"]
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
