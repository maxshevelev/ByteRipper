import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// What the owner says after a change, read back from the program: the C it
/// decompiles, its reasons and its calls. Each test makes its own project from
/// `GHIDRA_TYPE_MODULE`, a 32-bit PEI module, in a temporary folder.
final class GhidraOwnerReadBackTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    private func open(_ image: Data) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerReadBack-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerReadBackTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
    }

    private func image() throws -> Data {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    override func tearDown() async throws {
        if let host, let module { await host.stop(module) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func read(_ path: String) async throws -> [String: Any] {
        let data = try await host.read(module, path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @discardableResult
    private func post(_ path: String, _ object: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: object)
        let data = try await host.write(module, path, body: body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func entries() async throws -> [String] {
        (try await read("/v1/functions")["functions"] as? [[String: Any]] ?? []).compactMap { $0["entry"] as? String }
    }

    private func c(_ entry: String) async throws -> String {
        try await read("/v1/function/\(entry)")["c"] as? String ?? ""
    }

    /// The image with `MOV EAX,target; CALL EAX; RET` over the first function
    /// that starts the usual way, and what it calls: the second such function.
    /// The shape review found in SecCore at 0x9DFBDD0; no module at hand holds
    /// one, and the bytes are all the disassembler sees.
    private func imageWithAnIndirectCall() throws -> (image: Data, stub: UInt32, target: UInt32) {
        var bytes = [UInt8](try image())
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) } }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        let pe = Int(u32(0x3C))
        let base = u32(pe + 0x34)
        let table = pe + 0x18 + u16(pe + 0x14)
        var starts: [UInt32] = []
        var at: [UInt32: Int] = [:]
        for index in 0..<u16(pe + 6) {
            let section = table + index * 40
            let rva = u32(section + 12), raw = Int(u32(section + 20)), size = Int(u32(section + 16))
            guard u32(section + 36) & 0x20 != 0 else { continue }
            for offset in raw..<max(raw, raw + size - 3)
            where bytes[offset] == 0x55 && bytes[offset + 1] == 0x8B && bytes[offset + 2] == 0xEC
                && offset > raw && bytes[offset - 1] == 0xC3 {
                let address = base + rva + UInt32(offset - raw)
                starts.append(address)
                at[address] = offset
            }
        }
        let stub = try XCTUnwrap(starts.first), target = try XCTUnwrap(starts.dropFirst().first)
        let offset = try XCTUnwrap(at[stub])
        let code: [UInt8] = [0xB8] + (0..<4).map { UInt8(truncatingIfNeeded: target >> (8 * UInt32($0))) } + [0xFF, 0xD0, 0xC3]
        bytes.replaceSubrange(offset..<(offset + code.count), with: code)
        return (Data(bytes), stub, target)
    }

    /// `function` lists every call with what it reaches. Analysis gave this one
    /// a reference, as it does not always: the next test has the one it did not.
    func testAnIndirectCallIsListedWithTheAddressItHolds() async throws {
        let made = try imageWithAnIndirectCall()
        try await open(made.image)
        let stub = "0x" + String(made.stub, radix: 16, uppercase: true)
        let target = "0x" + String(made.target, radix: 16, uppercase: true)
        let all = try await entries()
        XCTAssertTrue(all.contains(stub), "the stub is a function of the image")
        let shown = try await read("/v1/disassembly/\(stub)")["instructions"] as? [[String: Any]] ?? []
        print("READBACK xrefs disassembly", shown.prefix(3).map { $0["text"] as? String ?? "" })

        let callees = try await read("/v1/xrefs?from=\(stub)")
        print("READBACK xrefs from stub", callees["references"] ?? "none")
        let held = try await read("/v1/xrefs?to=\(target)")
        print("READBACK xrefs to target", held)
        let calls = try await read("/v1/xrefs?function=\(stub)")
        print("READBACK xrefs function", calls)
        let rows = try XCTUnwrap(calls["calls"] as? [[String: Any]], "\(calls)")
        XCTAssertEqual(rows.count, 1, "\(rows)")
        XCTAssertEqual(rows.first?["text"] as? String, "CALL EAX")
        XCTAssertEqual(rows.first?["kind"] as? String, "indirect")
        XCTAssertEqual(rows.first?["target"] as? String, target)

        // A plain call says so, an indirect one nothing traces says that, and a
        // function that calls nothing answers an empty list.
        var kinds: Set<String> = []
        var leaf = false
        for entry in all {
            let list = try await read("/v1/xrefs?function=\(entry)")["calls"] as? [[String: Any]] ?? []
            leaf = leaf || list.isEmpty
            for row in list {
                let kind = row["kind"] as? String ?? ""
                kinds.insert(kind)
                if kind == "direct" { XCTAssertNotNil(row["target"], "\(row)") }
            }
        }
        XCTAssertTrue(kinds.contains("direct"), "\(kinds)")
        XCTAssertTrue(leaf)
    }

    /// The forms review found in SecCore, on a copy of its kept project:
    /// `MOV EAX,addr; CALL EAX` with no reference at all, and `MOV [EBX],addr`.
    func testConstantsWithNoReferenceAreFoundInACopyOfSecCore() async throws {
        guard ProcessInfo.processInfo.environment["GHIDRA_COPY_SECCORE"] != nil else {
            throw XCTSkip("GHIDRA_COPY_SECCORE is not set")
        }
        let source = GhidraHost.defaultProjectsRoot
        guard let original = GhidraProject.all(in: source).first(where: { (try? $0.state().module.name) == "SecCore" }) else {
            throw XCTSkip("no kept SecCore project to copy")
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerReadBack-\(UUID().uuidString)", isDirectory: true)
        let projects = directory.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let copy = projects.appendingPathComponent(original.module.hex)
        try FileManager.default.copyItem(at: original.folder, to: copy)
        try? FileManager.default.removeItem(at: copy.appendingPathComponent("owner.json"))
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: projects, idle: 120, holder: "GhidraOwnerReadBackTests"),
                          writer: store)
        module = original.module

        let shown = try await read("/v1/disassembly/0x9DFBDD0")["instructions"] as? [[String: Any]] ?? []
        print("READBACK seccore stub", shown.prefix(3).map { $0["text"] as? String ?? "" })
        let refs = try await read("/v1/xrefs?from=0x9DFBDD0")
        print("READBACK seccore from", refs["references"] ?? "none")
        let calls = try await read("/v1/xrefs?function=0x9DFBDD0")["calls"] as? [[String: Any]] ?? []
        print("READBACK seccore calls", calls)
        XCTAssertEqual(calls.first?["text"] as? String, "CALL EAX", "\(calls)")
        XCTAssertEqual(calls.first?["kind"] as? String, "indirect", "\(calls)")
        XCTAssertEqual(calls.first?["target"] as? String, "0x9DFBF90", "\(calls)")
        XCTAssertEqual(calls.first?["held_at"] as? String, "0x9DFBDD3", "\(calls)")
        let target = try await read("/v1/xrefs?to=0x9DFBF90")
        print("READBACK seccore to", target["held_by"] ?? "none")
        XCTAssertTrue((target["held_by"] as? [[String: Any]])?.contains { $0["from"] as? String == "0x9DFBDD3" } == true, "\(target)")
        let tss = try await read("/v1/xrefs?to=0x9DFBDD1")
        print("READBACK seccore tss", tss["held_by"] ?? "none")
        XCTAssertTrue((tss["held_by"] as? [[String: Any]])?.contains { $0["from"] as? String == "0x9DFC170" } == true, "\(tss)")
    }

    /// An address held as an address operand is not named, and now the answer
    /// says it was there rather than answering as if the value were not.
    func testAnEquateSaysWhereTheValueIsHeldAsAnAddress() async throws {
        try await open(try image())
        var seen = false
        for entry in try await entries() {
            let shown = try await read("/v1/disassembly/\(entry)")["instructions"] as? [[String: Any]] ?? []
            for instruction in shown {
                let text = instruction["text"] as? String ?? ""
                guard text.hasPrefix("MOV E"), let at = text.range(of: ",0x") else { continue }
                let value = String(text[text.index(after: at.lowerBound)...])
                guard let number = UInt64(value.dropFirst(2), radix: 16), number >= 0x10000 else { continue }
                let answer = try await post("/v1/set/equate", ["functions": [entry], "value": value, "name": "NAMED_ADDRESS",
                                                               "dry_run": true])
                guard (answer["applied"] as? [Any])?.isEmpty == true else { continue }
                print("READBACK equate", answer)
                let rows = try XCTUnwrap(answer["not_immediate"] as? [[String: Any]], "\(answer)")
                XCTAssertTrue(rows.contains { ($0["text"] as? String) == text }, "\(rows)")
                XCTAssertNotNil(rows.first?["address"])
                XCTAssertNotNil(rows.first?["operand"])
                seen = true
                break
            }
            if seen { break }
        }
        XCTAssertTrue(seen, "no address operand in the module")
    }

    /// A released function does not go on citing an entry as its reason; a
    /// reason of the review's own stays as it is.
    func testAReleaseLeavesNoReasonThatNamesAnEntryAsCurrent() async throws {
        try await open(try image())
        let all = try await entries()
        let released = try XCTUnwrap(all.first), other = try XCTUnwrap(all.dropFirst().first)
        let cited = "library registry entry 1a-test v7"
        try await post("/v1/rename/function", ["address": released, "name": "ReleasedOne", "by": "agent",
                                               "reason": "\(cited) (was Before)"])
        try await post("/v1/set/signature", ["address": released, "signature": "void ReleasedOne(void)",
                                             "by": "agent", "reason": cited])
        try await post("/v1/set/comment", ["address": released, "kind": "plate", "text": "The module's own."])
        try await post("/v1/rename/function", ["address": other, "name": "KeptOne", "by": "agent",
                                               "reason": "the review's own reason"])
        try await post("/v1/set/comment", ["address": other, "kind": "plate", "text": "The module's own."])
        try await post("/v1/library/release", ["items": [
            ["address": released, "id": "1a-test", "version": 7, "entry": [:] as [String: Any]],
            ["address": other, "id": "1a-other", "version": 1, "entry": [:] as [String: Any]]
        ]])
        let read = try await read("/v1/function/\(released)")
        print("READBACK release", read["name_reason"] ?? "none", "|", read["signature_reason"] ?? "none")
        XCTAssertEqual(read["name_reason"] as? String, "no longer a library function: \(cited) (was Before)")
        XCTAssertEqual(read["signature_reason"] as? String, "no longer a library function: \(cited)")
        let kept = try await self.read("/v1/function/\(other)")
        XCTAssertEqual(kept["name_reason"] as? String, "the review's own reason")
    }

    /// Explicit storage no convention gives leaves no convention in the C; the
    /// storage stays, no warning takes its place, and a storage the convention
    /// does give keeps it. A rename after it reaches the C and its callers.
    func testExplicitStorageReadsBackInTheC() async throws {
        try await open(try image())
        var entry = "", caller = ""
        for candidate in try await entries() {
            let references = try await read("/v1/xrefs?to=\(candidate)")["references"] as? [[String: Any]] ?? []
            if let row = references.first(where: { ($0["type"] as? String)?.contains("CALL") == true }),
               let from = row["function"] as? String {
                entry = candidate
                caller = from
                break
            }
        }
        XCTAssertFalse(entry.isEmpty)
        let before = try await c(caller)
        try await post("/v1/set/signature", ["address": entry, "signature": "UINT32 __cdecl Probe(UINT32 First, UINT32 Second)",
                                             "storage": ["ECX:4", "Stack[0x4]:4"], "by": "agent", "reason": "test"])
        let read = try await read("/v1/function/\(entry)")
        let text = read["c"] as? String ?? ""
        let head = text.split(separator: "\n").filter { !$0.hasPrefix("/*") && !$0.isEmpty }.first.map(String.init) ?? ""
        print("READBACK storage head:", head, "| convention:", read["calling_convention"] ?? "none",
              "| warnings:", text.split(separator: "\n").filter { $0.contains("WARNING") })
        print("READBACK storage caller before:", before.split(separator: "\n").filter { $0.contains("(") }.prefix(3))
        XCTAssertFalse(head.contains("__cdecl"), head)
        XCTAssertEqual(read["calling_convention"] as? String, "default")
        XCTAssertFalse(text.contains("Unknown calling convention"), text)
        XCTAssertEqual((read["parameters"] as? [[String: Any]])?.map { $0["storage"] as? String }, ["ECX:4", "Stack[0x4]:4"])
        let after = try await c(caller)
        print("READBACK storage caller after:", after.split(separator: "\n").filter { $0.contains("Probe") }.prefix(3))
        XCTAssertTrue(after.contains("Probe("), after)
        XCTAssertFalse(after.contains("Unknown calling convention"), after)

        try await post("/v1/rename/function", ["address": entry, "name": "ProbeRenamed", "by": "agent", "reason": "test"])
        let renamed = try await c(entry), renamedCaller = try await c(caller)
        print("READBACK rename:", renamed.split(separator: "\n").first { $0.contains("Probe") } ?? "", "|",
              renamedCaller.split(separator: "\n").first { $0.contains("Probe") } ?? "")
        XCTAssertTrue(renamed.contains("ProbeRenamed("))
        XCTAssertFalse(renamed.contains("Probe("))
        XCTAssertTrue(renamedCaller.contains("ProbeRenamed("))

        try await post("/v1/set/signature", ["address": entry, "signature": "UINT32 __cdecl ProbeRenamed(UINT32 First, UINT32 Second)",
                                             "storage": ["Stack[0x4]:4", "Stack[0x8]:4"], "by": "agent", "reason": "test"])
        let fits = try await c(entry)
        print("READBACK storage that fits:", fits.split(separator: "\n").first { $0.contains("ProbeRenamed") } ?? "")
        XCTAssertTrue(fits.contains("__cdecl"), fits)
        let kept = try await self.read("/v1/function/\(entry)")
        XCTAssertEqual(kept["calling_convention"] as? String, "__cdecl")
    }

    /// Not a check: the whole C of the module after the same explicit storage on
    /// the same functions, written to `GHIDRA_C_DUMP`, to compare one build of
    /// the owner with another.
    func testDumpTheModulesCAfterExplicitStorage() async throws {
        guard let dump = ProcessInfo.processInfo.environment["GHIDRA_C_DUMP"] else {
            throw XCTSkip("GHIDRA_C_DUMP is not set")
        }
        try await open(try image())
        let all = try await entries()
        func dumped(_ marked: [String]) async throws -> [String] {
            var lines: [String] = []
            for entry in all {
                let function = try await read("/v1/function/\(entry)")
                lines.append("=== \(entry) \(marked.contains(entry) ? "CHANGED" : "") convention=\(function["calling_convention"] ?? "unread")")
                lines.append(function["c"] as? String ?? "")
            }
            return lines
        }
        // The C before any write: what the decompiler answers with nothing changed.
        try (try await dumped([])).joined(separator: "\n").write(toFile: dump + ".pre", atomically: true, encoding: .utf8)
        var changed: [String] = []
        var unused: [String] = []
        for entry in all where changed.count < 20 {
            let callers = try await read("/v1/xrefs?to=\(entry)")["references"] as? [[String: Any]] ?? []
            guard callers.contains(where: { ($0["type"] as? String)?.contains("CALL") == true }) else {
                unused.append("\(entry) no caller")
                continue
            }
            let function = try await read("/v1/function/\(entry)")
            let parameters = function["parameters"] as? [[String: Any]] ?? []
            let places = parameters.compactMap { $0["storage"] as? String }
            guard places.count >= 2, places.count == parameters.count, places.allSatisfy({ $0.hasPrefix("Stack") && $0.hasSuffix(":4") }),
                  let signature = function["signature"] as? String else {
                unused.append("\(entry) parameters \(places)")
                continue
            }
            let storage = ["ECX:4"] + places.dropFirst()
            do {
                try await post("/v1/set/signature", ["address": entry, "signature": signature, "storage": storage,
                                                     "by": "agent", "reason": "comparing builds"])
                changed.append(entry)
            } catch {
                unused.append("\(entry) refused \(error)")
            }
        }
        var lines = ["changed \(changed)", "unused \(unused)", "project \(directory.path)"]
        lines += try await dumped(changed)
        try lines.joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
    }

    // MARK: - Reproductions on copies of kept projects

    private func openCopy(of name: String) async throws {
        guard ProcessInfo.processInfo.environment["GHIDRA_COPY_KEPT"] != nil else { throw XCTSkip("GHIDRA_COPY_KEPT is not set") }
        let source = GhidraHost.defaultProjectsRoot
        guard let original = GhidraProject.all(in: source).first(where: { (try? $0.state().module.name) == name }) else {
            throw XCTSkip("no kept \(name) project to copy")
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerReadBack-\(UUID().uuidString)", isDirectory: true)
        let projects = directory.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let copy = projects.appendingPathComponent(original.module.hex)
        try FileManager.default.copyItem(at: original.folder, to: copy)
        try? FileManager.default.removeItem(at: copy.appendingPathComponent("owner.json"))
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: projects, idle: 120, holder: "GhidraOwnerReadBackTests"),
                          writer: store)
        module = original.module
    }

    /// A temporary a review left does not make a function unfinished, and is found all the same.
    func testFragmentsAreListedThoughTheyAreNotUnfinished() async throws {
        try await openCopy(of: "CpuIoPei")
        let unfinished = try await read("/v1/functions?filter=unfinished&limit=50")
        let held = try XCTUnwrap((unfinished["summary"] as? [String: Any])?["fragments_only"] as? Int)
        XCTAssertGreaterThan(held, 0, "\(unfinished)")
        let listed = try await read("/v1/functions?filter=fragments&limit=50")
        let rows = try XCTUnwrap(listed["functions"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rows.count, held, "\(listed)")
        for row in rows {
            let leftovers = try XCTUnwrap(row["leftovers"] as? [String: Any])
            let names = try XCTUnwrap(leftovers["fragment_names"] as? [String], "\(row)")
            XCTAssertEqual(names.count, leftovers["fragments"] as? Int, "\(row)")
            XCTAssertFalse(names.isEmpty, "\(row)")
        }
    }

    /// Typing HASH locals: what the listing holds afterwards, to see a split.
    func testReproItem5HashSplit() async throws {
        try await openCopy(of: "SecureFlashPei")
        let entry = "0x9A13622"
        func locals() async throws -> [[String: Any]] {
            try await read("/v1/function/\(entry)")["locals"] as? [[String: Any]] ?? []
        }
        func line(_ row: [String: Any]) -> String { "\(row["name"] ?? "") \(row["storage"] ?? "") \(row["first_use"] ?? "-") \(row["type"] ?? "")" }
        for row in try await locals() where (row["storage"] as? String)?.hasPrefix("HASH") == true {
            let name = try XCTUnwrap(row["name"] as? String)
            let before = try await locals()
            var request: [String: Any] = ["function": entry, "storage": row["storage"] as Any, "type": "int *"]
            if let first = row["first_use"] { request["first_use"] = first }
            do {
                let answer = try await post("/v1/rename/variable", request)
                print("REPRO5", name, "answer", answer["storage"] ?? "-", answer["first_use"] ?? "-", answer["split"] ?? "-")
            } catch { print("REPRO5", name, "refused", error) }
            let after = try await locals()
            print("REPRO5", name, "count", before.count, "->", after.count, "same name", after.filter { $0["name"] as? String == name }.map(line))
            print("REPRO5 now", after.map(line))
        }
    }

    /// Undecoded bytes of a gap are read as code, and the program does not change.
    func testAnUndecodedGapIsReadWithoutChangingTheProgram() async throws {
        try await open(try image())
        let gaps = try await read("/v1/gaps?limit=500")
        let rows = try XCTUnwrap(gaps["gaps"] as? [[String: Any]])
        guard let gap = rows.first(where: { $0["instruction"] as? Bool == false && ($0["defined_data"] as? Bool ?? false) == false && ($0["size"] as? Int ?? 0) > 8 }),
              let start = gap["first_non_padding"] as? String else { throw XCTSkip("no undecoded gap: \(rows.prefix(3))") }
        let before = try await read("/v1/hello")
        let answer = try await read("/v1/disassembly/\(start)?limit=4")
        XCTAssertEqual(answer["undecoded"] as? Bool, true, "\(answer)")
        XCTAssertEqual(answer["gap"] as? String, start, "\(answer)")
        let instructions = try XCTUnwrap(answer["instructions"] as? [[String: Any]])
        print("UNDECODED", start, instructions.map { "\($0["address"] ?? "") \($0["bytes"] ?? "") \($0["text"] ?? "")" }, answer["stopped_by"] ?? "-", answer["next"] ?? "-")
        if answer["stopped_by"] == nil { XCTAssertEqual(instructions.count, 4, "\(answer)") }
        let after = try await read("/v1/hello")
        XCTAssertEqual(before["modification"] as? Int, after["modification"] as? Int)
        XCTAssertEqual(before["writes"] as? Int, after["writes"] as? Int)
    }

    /// A UINT64 on a 32-bit stack sits where the code reads it, and the answer says what moved.
    func testAWideParameterHasNoHoleBeforeIt() async throws {
        try await open(try image())
        let all = try await entries()
        let entry = try XCTUnwrap(all.first)
        func places() async throws -> [String] {
            (try await read("/v1/function/\(entry)")["parameters"] as? [[String: Any]] ?? []).compactMap { $0["storage"] as? String }
        }
        let signature = "EFI_STATUS PciRead(VOID * PeiServices, VOID * This, UINT32 Width, UINT64 Address, VOID * Buffer)"
        let answer = try await post("/v1/set/signature", ["address": entry, "signature": signature])
        let expected = ["Stack[0x4]:4", "Stack[0x8]:4", "Stack[0xc]:4", "Stack[0x10]:8", "Stack[0x18]:4"]
        let now = try await places()
        XCTAssertEqual(now, expected, "\(answer)")
        let moved = try XCTUnwrap(answer["aligned"] as? [[String: Any]], "\(answer)")
        XCTAssertEqual(moved.compactMap { $0["name"] as? String }, ["Address", "Buffer"])
        XCTAssertEqual(moved.first?["convention"] as? String, "Stack[0x14]:8", "\(answer)")
        // Set again, with nothing to move or something else: no storage of the last call stays.
        let narrow = try await post("/v1/set/signature", ["address": entry, "signature": "EFI_STATUS PciRead(UINT32 One, UINT32 Two)"])
        XCTAssertNil(narrow["aligned"], "\(narrow)")
        let narrowed = try await places()
        XCTAssertEqual(narrowed, ["Stack[0x4]:4", "Stack[0x8]:4"], "\(narrow)")
        let wide = try await post("/v1/set/signature", ["address": entry, "signature": "EFI_STATUS PciRead(UINT32 One, UINT64 Two, UINT32 Three)"])
        let widened = try await places()
        XCTAssertEqual(widened, ["Stack[0x4]:4", "Stack[0x8]:8", "Stack[0x10]:4"], "\(wide)")
        // Places the caller gives stay the caller's.
        let given = try await post("/v1/set/signature", ["address": entry, "signature": signature,
            "storage": ["Stack[0x4]:4", "Stack[0x8]:4", "Stack[0xc]:4", "Stack[0x14]:8", "Stack[0x1c]:4"]])
        XCTAssertNil(given["aligned"], "\(given)")
        let kept = try await places()
        XCTAssertEqual(kept[3], "Stack[0x14]:8", "\(given)")
    }

    /// `ghidra_done` on writes that end where they began: the same revision, the same time.
    func testAPublishLeavesTheStateUnmovedWhenNothingStoredChanges() async throws {
        try await open(try image())
        let all = try await entries()
        let entry = try XCTUnwrap(all.first)
        try await post("/v1/set/comment", ["address": entry, "kind": "plate", "text": "One."])
        _ = try await host.publish(module, by: "agent")
        func published() throws -> ProjectState.Published {
            try XCTUnwrap(GhidraProject.all(in: directory.appendingPathComponent("projects")).first?.state().published)
        }
        let first = try published()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try await post("/v1/set/comment", ["address": entry, "kind": "plate", "text": "Two."])
        try await post("/v1/set/comment", ["address": entry, "kind": "plate", "text": "One."])
        _ = try await host.release(module, by: "agent")
        let second = try published()
        XCTAssertEqual(second.at, first.at, "a publish that stored nothing new keeps its time")
        XCTAssertEqual(second.rev, first.rev)
        XCTAssertEqual(second.artifact, first.artifact)
        XCTAssertGreaterThan(second.writes ?? 0, first.writes ?? 0, "holdsUnpublishedWrites compares these")
    }
}
