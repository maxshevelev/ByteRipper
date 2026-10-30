import Foundation

/// The EDK2 type archives and the GUID table `ApplyUefi.java` names a module
/// with, built once into a cache every owner shares.
///
/// EDK2 comes as the pinned tag's tarball from GitHub, of which only
/// `MdePkg/Include` and the two `.dec` files are unpacked: a Mac without the
/// command line tools has no working `git`, and has `tar`.
public enum UEFITypes {
    public static let edk2Tag = "edk2-stable202608"
    /// What `BuildUefiTypes.java` makes of the headers, the recipe's
    /// `TYPES_REVISION`. 2: `EFI_STATUS` and `EFI_STATUS_CODE_TYPE` are enums.
    public static let typesRevision = 2
    /// The archives' name and the recipe's `types`: the tag and the revision.
    public static let types = "\(edk2Tag)-r\(typesRevision)"
    static let edk2Tarball = URL(string: "https://codeload.github.com/tianocore/edk2/tar.gz/refs/tags/\(edk2Tag)")!
    static let guidsURL = URL(string: "https://raw.githubusercontent.com/LongSoft/UEFITool/new_engine/common/guids.csv")!
    static let decFiles = ["MdePkg/MdePkg.dec", "MdeModulePkg/MdeModulePkg.dec"]

    public static var cacheRoot: URL {
        GhidraHost.defaultProjectsRoot.deletingLastPathComponent()
            .appendingPathComponent("Ghidra", isDirectory: true)
    }

    public struct Paths: Sendable {
        public let root: URL
        public var edk2: URL { root.appendingPathComponent(edk2Tag, isDirectory: true) }
        public var gdtX64: URL { root.appendingPathComponent("uefi_X64-\(types).gdt") }
        public var gdtIa32: URL { root.appendingPathComponent("uefi_Ia32-\(types).gdt") }
        public var guidsCSV: URL { root.appendingPathComponent("guids.csv") }
        public var guidsTSV: URL { root.appendingPathComponent("guids-\(edk2Tag).tsv") }

        public func archive(bits32: Bool) -> URL { bits32 ? gdtIa32 : gdtX64 }
    }

