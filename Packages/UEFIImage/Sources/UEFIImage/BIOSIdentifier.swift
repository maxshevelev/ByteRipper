import Foundation

/// The BIOS ID a firmware file carries: the signature `$IBIOSI$` and then a
/// UTF-16 string, in the file with GUID `C3E36D09-8294-4B97-A857-D5288FE33E28`
/// (`KnownGUIDs.name` calls it "BIOS ID").
///
/// Intel's layout is five parts between dots — board, OEM, major version, minor
/// version and a build date, `yymmddHHMM` — as Apple writes it
/// (`MBA71.88Z.F000.B00.1906140921`). A string that does not split that way is
/// still a BIOS ID, and only its text is given.
public struct BIOSIdentifier: Equatable, Sendable {
    public var text: String
    public var board: String?
    public var oem: String?
    public var majorVersion: String?
    public var minorVersion: String?
    /// `yyyy-mm-dd hh:mm`, from the ten digits at the end.
    public var buildDate: String?

    public static let signature = Array("$IBIOSI$".utf8)

    /// The identifier in a section's bytes, or nil when they do not open with
    /// the signature or hold no string after it.
    public static func read(_ bytes: [UInt8]) -> BIOSIdentifier? {
        guard bytes.starts(with: signature) else { return nil }
        var units: [UInt16] = []
        var index = signature.count
        while index + 1 < bytes.count {
            let unit = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            index += 2
        }
        let text = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var id = BIOSIdentifier(text: text)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 5, parts[4].count == 10, parts[4].allSatisfy(\.isASCII), parts[4].allSatisfy(\.isNumber) {
            id.board = parts[0]
            id.oem = parts[1]
            id.majorVersion = parts[2]
            id.minorVersion = parts[3]
            let d = Array(parts[4])
            id.buildDate = "20\(String(d[0...1]))-\(String(d[2...3]))-\(String(d[4...5])) \(String(d[6...7])):\(String(d[8...9]))"
        }
        return id
    }
}
