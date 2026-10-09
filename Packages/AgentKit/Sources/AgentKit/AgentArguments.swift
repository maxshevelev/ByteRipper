import Foundation

/// A tool's arguments, read the way every tool reads them.
///
/// Each reader throws an `AgentToolError` that names the argument and says
/// what was expected, so a handler is a list of reads and never a ladder of
/// `guard`s with a message apiece that drift apart.
public struct AgentArguments: Equatable, Sendable {
    public let values: [String: JSONValue]
    /// The most an answer to this call may be, in bytes — the server's bound
    /// (`AgentServer.Limits.maxAnswerBytes`), so a list can stop short of it
    /// (`AgentPage`) instead of being refused whole. Not an argument the agent
    /// gives: the connection sets it.
    public var answerBound: Int

    public init(_ values: [String: JSONValue] = [:],
                answerBound: Int = AgentServer.Limits().maxAnswerBytes) {
        self.values = values
        self.answerBound = answerBound
    }

    public subscript(name: String) -> JSONValue? {
        guard let value = values[name], !value.isNull else { return nil }
        return value
    }

    public func has(_ name: String) -> Bool { self[name] != nil }

    // MARK: Strings

    public func string(_ name: String) throws -> String {
        guard let value = self[name] else { throw missing(name) }
        guard let string = value.stringValue else { throw wrong(name, "a string") }
        return string
    }

    public func optionalString(_ name: String) throws -> String? {
        has(name) ? try string(name) : nil
    }

    /// One of a fixed set of words.
    public func choice(_ name: String, from choices: [String], default fallback: String? = nil) throws -> String {
        guard has(name) else {
            if let fallback { return fallback }
            throw missing(name)
        }
        let word = try string(name)
        guard choices.contains(word) else {
            throw AgentToolError("Argument `\(name)`: expected one of \(choices.joined(separator: ", ")), got \"\(word)\".")
        }
        return word
    }

    /// A list of strings; empty when the argument was not given.
    public func strings(_ name: String) throws -> [String] {
        guard let value = self[name] else { return [] }
        guard let items = value.arrayValue, items.allSatisfy({ $0.stringValue != nil }) else {
            throw wrong(name, "a list of strings")
        }
        return items.compactMap(\.stringValue)
    }

    // MARK: Numbers

    public func integer(_ name: String) throws -> Int64 {
        guard let value = self[name] else { throw missing(name) }
        guard let number = value.int64Value else { throw wrong(name, "an integer") }
        return number
    }

    public func bool(_ name: String, default fallback: Bool) throws -> Bool {
        guard let value = self[name] else { return fallback }
        guard let flag = value.boolValue else { throw wrong(name, "true or false") }
        return flag
    }

    /// An address or a length in the file.
    ///
    /// Taken as an integer, or as a string in hex (`"0x7F3000"`) or decimal —
    /// a model reads addresses in hex from every tool, the panel and the dump
    /// itself, and would otherwise have to convert each one to decimal before
    /// handing it back, which is where a digit goes missing.
    public func offset(_ name: String) throws -> UInt64 {
        guard let value = self[name] else { throw missing(name) }
        if let number = value.int64Value {
            guard number >= 0 else { throw AgentToolError("Argument `\(name)`: must not be negative.") }
            return UInt64(number)
        }
        if let text = value.stringValue, let number = Self.parseOffset(text) {
            return number
        }
        throw wrong(name, "an integer, or a string such as \"0x7F3000\"")
    }

    public func optionalOffset(_ name: String) throws -> UInt64? {
        has(name) ? try offset(name) : nil
    }

    /// How many items a list may return: the argument, clamped to
    /// `1...maximum`, or `fallback` when it was not given.
    public func limit(_ name: String = "limit", default fallback: Int, maximum: Int) throws -> Int {
        guard has(name) else { return min(fallback, maximum) }
        let asked = try integer(name)
        return Int(max(1, min(Int64(maximum), asked)))
    }

    static func parseOffset(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        let lower = trimmed.lowercased()
        if lower.hasPrefix("0x") { return UInt64(lower.dropFirst(2), radix: 16) }
        return UInt64(lower, radix: 10)
    }

    // MARK: Errors

    private func missing(_ name: String) -> AgentToolError {
        AgentToolError("Argument `\(name)` is required.")
    }

    private func wrong(_ name: String, _ expected: String) -> AgentToolError {
        AgentToolError("Argument `\(name)`: expected \(expected).")
    }
}

/// The few shapes of JSON Schema the tools here are described with.
///
/// Enough to say what an argument is and what it means; validation is the
/// readers' in `AgentArguments`, which give a model a sentence it can act on
/// rather than a schema path.
public enum AgentSchema {
    /// An object with the given properties, and no others.
    public static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var members: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false
        ]
        if !required.isEmpty { members["required"] = .array(required.map { .string($0) }) }
        return .object(members)
    }

    public static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    public static func choice(_ choices: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(choices.map { .string($0) }), "description": .string(description)]
    }

    public static func strings(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    public static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    public static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    /// An address or a length: an integer, or a string in hex or decimal
    /// (`AgentArguments.offset`).
    public static func offset(_ description: String) -> JSONValue {
        ["type": ["integer", "string"], "description": .string(description)]
    }

    /// The `limit` every list takes.
    public static func limit(default fallback: Int, maximum: Int) -> JSONValue {
        ["type": "integer", "minimum": 1, "maximum": .count(maximum),
         "description": .string("The most items one page holds — a ceiling: a page stops sooner when the answer "
             + "would pass the size bound, and says so with `truncated: \"size\"`. Default \(fallback), at most \(maximum).")]
    }

    /// The `after` every paged list takes.
    public static var after: JSONValue {
        string("The `next` of the page before, to go on from where it stopped.")
    }
}
