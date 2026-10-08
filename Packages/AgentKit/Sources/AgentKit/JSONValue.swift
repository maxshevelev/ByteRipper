import Foundation

/// One JSON value, as it crosses the wire in either direction.
///
/// An enum rather than `Any` from `JSONSerialization`, so a handler reading
/// its arguments is reading types the compiler checks, and an integer stays an
/// integer: an offset into a 32 MiB image arrives as `0x1F3000` written in
/// decimal, and a reading that went through `Double` and came back as
/// `2044928.0` would be a reading that cannot be pasted back as an address.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// A number written without a fraction or an exponent that fits in 64
    /// bits. Everything else is a `double`.
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Reading

extension JSONValue {
    /// The member named `key` of an object; nil for a missing member and for a
    /// value that is not an object at all.
    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The integer, and a double that holds one exactly — some encoders write
    /// `16.0` for sixteen, and refusing it would be refusing a correct answer
    /// over spelling.
    public var int64Value: Int64? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            guard value.rounded() == value, abs(value) < 9.2e18 else { return nil }
            return Int64(value)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// An unsigned offset or size. Every one this app deals in fits in an
    /// `Int64`; one that does not is written as a double rather than wrapped.
    public static func uint(_ value: UInt64) -> JSONValue {
        value <= UInt64(Int64.max) ? .int(Int64(value)) : .double(Double(value))
    }

    /// A count or an index.
    public static func count(_ value: Int) -> JSONValue { .int(Int64(value)) }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        // JSON has no NaN and no infinity; a handler that computed one has
        // computed nothing, and null says so without failing the whole answer.
        case .double(let value):
            if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Text

extension JSONValue {
    /// Parses one JSON text. Throws on anything that is not exactly one value.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The value as compact JSON with its keys sorted.
    ///
    /// Sorted because the same answer must be the same bytes: an agent's
    /// client may cache a tool list, and two answers that differ only in the
    /// order a dictionary happened to iterate are two answers to compare.
    /// Compact because every byte of an answer is read by a model. Never holds
    /// a newline — a string's own newlines are escaped — which is what lets
    /// one line carry one message.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a `JSONValue` cannot fail: every case maps onto a JSON
        // value, and the one that would not (a non-finite double) is written
        // as null above.
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var jsonText: String { String(decoding: encoded(), as: UTF8.self) }
}
