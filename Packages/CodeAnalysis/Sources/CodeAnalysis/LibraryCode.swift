import Foundation

/// The code of a library function, kept by the registry for each of its bodies.
///
/// A library function is the same ASM in every module, apart from where it stands.
/// So the registry holds the instructions, and a reference out of the function
/// names what it reaches: `entry`, the registry number of the function it calls, or
/// `label`, a datum of the library. A module holds where the function starts and
/// the address each of those has there (`targets`). `instructions` puts the two
/// together, and `bind` makes a function a link only when that gives its real
/// instructions, byte for byte: a function it does not give is another function.
public enum LibraryCode {
    /// The code object of a body as one module has it. `number` is the registry
    /// number of the function at an address, `label` a datum's name in the module
    /// where a review gave one. Nil when the function calls anything the registry
    /// does not hold: such a function is no library function.
    public static func build(function: [String: Any], number: (UInt64) -> String?,
                             inImage: (UInt64) -> Bool, label: (UInt64) -> String?) -> Data? {
        guard let entry = address(function["entry"]),
              let instructions = function["instructions"] as? [[String: Any]], !instructions.isEmpty else { return nil }
        let inside = Set(instructions.compactMap { address($0["address"]) })
        var labels: [UInt64: String] = [:]
        var built: [[String: Any]] = []
        for instruction in instructions {
            guard let at = address(instruction["address"]) else { return nil }
            var kept = instruction
            kept["offset"] = nil
            let bytes = byteList(instruction["bytes"])
            var references: [[String: Any]] = []
            for reference in instruction["references"] as? [[String: Any]] ?? [] {
                var row = reference
                guard let to = address(reference["to"]) else { continue }
                if !inside.contains(to) {
                    if isFlow(reference) {
                        guard let callee = number(to) else { return nil }
                        row["entry"] = callee
                    } else if inImage(to), encoded(to, at: at, in: bytes) != nil {
                        let name = labels[to] ?? label(to) ?? String(format: "data_%llX", at &- entry)
                        labels[to] = name
                        row["label"] = name
                    }
                }
                references.append(row)
            }
            kept["references"] = references
            built.append(kept)
        }
        return try? JSONSerialization.data(withJSONObject: ["base": hex(entry), "instructions": built],
                                           options: [.sortedKeys])
    }

    /// What a module has to hold for `function` to read through `code`; nil when
    /// the code does not give that function's instructions.
    public static func bind(code: Data, to function: [String: Any]) -> [String: String]? {
        guard let source = read(code), let entry = address(function["entry"]),
              let real = function["instructions"] as? [[String: Any]],
              real.count == source.instructions.count else { return nil }
        var targets: [String: String] = [:]
        for (theirs, ours) in zip(source.instructions, real) {
            let mine = Dictionary(grouping: ours["references"] as? [[String: Any]] ?? [], by: { $0["type"] as? String ?? "" })
            var used: [String: Int] = [:]
            for reference in theirs["references"] as? [[String: Any]] ?? [] {
                let type = reference["type"] as? String ?? ""
                let position = used[type, default: 0]
                used[type] = position + 1
                guard let key = (reference["entry"] ?? reference["label"]) as? String else { continue }
                guard let row = mine[type], position < row.count, let to = address(row[position]["to"]) else { return nil }
                if let held = targets[key], held != hex(to) { return nil }
                targets[key] = hex(to)
            }
        }
        guard let rebuilt = instructions(code: code, entry: entry, targets: targets) else { return nil }
        for (made, ours) in zip(rebuilt, real) {
            guard address(made["address"]) == address(ours["address"]),
                  byteList(made["bytes"]) == byteList(ours["bytes"]),
                  made["text"] as? String == ours["text"] as? String,
                  made["mnemonic"] as? String == ours["mnemonic"] as? String else { return nil }
        }
        return targets
    }

    /// The function's instructions in a module: the registry's code at the
    /// module's addresses. Nil when a target it needs is not given.
    public static func instructions(code: Data, entry: UInt64, targets: [String: String]) -> [[String: Any]]? {
        guard let source = read(code) else { return nil }
        let shift = entry &- source.base
        let inside = Set(source.instructions.compactMap { address($0["address"]) })
        var out: [[String: Any]] = []
        out.reserveCapacity(source.instructions.count)
        for instruction in source.instructions {
            guard let was = address(instruction["address"]) else { return nil }
            let at = was &+ shift
            var bytes = byteList(instruction["bytes"])
            var moved: [UInt64: UInt64] = [:]
            var references: [[String: Any]] = []
            for reference in instruction["references"] as? [[String: Any]] ?? [] {
                guard let to = address(reference["to"]) else { continue }
                var now = to
                if let key = (reference["entry"] ?? reference["label"]) as? String {
                    guard let held = targets[key].flatMap({ address($0) }) else { return nil }
                    now = held
                } else if inside.contains(to) {
                    now = to &+ shift
                }
                moved[to] = now
                var row = reference
                row["to"] = hex(now)
                row["entry"] = nil
                row["label"] = nil
                references.append(row)
                let keyed = reference["entry"] != nil || reference["label"] != nil
                if keyed || inside.contains(to) {
                    patch(&bytes, from: to, was: was, to: now, at: at, flow: isFlow(reference), inside: inside.contains(to))
                }
            }
            var row = instruction
            row["address"] = hex(at)
            row["bytes"] = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            row["text"] = rewritten(instruction["text"] as? String ?? "", moved)
            row["references"] = references
            out.append(row)
        }
        return out
    }

