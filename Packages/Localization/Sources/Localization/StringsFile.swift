import Foundation

/// Reading a `.strings` file.
///
/// The platform's own format — `"key" = "value";` with `/* */` comments —
/// because a translator's tools already know it, and because the system's own
/// parser handles the escaping rules so nothing here has to. A file that will
/// not parse comes back empty rather than half-read: half a language is worse
/// than none, and the coverage script reports the file long before a user sees
/// it (`Skills/help-coverage`).
enum StringsFile {
    static func parse(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8) else { return [:] }
        let parsed = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        return (parsed as? [String: String]) ?? [:]
    }
}
