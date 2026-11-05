import Foundation

/// What a module stores of a function, and it is one of two things.
///
/// A function of the module: its name, signature, C and review. It has no field
/// that says "library": a stored function with text is the module's.
///
/// A link: the registry number and the module's own facts — where the function
/// starts, who calls it, what it calls and the addresses of what its code names
/// (`targets`), and its body's key. Those are the only fields a link has: its ASM,
/// like everything that describes it, is the entry's, and a reader takes it from
/// there (`LibraryView`, `LibraryCode`).
///
/// Every analysis passes through `stored` on its way into a store, so what
/// comes out is one of the two whatever went in. An artifact already in this
/// form comes back byte for byte.
public enum ModuleFormat {
    /// The fields of a link.
    private static let linkFields: Set<String> = [
        "entry", "size", "callers", "callees", "targets", "body", "reference_bytes", "registry"
    ]
    /// Words of an older form, or of the working export of a project: none is stored.
    private static let notStored = ["library_kind", "library_entry", "library_candidate", "copy_free"]

    /// Whether a stored function holds only what a link has.
    static func isLink(_ function: [String: Any]) -> Bool {
        function["registry"] is String && function.keys.allSatisfy(linkFields.contains)
    }

    /// Whether a function of the module holds a word of the older form.
    static func holdsOldWords(_ function: [String: Any]) -> Bool {
        notStored.contains { function[$0] != nil } || function["review_level"] as? String == "library"
    }

    /// A function of the module says how far its review got as the exporter would
    /// of what is stored. A level that came from the older form — "library", which
    /// judged nothing, or none where a link was — and a `full` over a thunk or over
    /// a function with no C cannot stand: a thunk or an external has no body to
    /// review, and a function with no
    /// C has no plate and no step comments a reader could find, since both live
    /// in the C. The exporter's own verdict on a function with C stays.
    static func graded(_ function: inout [String: Any], wasLink: Bool) {
        let level = function["review_level"] as? String
        // An older exporter's function with no level at all is left as it wrote it.
        guard level == "full" || level == "library" || (level == nil && wasLink) else { return }
        if function["external"] as? Bool == true || function["thunk"] as? Bool == true {
            function["review_level"] = "no_body"
            function["review_gaps"] = [String]()
            return
        }
        guard function["c"] == nil else { return }
        let held = Set(function["review_gaps"] as? [String] ?? [])
        let name = function["name"] as? String ?? ""
        let placeholder = function["name_source"] as? String == "DEFAULT" || name.isEmpty || name.hasPrefix("FUN_")
        var gaps: [String] = []
        // In the exporter's order.
        for gap in ["name", "plate", "comments", "params", "locals", "c"] {
            let missing: Bool
            switch gap {
            case "name": missing = placeholder
            case "plate", "comments", "c": missing = true
            default: missing = held.contains(gap)
            }
            if missing { gaps.append(gap) }
        }
        function["review_gaps"] = gaps
        function["review_level"] = placeholder ? "decompiled" : "partial"
    }

    public struct Stored: Sendable {
        public var artifact: Data
        /// The entries of the functions that are links now.
        public var functions: Set<String>
        /// Every instruction address in them, for what a review wrote there.
        public var addresses: Set<String>
        /// The entry each link reads from, by the function's entry address.
        public var entries: [String: String] = [:]
    }

    /// The working export with what a publish's registry decision said of its
    /// functions: each address names the entry it is now, as the project's mark
    /// will say once the revision is stored. A short body has no other way to
    /// say which entry it is, and the mark is written after the revision.
    public static func decided(_ raw: Data, entries: [String: String]) -> Data {
        guard !entries.isEmpty, var object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              var functions = object["functions"] as? [[String: Any]] else { return raw }
        var changed = false
        for position in functions.indices {
            guard let entry = functions[position]["entry"] as? String, let at = LibraryCode.address(entry) else { continue }
            guard let id = entries.first(where: { LibraryCode.address($0.key) == at })?.value else { continue }
            functions[position]["library_entry"] = ["id": id, "state": "entry"]
            changed = true
        }
        guard changed else { return raw }
        object["functions"] = functions
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? raw
    }

