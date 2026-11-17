/// A number in hex, as the app writes one in a message, a readout or an
/// agent's answer: upper-case digits, `0x1FE028`.
///
/// Built from the integer with `String(_:radix:uppercase:)`, never through a
/// format string: `String(format: "%X", someUInt64)` compiles and reads only 32
/// bits.
///
/// A negative value — a signed field read from a damaged structure, a size
/// that underflowed — is written as its two's complement at its own type's
/// width: `0xFFFFFFFF` for an `Int32` of -1, `0xFB` for an `Int8` of -5,
/// sixteen digits only for a 64-bit type. Never `0x-5`: that is no hex number a
/// reader or a client can parse.
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
        // `words` is the two's complement, least significant first, sign-
        // extended to whole words: write them all, keep the type's own digits.
        let all = words.reversed().map { word in
            let digits = String(word, radix: 16, uppercase: true)
            return String(repeating: "0", count: UInt.bitWidth / 4 - digits.count) + digits
        }.joined()
        return String(all.suffix((bitWidth + 3) / 4))
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

extension Range where Bound: BinaryInteger {
    /// `0x100–0x13F`: a stretch of bytes by its first and its last byte, the
    /// way the status bar, the segment list and every message write one — not
    /// by the first byte after it, which belongs to the next stretch. One
    /// byte is that byte's address alone; an empty range is its position.
    public var hexExtent: String {
        // Compared, not subtracted: a signed range wider than the type's
        // maximum would overflow the subtraction.
        guard lowerBound < upperBound, lowerBound + 1 < upperBound else { return lowerBound.hexNumber }
        return "\(lowerBound.hexNumber)–\((upperBound - 1).hexNumber)"
    }
}
