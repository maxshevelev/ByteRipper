/// The "Apple ROM Version" block a Mac's firmware carries as plain text: the
/// model or BIOS ID, the EFI version, who built it and when, the compiler and
/// the UUIDs of the build.
///
/// Older boards keep it as a raw section of a file (`KnownGUIDs.name` calls it
/// "Apple ROM Information"); newer ones leave it in the padding at the start of
/// the BIOS region, so what finds it is the title line, not where it lies. Each line after the title is
/// `  Key:   value` — a key may repeat (`UUID` does), so the entries stay a list.
public struct AppleROMInformation: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: String
    }

    public var entries: [Entry]

    public static let title = "Apple ROM Version"

    /// More than any block seen is long; a bound on what a padding node is
    /// searched for.
    public static let searchLimit: UInt64 = 0x1_0000

    /// The block in `bytes`, wherever it starts in them, or nil when there is no
    /// title line. It ends at the first byte that is not text.
    public static func read(_ bytes: [UInt8]) -> AppleROMInformation? {
        let marker = Array(title.utf8)
        guard bytes.count >= marker.count,
              let start = (0...(bytes.count - marker.count)).first(where: {
                  bytes[$0..<($0 + marker.count)].elementsEqual(marker)
              })
        else { return nil }
        let text = bytes[start...].prefix { $0 == 0x0A || (0x20..<0x7F).contains($0) }
        let lines = String(decoding: text, as: UTF8.self).split(separator: "\n").dropFirst()
        let entries = lines.compactMap { line -> Entry? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingSpaces()
            let value = line[line.index(after: colon)...].trimmingSpaces()
            return key.isEmpty ? nil : Entry(key: key, value: value)
        }
        return entries.isEmpty ? nil : AppleROMInformation(entries: entries)
    }
}

private extension Substring {
    func trimmingSpaces() -> String {
        String(drop(while: { $0 == " " }).reversed().drop(while: { $0 == " " }).reversed())
    }
}
