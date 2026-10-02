import FirmwareCompression

/// The device overrides a Mac's system-flags store carries: Apple's own list of
/// what to add to, change in and take out of the device tree the firmware builds
/// for this board — its USB and Thunderbolt ports, thermal sensors, fan limits.
///
/// The store's `overrides` variable is a bzip2 stream of text, one rule a line,
/// three tab-separated fields: the action, what it applies to (`()` for every
/// device), and the device or the properties it sets. Nothing documents the
/// format; this reads what a 2010 to 2016 MacBook's store holds, and a line
/// that does not fit is kept whole rather than guessed at.
public struct AppleOverrides: Equatable, Sendable {
    public struct Rule: Equatable, Sendable {
        /// `ADD_DEVICE`, `SET_PROPERTY`, `REMOVE_DEVICE`, … as written.
        public var action: String
        /// The match the rule applies to, without its parentheses; empty when
        /// it applies to every device.
        public var appliesTo: String
        /// The rest of the line: the device an add creates, the properties a
        /// set writes, or the second match of a remove.
        public var detail: String
    }

    public var rules: [Rule]

    /// The variable whose data this reads.
    public static let variableName = "overrides"

    /// How much text a store of at most 64 KiB may unpack to.
    private static let limit: UInt64 = 1 << 22

    /// The text a variable's data unpacks to, or nil when it is not a bzip2
    /// stream — a store of another vendor's, or a damaged one.
    public static func unpacked(_ data: [UInt8]) -> [UInt8]? {
        try? FirmwareDecompression.bzip2(data, limit: limit)
    }

    /// The rules in a variable's data, or nil when it is not a bzip2 stream of
    /// text.
    public static func read(_ data: [UInt8]) -> AppleOverrides? {
        guard let text = unpacked(data) else { return nil }
        let lines = String(decoding: text, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == "\0" })
        let rules = lines.map { line -> Rule in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return Rule(action: String(line), appliesTo: "", detail: "") }
            var target = String(fields[1])
            if target.hasPrefix("("), target.hasSuffix(")") { target = String(target.dropFirst().dropLast()) }
            return Rule(action: String(fields[0]), appliesTo: target, detail: String(fields[2]))
        }
        return rules.isEmpty ? nil : AppleOverrides(rules: rules)
    }
}
