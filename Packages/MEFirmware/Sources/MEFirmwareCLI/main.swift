import Foundation
import MEFirmware

/// Developer harness for the MEFirmware module (not part of the library).
///
/// Reads one file and runs the module's async `analyze(region:baseOffset:)`,
/// then prints the regions the parser found and the full `FirmwareAnalysis`
/// result model as JSON — the same Codable "structured output for UI" the app
/// renders, so a parse can be eyeballed without a window.
///
/// Best input is an engine region whose bytes start at `$FPT` (e.g. the ME
/// partition a tool like ByteRipper extracted); partition offsets are then
/// relative to that region. Pass the region's offset inside a larger dump as
/// the second argument and reported offsets are shifted by it.
///
/// Usage:
///   swift run MEFirmwareCLI <image> [baseOffset] [--dat <dir>]
///
/// `--dat` points at a MEAnalyzer clone and reads its databases off disk
/// instead of over the network — which is also the only way to get the decodes
/// that wait for `FileTable.dat` (the MFS Integrity split, the EFS file
/// inventory) out of a one-shot run.
///
/// Examples:
///   swift run MEFirmwareCLI ~/dumps/me_region.bin
///   swift run MEFirmwareCLI ~/dumps/full.bin 0x1000     # region sits at 0x1000
///   swift run MEFirmwareCLI ~/dumps/full.bin --dat ~/Projects/MEAnalyzer
@main
struct MEFirmwareCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { usage() }

        if args[1] == "--bench" {
            guard args.count >= 3 else { usage() }
            await bench(dumps: args[2], dat: args.count >= 4 ? args[3] : nil)
            return
        }

        let path = args[1]
        var baseOffset = 0
        var datDirectory: String? = nil
        var rest = args.dropFirst(2)
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "--dat" {
                guard let directory = rest.first else { fail("--dat needs a directory") }
                rest = rest.dropFirst()
                datDirectory = directory
                continue
            }
            switch parseOffset(argument) {
            case .success(let value): baseOffset = value
            case .failure(let reason): fail("bad baseOffset '\(argument)': \(reason)")
            }
        }

        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            fail("cannot read \(path)")
        }

        var source: any MEADataSource = datDirectory.map { local(dat: $0) }
            ?? MEAGitHubDataRepository()
        let result: FirmwareAnalysis
        do {
            result = try await MEFirmwareAnalyzer(data: source)
                .analyze(region: data, baseOffset: baseOffset,
                         descriptorBytes: data.count >= 0x1000 ? data : nil)
        } catch {
            fail("analysis failed: \(error.localizedDescription)")
        }

        printSummary(result, path: path, size: data.count,
                     bytes: data,
                     fileTable: try? await source.fileTable())
        if !result.issues.isEmpty {
            for issue in result.issues {
                print("issue[\(issue.severity.rawValue)]: \(issue.message)")
            }
        }
        print("--- FirmwareAnalysis JSON ---")
        print(json(result))
    }

    // MARK: - Bench

    /// A data source reading the three databases off disk, so a timing run
    /// measures parsing and not the network. Anything missing is left at the
    /// protocol default, which throws — the legs needing it are then skipped,
    /// so point `--dat` at a MEAnalyzer clone for a representative number.
    private struct LocalData: MEADataSource {
        var db = MEADatabase()
        var huffman: HuffmanDictionaries?
        var table: FileTable?

        func database() async throws -> MEADatabase { db }
        func huffmanDictionaries() async throws -> HuffmanDictionaries {
            guard let huffman else {
                throw MEADataError.malformed(file: "Huffman.dat (not supplied)")
            }
            return huffman
        }
        func fileTable() async throws -> FileTable {
            guard let table else {
                throw MEADataError.malformed(file: "FileTable.dat (not supplied)")
            }
            return table
        }
    }

    /// The databases of a MEAnalyzer clone, as a source. Anything missing is
    /// reported and left throwing, which is what the protocol default does —
    /// the decodes needing it are then the ones a network run would get.
    private static func local(dat: String) -> LocalData {
        var source = LocalData()
        if let text = try? String(contentsOfFile: dat + "/MEA.dat", encoding: .utf8) {
            source.db = MEADatabase.parse(text)
        } else {
            print("warning: no MEA.dat under \(dat) — identification will be empty")
        }
        if let text = try? String(contentsOfFile: dat + "/Huffman.dat", encoding: .utf8) {
            source.huffman = try? HuffmanDictionaries.parse(text)
        }
        if let text = try? String(contentsOfFile: dat + "/FileTable.dat", encoding: .utf8) {
            source.table = try? FileTable.parse(text)
        }
        return source
    }

    /// Time `analyze` over every file in `dumps`, five runs each after a warm-up.
    /// Reports the best run, which is the one least polluted by other load.
    static func bench(dumps: String, dat: String?) async {
        let source = dat.map { local(dat: $0) } ?? LocalData()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dumps)) ?? [])
            .sorted()
            .filter { !$0.hasPrefix(".") }
        guard !files.isEmpty else { fail("no files in \(dumps)") }

        let runs = 5
        for name in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dumps + "/" + name),
                                       options: .mappedIfSafe) else { continue }
            _ = try? await MEFirmwareAnalyzer(data: source).analyze(region: data)
            var best = Double.infinity
            var total = 0.0
            for _ in 0..<runs {
                let start = Date()
                _ = try? await MEFirmwareAnalyzer(data: source).analyze(region: data)
                let elapsed = Date().timeIntervalSince(start)
                best = min(best, elapsed)
                total += elapsed
            }
            let label = name.padding(toLength: 18, withPad: " ", startingAt: 0)
            print(label + String(format: "%7.1f MiB   best %7.1f ms   mean %7.1f ms",
                                 Double(data.count) / 1_048_576,
                                 best * 1000, total / Double(runs) * 1000))
        }
    }

    static func printSummary(_ result: FirmwareAnalysis, path: String, size: Int,
                             bytes: Data, fileTable: FileTable?) {
        let base = result.regions.isEmpty ? 0 : result.regions[0].offset
        _ = base
        print("file:       \(path) (\(size) bytes)")
        print("family:     \(result.family.rawValue)  release: \(result.release.rawValue)  type: \(result.type.rawValue)")
        print("variant:    '\(result.variant)'  version: \(result.version.text)  sku: '\(result.sku)'")
        // The three facts that are ours rather than MEAnalyzer's, on one line
        // each: the harness is how they are checked against dumps whose answers
        // are known (Skills/me-eom-structures/reference/structures.md).
        print("manufacturing: \(result.manufacturingState?.rawValue ?? "-")"
              + (result.manufacturingBasis.map { basis -> String in
                  "  (flag: \(basis.flag.map { $0 ? "1" : "0" } ?? "-")"
                      + ", flexible: \(basis.flexible.map(String.init) ?? "-")"
                      + ", page: \(basis.page?.rawValue ?? "-")"
                      + ", descriptor: \(basis.descriptorOpen.map { $0 ? "open" : "locked" } ?? "-")"
                      + ", live files: \(basis.liveFilesResolved ? "read" : "not read")" + ")"
              } ?? ""))
        print("boot guard:    \(result.bootGuardProfile.map { "\($0.rawValue) - \($0.rawValue)" } ?? "no profile record in this image")")
        print("oem key hash:  \(result.oemPublicKeyHash.map(describeKeyHash) ?? "not read")")
        // What the *file system* says about End of Manufacturing, which the
        // panel's row deliberately does not report — it answers for the next
        // first boot, not for the board the dump came from. A harness reading a
        // dump wants both: `/home/mca/eom` = 1 is that board's own record that
        // Manufacturing was closed, and `eom_config` is the flag as the file
        // system has it. Read from the extents the analysis recorded, so the
        // bytes come from the same places the panel's own reading did.
        for (name, value) in liveEOMRecords(result, bytes: bytes, fileTable: fileTable) {
            print("live record:   \(name) = \(value)")
        }
        // The configuration tab's own content, file by file.
        let configurationMap = MEConfigurationMap.forME(major: result.version.major)
        for file in result.configuration ?? [] {
            let sizes = [file.fitc.map { "FITC \($0.size)" }, file.mfs.map { "MFS \($0.size)" }]
                .compactMap { $0 }.joined(separator: ", ")
            print("configuration: \(file.path)  [\(file.alias): \(sizes)]")
            let layout = configurationMap?.file(at: file.path)
            var names = layout?.settings.map(\.name) ?? []
            for name in ((file.fitc?.settings ?? []) + (file.mfs?.settings ?? [])).map(\.name)
            where !names.contains(name) {
                names.append(name)
            }
            for name in names {
                let setting = layout?.settings.first { $0.name == name }
                func cell(_ page: ConfigurationFile.Page?) -> String {
                    guard let value = page?.settings.first(where: { $0.name == name }) else {
                        return "—"
                    }
                    let number = value.number.map { String($0) } ?? value.bytes ?? "?"
                    let label = setting?.options?[value.number ?? -1].map { " (\($0))" } ?? ""
                    return "\(number)\(label)"
                }
                let auto = setting?.auto == true ? "  [auto]" : ""
                print("    \(name)\(auto): FITC = \(cell(file.fitc))   MFS = \(cell(file.mfs))")
            }
        }
        if let pins = result.gpioPins, !pins.pins.isEmpty {
            // The feature pins the tool built into the image: what each pin
            // is for, where it is, and who owns it.
            print("gpio pins: \(pins.path)  [\(pins.fromImage ? "image" : "MFS")]")
            for pin in pins.pins {
                let feature = pin.feature.map { "  \($0)" } ?? ""
                print("    \(pin.pinName)  \(pin.usage ?? String(pin.usageID))"
                      + "  \(pin.ownership)  \(pin.padMode)\(feature)")
            }
        }
        if result.regions.isEmpty {
            print("FPT regions: none found")
        } else {
            print("FPT regions (\(result.regions.count)):  [id] name  offset  size  flags")
            for region in result.regions {
                let label = region.name.isEmpty ? "<erased>" : region.name
                print(String(format: "  [%2d] %@ 0x%08X 0x%08X 0x%08X",
                             region.id, label as NSString, region.offset, region.size, region.flags))
            }
        }
    }

    /// The live file system's Manufacturing records — `/home/mca/eom`,
    /// `/home/mca/eom_config` and `/home/mca/manuf_lock` — as their first byte,
    /// found by the File IDs `FileTable.dat` gives the volume's files and read
    /// out of the stretches the analysis recorded for each of them.
    static func liveEOMRecords(_ result: FirmwareAnalysis, bytes: Data,
                               fileTable: FileTable?) -> [(String, String)] {
        // An FTBL volume is the only one whose files carry File IDs — an older
        // volume's records are named the other way, and matching its files by
        // ID picks whichever file happens to share the index (CSME 12 answered
        // with a 41-byte "eom" and a 124-byte "manuf_lock" before this gate).
        guard let volume = result.mfsVolume, volume.usesFTBL,
              let table = fileTable else { return [] }
        let resolution = table.resolve(platform: volume.ftblPlatform,
                                       dictionary: volume.ftblDictionary)
        let naming = table.records(namingFileIndices: Set(volume.files.map(\.index)),
                                   platform: resolution.platform,
                                   dictionary: resolution.dictionary)
        let wanted: [String: UInt32] = ["/home/mca/eom": 0x1002_0000,
                                        "/home/mca/eom_config": 0x1001_EE00,
                                        "/home/mca/manuf_lock": 0x1002_0100]
        var out: [(String, String)] = []
        for file in volume.files {
            guard let entry = naming[file.index],
                  let fileID = UInt32(entry.fileID, radix: 16),
                  let name = wanted.first(where: { $0.value == fileID })?.key,
                  let extent = file.extents?.first,
                  extent.lowerBound >= 0, extent.lowerBound < bytes.count else { continue }
            let first = bytes[bytes.startIndex + extent.lowerBound]
            out.append((name, String(format: "0x%02X (%d byte(s) at 0x%X)",
                                     first, file.contentSize ?? file.size, extent.lowerBound)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// The harness's own words for the four findings — the panel's are in
    /// `MEAText`, which the harness does not link.
    static func describeKeyHash(_ value: OEMKeyHash) -> String {
        switch value {
        case .hash(let hex): return hex
        case .allZeros: return "not set (all zeros)"
        case .erased: return "not set (the area is erased)"
        case .unrecognized: return "layout not recognized"
        }
    }

    static func json(_ result: FirmwareAnalysis) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) else {
            return "<encoding failed>"
        }
        return text
    }

    private enum OffsetError: Error, CustomStringConvertible {
        case notHex, notDecimal
        var description: String {
            switch self {
            case .notHex: return "not a hex number"
            case .notDecimal: return "not a decimal number"
            }
        }
    }

    static func parseOffset(_ raw: String) -> Result<Int, Error> {
        if raw.lowercased().hasPrefix("0x") {
            guard let v = Int(raw.dropFirst(2), radix: 16) else { return .failure(OffsetError.notHex) }
            return .success(v)
        }
        guard let v = Int(raw) else { return .failure(OffsetError.notDecimal) }
        return .success(v)
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data("""
        Usage: MEFirmwareCLI <image> [baseOffset] [--dat <dir>]
               MEFirmwareCLI --bench <dumps-dir> [dat-dir]
          <image>      engine region whose bytes start at $FPT (e.g. ME partition)
          [baseOffset] offset of <image> inside a larger dump, decimal or 0x-hex (default 0)
          --dat <dir>  read the databases off a MEAnalyzer clone instead of the
                       network (the only way to get the FileTable.dat decodes)
          --bench      time analyze() over every file in <dumps-dir>, no network;
                       [dat-dir] holds the same databases (a MEAnalyzer clone)

        Examples:
          swift run MEFirmwareCLI ~/dumps/me_region.bin
          swift run MEFirmwareCLI ~/dumps/full.bin 0x1000
          swift run MEFirmwareCLI ~/dumps/full.bin --dat ~/Projects/MEAnalyzer
          swift run -c release MEFirmwareCLI --bench ~/Desktop/ME ~/Projects/MEAnalyzer
        """.utf8))
        exit(2)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