    /// The registry number a function is a link to; nil for a function of the
    /// module. A body the registry holds is that entry's, in whichever module.
    private static func registryNumber(_ function: [String: Any], in index: LibraryIndex) -> String? {
        let mark = (function["library_entry"] as? [String: Any])?["id"] as? String ?? function["registry"] as? String
        return LibraryView.entryID(body: function["body"] as? String, mark: mark,
                                   external: function["external"] as? Bool ?? false,
                                   thunk: function["thunk"] as? Bool ?? false,
                                   referenceBytes: function["reference_bytes"] as? String, in: index)
    }

    /// The code a function reads through, when the registry holds one.
    private static func codeDigest(_ number: String, body: Any?, in index: LibraryIndex) -> SHA256Digest? {
        index.code(ofBody: body as? String, entry: number)
    }

    /// The code objects `stored` needs for this artifact.
    public static func codeNeeded(_ raw: Data, index: LibraryIndex) -> [SHA256Digest] {
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let functions = object["functions"] as? [[String: Any]] else { return [] }
        return Array(Set(functions.compactMap { function -> SHA256Digest? in
            guard function["instructions"] != nil, let number = registryNumber(function, in: index) else { return nil }
            return codeDigest(number, body: function["body"], in: index)
        }))
    }

    /// One body this artifact can give the registry the code of.
    public struct Teaching: Sendable {
        public var id: String
        public var variant: LibraryVariant
        public var name: String
        public var kind: String
        public var address: String
        public var code: Data
    }

    /// The bodies the registry holds with no code, which this artifact has. A
    /// function with a call to anything the registry does not hold gives none.
    public static func teachings(_ raw: Data, index: LibraryIndex) -> [Teaching] {
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let functions = object["functions"] as? [[String: Any]] else { return [] }
        var numbers: [UInt64: String] = [:]
        for function in functions {
            if let at = LibraryCode.address(function["entry"]), let number = registryNumber(function, in: index) {
                numbers[at] = number
            }
        }
        let blocks = (object["blocks"] as? [[String: Any]] ?? []).compactMap { block -> ClosedRange<UInt64>? in
            guard let start = LibraryCode.address(block["start"]), let end = LibraryCode.address(block["end"]),
                  start <= end else { return nil }
            return start...end
        }
        var names: [UInt64: String] = [:]
        for symbol in object["symbols"] as? [[String: Any]] ?? [] {
            if let at = LibraryCode.address(symbol["address"]), let name = symbol["name"] as? String { names[at] = name }
        }
        var found: [Teaching] = []
        for function in functions {
            guard function["instructions"] != nil, let text = function["entry"] as? String,
                  let at = LibraryCode.address(text), let number = numbers[at], let row = index.entries[number],
                  let key = function["body"] as? String,
                  let variant = index.variant(ofEntry: number, body: key), variant.code == nil,
                  let code = LibraryCode.build(function: function, number: { place in
                      numbers[place].flatMap { callee in
                          index.entries[callee].flatMap { index.mayCall(row.kind, $0.kind) ? callee : nil }
                      }
                  },
                                               inImage: { place in blocks.contains { $0.contains(place) } },
                                               label: { names[$0] }) else { continue }
            found.append(Teaching(id: number, variant: variant, name: row.name, kind: row.kind, address: text, code: code))
        }
        return found
    }