    /// The code as the registry shows it: by place in the function, and what it
    /// calls by the name it has now.
    public static func listing(code: Data, name: (String) -> String?) -> [[String: Any]]? {
        guard let source = read(code) else { return nil }
        return source.instructions.compactMap { instruction -> [String: Any]? in
            guard let at = address(instruction["address"]) else { return nil }
            var said = instruction["text"] as? String ?? ""
            var references: [[String: Any]] = []
            for reference in instruction["references"] as? [[String: Any]] ?? [] {
                var row = reference
                if let to = address(reference["to"]) {
                    var word: String?
                    if let id = reference["entry"] as? String { word = name(id) ?? id }
                    if let label = reference["label"] as? String { word = label }
                    if let word {
                        said = replacing(said, to, with: word)
                        row["to"] = nil
                    }
                }
                references.append(row)
            }
            var row = instruction
            row["address"] = nil
            row["offset"] = String(format: "0x%llX", at &- source.base)
            row["text"] = said
            row["references"] = references
            return row
        }
    }

    // MARK: - Helpers

    private static func read(_ code: Data) -> (base: UInt64, instructions: [[String: Any]])? {
        guard let object = (try? JSONSerialization.jsonObject(with: code)) as? [String: Any],
              let base = address(object["base"]),
              let instructions = object["instructions"] as? [[String: Any]] else { return nil }
        return (base, instructions)
    }

    private static func isFlow(_ reference: [String: Any]) -> Bool {
        let type = reference["type"] as? String ?? ""
        return type.contains("CALL") || type.contains("JUMP")
    }

    static func address(_ value: Any?) -> UInt64? {
        (value as? String).flatMap { CodeAddress(hex: $0)?.value }
    }

    private static func hex(_ value: UInt64) -> String { String(format: "0x%llX", value) }

    private static func byteList(_ value: Any?) -> [UInt8] {
        ((value as? String) ?? "").split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    private static func littleEndian(_ value: UInt64, _ width: Int) -> [UInt8] {
        (0..<width).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
    }

    private static func position(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        return (0...(bytes.count - pattern.count)).first { Array(bytes[$0..<($0 + pattern.count)]) == pattern }
    }

    /// Where an instruction's bytes hold `target`: its absolute value, or its
    /// distance from the instruction's end.
    private static func encoded(_ target: UInt64, at: UInt64, in bytes: [UInt8]) -> Int? {
        position(of: littleEndian(target, 4), in: bytes)
            ?? position(of: littleEndian(target &- (at &+ UInt64(bytes.count)), 4), in: bytes)
    }

    private static func patch(_ bytes: inout [UInt8], from old: UInt64, was: UInt64, to new: UInt64, at: UInt64,
                              flow: Bool, inside: Bool) {
        let end = UInt64(bytes.count)
        let oldNear = littleEndian(old &- (was &+ end), 4), newNear = littleEndian(new &- (at &+ end), 4)
        let oldFar = littleEndian(old, 4), newFar = littleEndian(new, 4)
        let tries = flow ? [(oldNear, newNear), (oldFar, newFar)] : [(oldFar, newFar), (oldNear, newNear)]
        for (from, into) in tries {
            if let place = position(of: from, in: bytes) {
                bytes.replaceSubrange(place..<(place + 4), with: into)
                return
            }
        }
    }

    private static let token = try? NSRegularExpression(pattern: "0x[0-9a-fA-F]+")

    private static func rewritten(_ text: String, _ moved: [UInt64: UInt64]) -> String {
        guard let token else { return text }
        var out = text
        let whole = NSRange(text.startIndex..., in: text)
        for match in token.matches(in: text, range: whole).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let found = String(out[range])
            guard let value = address(found), let now = moved[value] else { continue }
            let digits = found.dropFirst(2)
            let written = digits.hasPrefix("0")
                ? "0x" + String(format: "%0\(digits.count)llx", now) : String(format: "0x%llx", now)
            out.replaceSubrange(range, with: written)
        }
        return out
    }

    private static func replacing(_ text: String, _ value: UInt64, with word: String) -> String {
        guard let token else { return text }
        var out = text
        let whole = NSRange(text.startIndex..., in: text)
        for match in token.matches(in: text, range: whole).reversed() {
            guard let range = Range(match.range, in: out), address(String(out[range])) == value else { continue }
            out.replaceSubrange(range, with: word)
        }
        return out
    }
}

extension LibraryIndex {
    /// The body of entry `id` a function with body `key` reads through, whether
    /// the entry holds it or it was taken out. A short body's key keeps the
    /// entry's own identity, not the function's: its shape, the bytes, says it.
    func variant(ofEntry id: String, body key: String?) -> LibraryVariant? {
        guard let key else { return nil }
        let held = entries[id]?.variants ?? (takenOut ?? [:]).values.filter { $0.id == id }.map(\.variant)
        if let exact = held.first(where: { $0.body.key == key }) { return exact }
        guard LibraryBody.isShort(key: key) else { return nil }
        let shape = key.split(separator: "-").prefix(2).joined(separator: "-")
        return held.first { $0.body.shape == shape }
    }

    /// What was taken out, for a link still naming it: a short body by the number.
    func takenOutRecord(of function: CodeArtifact.Function) -> LibraryTakenOut? {
        function.body.flatMap { takenOut?[$0] } ?? function.registryNumber.flatMap { takenOut?[$0] }
    }

    /// The code the registry keeps for a body.
    func code(ofBody body: String?, entry id: String) -> SHA256Digest? {
        variant(ofEntry: id, body: body)?.code
    }
}
