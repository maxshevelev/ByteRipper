/// A number in hex, as the app writes one in a message, a readout or an
/// agent's answer: upper-case digits, no padding.
///
/// Built from the integer with `String(_:radix:uppercase:)`, never through a
/// format string: `String(format: "%X", someUInt64)` compiles and reads only 32
/// bits. Padded addresses — the Offset column's eight digits — are the app's
/// own (`bareAddress`), because only the hex view lines numbers up in a column.
extension BinaryInteger {
    /// `0x1FE028`, `0x0`.
    public var hexNumber: String {
        "0x" + bareHexNumber
    }

    /// `1FE028` — `hexNumber` without its prefix, for a copy to the clipboard:
    /// every offset field adds the `0x` on its own.
    public var bareHexNumber: String {
        String(self, radix: 16, uppercase: true)
    }
}