    public static func stored(_ raw: Data, index: LibraryIndex, code: [SHA256Digest: Data] = [:]) -> Stored {
        let same = Stored(artifact: raw, functions: [], addresses: [])
        guard var object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              var functions = object["functions"] as? [[String: Any]] else { return same }
        // What may be a link: what the registry holds and, for a function still
        // holding its instructions, what its code gives exactly. A function whose
        // callee turns out not to be a link is not one either, so this settles.
        var numbers: [UInt64: String] = [:]
        for function in functions {
            guard let at = LibraryCode.address(function["entry"]),
                  let number = registryNumber(function, in: index) else { continue }
            numbers[at] = number
        }
        var targets: [UInt64: [String: String]] = [:]
        var settled = false
        while !settled {
            settled = true
            for function in functions where function["instructions"] != nil {
                guard let at = LibraryCode.address(function["entry"]), let number = numbers[at] else { continue }
                let bound = codeDigest(number, body: function["body"], in: index)
                    .flatMap { code[$0] }
                    .flatMap { LibraryCode.bind(code: $0, to: function) }
                let calleesHold = bound.map { held in
                    held.allSatisfy { (key: String, place: String) -> Bool in
                        guard let callee = index.entries[key] else { return true }
                        guard let target = LibraryCode.address(place), numbers[target] == key,
                              let caller = index.entries[number] else { return false }
                        return index.mayCall(caller.kind, callee.kind)
                    }
                } ?? false
                if let bound, calleesHold {
                    targets[at] = bound
                } else {
                    numbers[at] = nil
                    settled = false
                }
            }
        }
        var links = Set<String>(), addresses = Set<String>(), entries: [String: String] = [:], changed = false
        for position in functions.indices {
            var function = functions[position]
            guard let entry = function["entry"] as? String, let at = LibraryCode.address(entry) else { continue }
            if let number = numbers[at] {
                for instruction in function["instructions"] as? [[String: Any]] ?? [] {
                    if let place = instruction["address"] as? String { addresses.insert(place) }
                }
                let bound = targets[at]
                function = function.filter { linkFields.contains($0.key) }
                function["registry"] = number
                if let bound, !bound.isEmpty { function["targets"] = bound }
                links.insert(entry)
                entries[entry] = number
            } else {
                let wasLink = function["registry"] != nil || function["library_entry"] != nil || function["copy_free"] != nil
                for key in notStored { function[key] = nil }
                function["registry"] = nil
                if wasLink, function["name"] == nil {
                    // What was a link and is not one: a function no review has read.
                    function["name"] = String(format: "FUN_%08llx", at)
                    function["name_source"] = "DEFAULT"
                    function["review_level"] = nil
                }
                graded(&function, wasLink: wasLink)
                if function["review_level"] as? String == "library" {
                    function["review_level"] = ((function["review_gaps"] as? [Any]) ?? []).isEmpty ? "full" : "partial"
                }
            }
            if !NSDictionary(dictionary: function).isEqual(to: functions[position]) {
                functions[position] = function
                changed = true
            }
        }
        var symbols = object["symbols"] as? [[String: Any]]
        if let held = symbols, !links.isEmpty {
            let kept = held.filter { !links.contains($0["address"] as? String ?? "") }
            if kept.count != held.count {
                symbols = kept
                changed = true
            }
        }
        // What the module's lists say at a link's instructions is the entry's too:
        // the text of an instruction, and the names its constants have there.
        if !addresses.isEmpty {
            for list in ["post_codes", "port_writes", "status_code_calls"] {
                guard var rows = object[list] as? [[String: Any]] else { continue }
                for row in rows.indices where addresses.contains(rows[row]["address"] as? String ?? "") {
                    if rows[row]["text"] != nil || rows[row]["context"] != nil { changed = true }
                    rows[row]["text"] = nil
                    rows[row]["context"] = nil
                }
                object[list] = rows
            }
            if let equates = object["equates"] as? [[String: Any]] {
                var kept: [[String: Any]] = []
                for var equate in equates {
                    guard let uses = equate["references"] as? [Any] else { kept.append(equate); continue }
                    let left = uses.filter { use in
                        let place = (use as? [String: Any])?["address"] as? String ?? (use as? [Any])?.first as? String ?? ""
                        return !addresses.contains(place)
                    }
                    if left.count != uses.count { changed = true }
                    if left.isEmpty, !uses.isEmpty { continue }
                    equate["references"] = left
                    kept.append(equate)
                }
                object["equates"] = kept
            }
        }
        guard changed else { return Stored(artifact: raw, functions: links, addresses: addresses, entries: entries) }
        object["functions"] = functions
        if let symbols { object["symbols"] = symbols }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return same
        }
        return Stored(artifact: data, functions: links, addresses: addresses, entries: entries)
    }

    /// The review document without what it says of the links: their decisions,
    /// and the comments written at their instructions.
    public static func review(_ document: Data, of stored: Stored) -> Data {
        guard !stored.functions.isEmpty,
              var object = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any] else { return document }
        var changed = false
        if var functions = object["functions"] as? [String: Any] {
            for key in stored.functions where functions[key] != nil {
                functions[key] = nil
                changed = true
            }
            object["functions"] = functions
        }
        if let comments = object["comments"] as? [[String: Any]] {
            let kept = comments.filter { !stored.addresses.contains($0["address"] as? String ?? "") }
            if kept.count != comments.count {
                object["comments"] = kept
                changed = true
            }
        }
        guard changed else { return document }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? document
    }
}
