/// A number in hex, as the app writes one in a message, a readout or an
/// agent's answer: upper-case digits, `0x1FE028`.
///
/// Built from the integer with `String(_:radix:uppercase:)`, never through a
/// format string: `String(format: "%X", someUInt64)` compiles and reads only 32
/// bits.
///
/// A negative value — a signed field read from a damaged structure, a size
/// that underflowed — is written as its 64-bit two's complement,
/// `0xFFFFFFFFFFFFFFFB` for -5, the way `%llX` wrote it. Never `0x-5`: that is
/// no hex number a reader or a client can parse.
extension BinaryInteger {
    /// `0x1FE028`, `0x0`.
    public var hexNumber: String {
        "0x" + bareHexNumber
    }

    /// `1FE028` — `hexNumber` without its prefix, for a copy to the clipboard
    /// (every offset field adds the `0x` on its own) or a sentence that writes
    /// the prefix itself.
    public var bareHexNumber: String {
        guard Self.isSigned, self < 0 else { return String(self, radix: 16, uppercase: true) }
        return String(UInt64(truncatingIfNeeded: self), radix: 16, uppercase: true)
    }

    /// `0x0005` for `digits` 4: padded with zeros to a field's width, never
    /// cut — a value wider than the field shows every digit it has.
    public func hexNumber(digits: Int) -> String {
        "0x" + bareHexNumber(digits: digits)
    }

    /// `0005` — `hexNumber(digits:)` without its prefix: the Offset column's
    /// eight digits, a CPUID's platform.
    public func bareHexNumber(digits: Int) -> String {
        let text = bareHexNumber
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