    /// Builds whatever of the cache is missing and returns its paths.
    public static func ensure(install: GhidraInstall, sources: OwnerSources, root: URL = cacheRoot,
                              progress: @Sendable (String) -> Void = { _ in }) async throws -> Paths {
        let paths = Paths(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.edk2.appendingPathComponent("MdePkg/Include").path) {
            progress("Fetching \(edk2Tag)'s MdePkg from GitHub")
            try await fetchEDK2(into: paths.edk2)
        }
        if !(fm.fileExists(atPath: paths.gdtX64.path) && fm.fileExists(atPath: paths.gdtIa32.path)) {
            progress("Building the UEFI type archives in Ghidra (about a minute)")
            try buildArchives(install: install, sources: sources, edk2: paths.edk2, paths: paths)
        }
        if !fm.fileExists(atPath: paths.guidsCSV.path) {
            progress("Downloading the GUID catalogue")
            // EDK2's own names still name the standard GUIDs without it.
            if let (file, response) = try? await URLSession.shared.download(from: guidsURL),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                try? fm.moveItem(at: file, to: paths.guidsCSV)
            }
        }
        if !fm.fileExists(atPath: paths.guidsTSV.path) {
            try writeTable(edk2: paths.edk2, csv: paths.guidsCSV, to: paths.guidsTSV)
        }
        return paths
    }

    static func fetchEDK2(into target: URL) async throws {
        let (file, response) = try await URLSession.shared.download(from: edk2Tarball)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GhidraHostError(.install, "\(edk2Tarball) could not be downloaded; is GitHub reachable?")
        }
        let partial = target.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let log = partial.appendingPathExtension("log")
        defer { try? FileManager.default.removeItem(at: log) }
        let status = try Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            ["-xzf", file.path, "-C", partial.path, "--strip-components", "1",
             "--include", "*/MdePkg/Include/*"] + decFiles.flatMap { ["--include", "*/\($0)"] },
            log: log, timeout: 600)
        guard status == 0,
              FileManager.default.fileExists(atPath: partial.appendingPathComponent("MdePkg/Include").path) else {
            throw GhidraHostError(.install, "unpacking \(edk2Tag) failed: "
                                  + ((try? String(contentsOf: log, encoding: .utf8)) ?? ""))
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
    }

    /// `BuildUefiTypes.java` in a headless run; a run needs a program, and a
    /// few raw bytes imported with the binary loader serve.
    static func buildArchives(install: GhidraInstall, sources: OwnerSources, edk2: URL, paths: Paths) throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghidra-types-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let dummy = work.appendingPathComponent("dummy.bin")
        try Data(count: 16).write(to: dummy)
        let log = work.appendingPathComponent("types.log")
        let status = try Subprocess.run(
            install.analyzeHeadless,
            [work.path, "types", "-import", dummy.path, "-loader", "BinaryLoader",
             "-processor", "x86:LE:64:default", "-noanalysis", "-deleteProject",
             "-scriptPath", sources.scripts.path,
             "-preScript", "BuildUefiTypes.java", edk2.path, work.path],
            log: log, timeout: 1200, environment: install.environment)
        let x64 = work.appendingPathComponent("uefi_X64.gdt")
        let ia32 = work.appendingPathComponent("uefi_Ia32.gdt")
        guard status == 0, FileManager.default.fileExists(atPath: x64.path),
              FileManager.default.fileExists(atPath: ia32.path) else {
            let tail = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(30)
            throw GhidraHostError(.install, "BuildUefiTypes failed (exit \(status)):\n" + tail.joined(separator: "\n"))
        }
        try? FileManager.default.removeItem(at: paths.gdtX64)
        try? FileManager.default.removeItem(at: paths.gdtIa32)
        try FileManager.default.moveItem(at: x64, to: paths.gdtX64)
        try FileManager.default.moveItem(at: ia32, to: paths.gdtIa32)
    }

    // MARK: - The GUID table

    /// EDK2's names first — they are the source's own — then the catalogue's.
    static func writeTable(edk2: URL, csv: URL?, to out: URL) throws {
        var table: [String: String] = [:]
        for dec in decFiles {
            if let text = try? String(contentsOf: edk2.appendingPathComponent(dec), encoding: .utf8) {
                for (key, name) in decGUIDs(text) where table[key] == nil { table[key] = name }
            }
        }
        if let csv, let data = try? Data(contentsOf: csv) {
            for (key, name) in csvGUIDs(String(decoding: data, as: UTF8.self)) where table[key] == nil {
                table[key] = name
            }
        }
        let text = table.keys.sorted().map { "\($0)\t\(table[$0]!)\n" }.joined()
        try Data(text.utf8).write(to: out, options: .atomic)
    }

    /// The 16 bytes of an EFI_GUID as they lie in memory, as upper-case hex.
    static func guidBytes(_ data1: UInt32, _ data2: UInt16, _ data3: UInt16, _ rest: [UInt8]) -> String {
        var raw: [UInt8] = []
        raw += (0..<4).map { UInt8(truncatingIfNeeded: data1 >> (8 * $0)) }
        raw += (0..<2).map { UInt8(truncatingIfNeeded: data2 >> (8 * $0)) }
        raw += (0..<2).map { UInt8(truncatingIfNeeded: data3 >> (8 * $0)) }
        raw += rest
        return raw.map { String(format: "%02X", $0) }.joined()
    }

    /// The first entry of each GUID in a `.dec` file's
    /// `gName = { 0x…, 0x…, 0x…, { 0x…, … } }` lines, in file order.
    static func decGUIDs(_ text: String) -> [(String, String)] {
        let pattern = #"(?m)^\s*(g\w+)\s*=\s*\{\s*0x([0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)\s*,\s*\{([^}]*)\}\s*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var found: [(String, String)] = []
        for match in regex.matches(in: text, range: range) {
            func group(_ index: Int) -> String { String(text[Range(match.range(at: index), in: text)!]) }
            let rest = group(5).components(separatedBy: "0x").dropFirst().compactMap { part -> UInt8? in
                let digits = part.prefix { $0.isHexDigit }
                return digits.isEmpty ? nil : UInt8(truncatingIfNeeded: UInt64(digits, radix: 16) ?? 0)
            }
            guard rest.count == 8,
                  let a = UInt64(group(2), radix: 16), let b = UInt64(group(3), radix: 16),
                  let c = UInt64(group(4), radix: 16) else { continue }
            let key = guidBytes(UInt32(truncatingIfNeeded: a), UInt16(truncatingIfNeeded: b),
                                UInt16(truncatingIfNeeded: c), rest)
            if seen.insert(key).inserted { found.append((key, group(1))) }
        }
        return found
    }

    static func csvGUIDs(_ text: String) -> [(String, String)] {
        var seen = Set<String>()
        var found: [(String, String)] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let parts = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = registryGUID(String(parts[0])),
                  let name = canonicalName(parts.count > 1 ? String(parts[1]) : "") else { continue }
            if seen.insert(key).inserted { found.append((key, name)) }
        }
        return found
    }

    /// `4CF5B200-68B8-4CA5-9EEC-B23E3F50029A` → its memory bytes.
    static func registryGUID(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == 5, zip(parts, lengths).allSatisfy({ $0.count == $1 && $0.allSatisfy(\.isHexDigit) }),
              let a = UInt32(parts[0], radix: 16), let b = UInt16(parts[1], radix: 16),
              let c = UInt16(parts[2], radix: 16) else { return nil }
        let tail = Array(parts[3] + parts[4])
        let rest = stride(from: 0, to: 16, by: 2).compactMap { UInt8(String(tail[$0...$0 + 1]), radix: 16) }
        return guidBytes(a, b, c, rest)
    }

    /// A catalogue name as EDK2 would spell the GUID's variable: `g…Guid`.
    static func canonicalName(_ text: String) -> String? {
        var name = String(text.unicodeScalars.filter {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_"
        })
        guard let first = name.first, first.isLetter || first == "_" else { return nil }
        let chars = Array(name)
        if !(chars[0] == "g" && chars.count > 1 && chars[1].isUppercase) {
            name = "g" + String(chars[0]).uppercased() + String(chars.dropFirst())
        }
        if !name.hasSuffix("Guid") { name += "Guid" }
        return name
    }
}
