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
    private var store: ContentStore!

    private func open(_ image: Data) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerReadBack-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        self.store = store
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerReadBackTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
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
        // These tests are about what a write leaves for a done, not about who
        // may write: the module is in work for each write, as a holder keeps it.
        try await host.take(module)
        let data = try await host.write(module, path, body: body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A done by the holder, who has the module in work.
    private func release() async throws -> GhidraHost.Publication? {
        try await host.take(module)
        return try await host.release(module, by: "agent")
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
        // Both need a module with direct calls and a leaf, which a small one
        // (DebugMaskPei: a handful of functions, every call through a table)
        // does not have: that is the module, not the owner.
        guard kinds.contains("direct"), leaf else {
            throw XCTSkip("GHIDRA_TYPE_MODULE has no direct call or no leaf function: \(kinds), leaf \(leaf)")
        }
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
        // A small module (DebugMaskPei) holds no `MOV reg,address` at all: the
        // case cannot be tried there.
        guard seen else { throw XCTSkip("GHIDRA_TYPE_MODULE holds no MOV of an address into a register") }
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
    /// stack-params-1: on 32-bit x86 an 8-byte parameter takes the next 4-byte
    /// stack slot, as cdecl and stdcall put it — stock Ghidra wastes a slot to
    /// align it to 8 and moves it and every later parameter by 4 (issue
    /// 24ca998e: FatPei's `Open` printed `0x2000000000` for `1, 0x20`). The
    /// owner packs a signature's own parameters itself (`aligned`); with the
    /// patch the convention already puts them there, so nothing is moved and
    /// the storage stays the convention's. The decompiler's half — a call
    /// through a function pointer — is checked on FatPei by hand.
    func testAnEightByteParameterTakesTheNextStackSlot() async throws {
        let image = try image()
        let install = try GhidraInstall.find()
        // GHIDRA_STOCK_DECOMPILER=check runs it on a stock decompiler, to see it fail there.
        guard install.decompilerPatch != nil || ProcessInfo.processInfo.environment["GHIDRA_STOCK_DECOMPILER"] == "check" else {
            throw XCTSkip("\(install.home.path) has no decompiler patch (Scripts/make-patched-ghidra.sh)")
        }
        try await open(image)
        let hello = try await read("/v1/hello")
        XCTAssertEqual(hello["decompiler_patch"] as? String, install.decompilerPatch)
        let first = try await entries().first
        let entry = try XCTUnwrap(first)
        let answer = try await post("/v1/set/signature", ["address": entry,
                                             "signature": "UINT32 __cdecl Probe(UINT32 First, UINT64 Second, UINT32 Third)",
                                             "by": "agent", "reason": "test"])
        XCTAssertNil(answer["aligned"], "the convention left a hole the owner had to close: \(answer["aligned"] ?? "")")
        XCTAssertEqual(answer["calling_convention"] as? String, "__cdecl")
        let read = try await read("/v1/function/\(entry)")
        XCTAssertEqual((read["parameters"] as? [[String: Any]])?.map { $0["storage"] as? String },
                       ["Stack[0x4]:4", "Stack[0x8]:8", "Stack[0x10]:4"])
    }

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

    /// A pointer that is zero reads `NULL` in the C of a read and of a publish,
    /// which agree, and the artifact still calls it a constant. A zero that is
    /// no pointer stays a number.
    /// A function typedef for a name the program holds as a function
    /// definition — the one a field's pointer was named into — redefines that
    /// definition. No second, self-naming typedef at the root shadows it.
    func testAFunctionTypedefRedefinesTheDefinitionItNames() async throws {
        try await open(try image())
        let made = try await post("/v1/type", ["c": "typedef struct _PROBE_PPI { EFI_STATUS (*Run)(void *Arg0); } PROBE_PPI;"])
        XCTAssertTrue((made["c"] as? String ?? "").contains("PROBE_PPI_Run * Run"), "\(made)")
        let redefined = try await post("/v1/type", ["c": "typedef EFI_STATUS PROBE_PPI_Run(void *Arg0, void *Arg1);"])
        let said = redefined["c"] as? String ?? ""
        XCTAssertFalse(said.contains("typedef PROBE_PPI_Run PROBE_PPI_Run"), "\(redefined)")
        XCTAssertTrue(said.contains("Arg1"), "the definition itself, with its new parameters: \(redefined)")
        let definition = try await read("/v1/type?name=PROBE_PPI_Run")
        let program = try XCTUnwrap(definition["program"] as? [String: Any], "\(definition)")
        XCTAssertTrue((program["c"] as? String ?? "").contains("Arg1"), "\(definition)")
        XCTAssertFalse((program["c"] as? String ?? "").contains("typedef PROBE_PPI_Run PROBE_PPI_Run"), "\(definition)")
        // A structure defined afterwards binds its field to the definition —
        // the new signature, under the field's own name — not to a shadow.
        let again = try await post("/v1/type", ["c": "typedef struct _PROBE2_PPI { PROBE_PPI_Run *Run; } PROBE2_PPI;"])
        XCTAssertTrue((again["c"] as? String ?? "").contains("PROBE2_PPI_Run * Run"), "\(again)")
        let bound = try await read("/v1/type?name=PROBE2_PPI_Run")
        XCTAssertTrue(((bound["program"] as? [String: Any])?["c"] as? String ?? "").contains("Arg1"), "\(bound)")
        let field = try await read("/v1/type?name=PROBE_PPI")
        XCTAssertFalse("\(field)".contains("BAD"), "\(field)")
        _ = try await release()
    }

    /// Issue 9a4b1fa7: a prototype that names a structure only as
    /// `struct _NAME *` takes the structure the program holds; it is not
    /// replaced by the empty one the parser makes of the reference.
    func testAStructureAPrototypeOnlyPointsAtKeepsItsFields() async throws {
        try await open(try image())
        _ = try await post("/v1/type", ["c": """
            typedef struct _PROBE_LOG_PPI { EFI_STATUS (*AddLog)(struct _PROBE_LOG_PPI *This, UINT32 Event); \
            UINT32 Count; UINT32 Mode; UINT32 Last; } PROBE_LOG_PPI;
            """])
        let before = try await read("/v1/type?name=PROBE_LOG_PPI")
        XCTAssertEqual((before["program"] as? [String: Any])?["size"] as? Int, 0x10, "\(before)")
        let redefined = try await post("/v1/type", ["c": """
            typedef EFI_STATUS PROBE_LOG_PPI_AddLog(struct _PROBE_LOG_PPI *This, UINT32 Event, UINT32 Data);
            """])
        XCTAssertTrue((redefined["c"] as? String ?? "").contains("Data"), "\(redefined)")
        for name in ["PROBE_LOG_PPI", "_PROBE_LOG_PPI"] {
            let after = try await read("/v1/type?name=\(name)")
            let program = try XCTUnwrap(after["program"] as? [String: Any], "\(after)")
            XCTAssertEqual(program["size"] as? Int, 0x10, "\(name): \(after)")
            XCTAssertTrue((program["c"] as? String ?? "").contains("Count"), "\(name): \(after)")
        }
        _ = try await release()
    }

    /// Issue 85624707: a structure defined again with an inline member of
    /// another prototype gives the member's named signature type that
    /// prototype — it was kept with the old one — and the parser's `_func_N`
    /// for the member is not left in the program.
    func testAMemberDeclaredAgainTakesItsNewPrototype() async throws {
        try await open(try image())
        func parserTypes() async throws -> Int {
            let listed = try await read("/v1/types?contains=_func_&kind=function&limit=5000")
            return (listed["types"] as? [[String: Any]] ?? []).filter { ($0["source"] as? String) == "program" }.count
        }
        let before = try await parserTypes()
        _ = try await post("/v1/type", ["c": """
            typedef struct _PROBE_ERR_PPI { void (*AddLog)(struct _PROBE_ERR_PPI *This, UINT32 Event); \
            UINT32 Count; } PROBE_ERR_PPI;
            """])
        let first = try await read("/v1/type?name=PROBE_ERR_PPI_AddLog")
        XCTAssertTrue(((first["program"] as? [String: Any])?["c"] as? String ?? "").contains("void"), "\(first)")
        let again = try await post("/v1/type", ["c": """
            typedef struct _PROBE_ERR_PPI { EFI_STATUS (*AddLog)(struct _PROBE_ERR_PPI *This, UINT32 Event); \
            UINT32 Count; } PROBE_ERR_PPI;
            """])
        XCTAssertEqual(again["member_types_replaced"] as? [String], ["PROBE_ERR_PPI_AddLog"], "\(again)")
        let after = try await read("/v1/type?name=PROBE_ERR_PPI_AddLog")
        let c = (after["program"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(c.contains("EFI_STATUS"), "\(after)")
        XCTAssertFalse(c.contains("void PROBE_ERR_PPI_AddLog"), "\(after)")
        let left = try await parserTypes()
        XCTAssertEqual(left, before, "the parser's _func_ types are gone")
        _ = try await release()
    }

    /// A structure defined again by its tag, whose function members the C
    /// names by the typedefs the program holds, keeps those typedefs: the
    /// members are not renamed after the tag (`_PROBE_SMU_PPI_SmnRead`). A
    /// member written as an inline prototype is named through the
    /// structure's typedef, as it is when the typedef is what the C defines.
    func testAStructureDefinedByItsTagKeepsTheMemberTypesItNames() async throws {
        try await open(try image())
        _ = try await post("/v1/type", ["c": """
            typedef EFI_STATUS (PROBE_SMU_PPI_SmnRead)(UINT32 Address, UINT32 *Value);
            typedef struct _PROBE_SMU_PPI { PROBE_SMU_PPI_SmnRead *SmnRead; UINT32 Revision; } PROBE_SMU_PPI;
            """])
        _ = try await post("/v1/type", ["c": """
            struct _PROBE_SMU_PPI { PROBE_SMU_PPI_SmnRead *SmnRead; \
            EFI_STATUS (*SmnWrite)(UINT32 Address, UINT32 Value); UINT32 Revision; };
            """])
        let ppi = try await read("/v1/type?name=_PROBE_SMU_PPI")
        let c = (ppi["program"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(c.contains("PROBE_SMU_PPI_SmnRead * SmnRead"), "\(ppi)")
        XCTAssertTrue(c.contains("PROBE_SMU_PPI_SmnWrite * SmnWrite"), "\(ppi)")
        XCTAssertFalse(c.contains("_PROBE_SMU_PPI_Smn"), "\(ppi)")
        let listed = try await read("/v1/types?contains=_PROBE_SMU_PPI_&kind=function&limit=50")
        XCTAssertEqual((listed["types"] as? [[String: Any]] ?? []).count, 0, "\(listed)")
        // A publish names the members again over what the review recorded:
        // the named ones stay, and the typedef's recorded text is the
        // structure as the tag defined it last.
        _ = try await host.preview(module, "/v1/publish?dry_run=1", body: Data())
        let review = try await read("/v1/review")
        let types = review["types"] as? [[String: Any]] ?? []
        let recorded = Dictionary(uniqueKeysWithValues: types.compactMap { item in
            (item["name"] as? String).map { ($0, item["c"] as? String ?? "") } })
        for name in ["PROBE_SMU_PPI", "_PROBE_SMU_PPI"] {
            let text = try XCTUnwrap(recorded[name], "\(recorded.keys.sorted())")
            XCTAssertTrue(text.contains("SmnWrite"), "\(name): \(text)")
            XCTAssertFalse(text.contains("_PROBE_SMU_PPI_Smn"), "\(name): \(text)")
        }
        _ = try await release()
    }

    /// Issue 7f2d75ae: one text defining a structure and the structure it
    /// holds an array of names the inline function members of both — not only
    /// of the type the text ends with. A member left `_func_N` reached the
    /// shared archive, where another module's `_func_1` has another signature.
    func testOneTextNamesTheFunctionMembersOfEveryStructureItDefines() async throws {
        try await open(try image())
        _ = try await post("/v1/type", ["c": """
            #pragma pack(1)
            typedef struct {
              EFI_GUID HashGuid;
              EFI_STATUS (*HashInit)(UINTN *HashHandle);
              EFI_STATUS (*HashUpdate)(UINTN HashHandle, void *DataToHash, UINTN DataToHashLen);
            } PROBE_HASH_INTERFACE;
            typedef struct {
              EFI_GUID Identifier;
              UINTN HashInterfaceCount;
              PROBE_HASH_INTERFACE HashInterface[5];
              UINT32 SupportedHashMask;
            } PROBE_HASH_INTERFACE_HOB;
            #pragma pack()
            """])
        let inner = try await read("/v1/type?name=PROBE_HASH_INTERFACE")
        let c = (inner["program"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertFalse(c.contains("_func_"), "\(inner)")
        XCTAssertTrue(c.contains("PROBE_HASH_INTERFACE_HashInit * HashInit"), "\(inner)")
        _ = try await release()
    }

    /// A function type the review named keeps its name in a member: only the
    /// parser's `_func_N` is named after the structure and the field. Taking
    /// the shared copy of such a structure (`take_shared`) must leave it as
    /// the shared archive has it, not rename its member's type back.
    func testANamedFunctionTypeInAMemberKeepsItsName() async throws {
        try await open(try image())
        _ = try await post("/v1/type", ["c": "typedef UINT32 (EFIAPI PROBE_HOOK_FUNCTION)(UINT32 HookId, UINT32 Reserved0, UINT32 Reserved1);"])
        _ = try await post("/v1/type", ["c": """
            typedef struct _PROBE_HOOK_ENTRY {
              UINT32 HookId;
              PROBE_HOOK_FUNCTION *Hook;
              UINT32 (*Inline)(UINT32 Value);
            } PROBE_HOOK_ENTRY;
            """])
        let entry = try await read("/v1/type?name=PROBE_HOOK_ENTRY")
        let c = (entry["program"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(c.contains("PROBE_HOOK_FUNCTION * Hook"), "\(entry)")
        XCTAssertTrue(c.contains("PROBE_HOOK_ENTRY_Inline * Inline"), "\(entry)")
        _ = try await release()
    }

    /// Issue ddb578ae: a function typedef in the same text as the structure
    /// that uses it is the function definition itself, as when it is defined
    /// alone — not a root typedef `typedef X X;` over `/functions/X` that the
    /// member then points at, which prints every call with a cast.
    func testAFunctionTypedefBesideItsStructureIsTheDefinition() async throws {
        try await open(try image())
        _ = try await post("/v1/type", ["c": """
            typedef UINT32 PROBE_SAME_TEXT_FUNCTION(UINT32 HookId, UINT32 Reserved0);
            typedef struct _PROBE_SAME_TEXT_ENTRY {
              UINT32 HookId;
              PROBE_SAME_TEXT_FUNCTION *Hook;
            } PROBE_SAME_TEXT_ENTRY;
            """])
        let function = try await read("/v1/type?name=PROBE_SAME_TEXT_FUNCTION")
        let program = (function["program"] as? [String: Any]) ?? [:]
        XCTAssertEqual(program["kind"] as? String, "function", "\(function)")
        XCTAssertFalse((program["c"] as? String ?? "").contains("typedef PROBE_SAME_TEXT_FUNCTION PROBE_SAME_TEXT_FUNCTION"), "\(function)")
        let entry = try await read("/v1/type?name=PROBE_SAME_TEXT_ENTRY")
        XCTAssertTrue(((entry["program"] as? [String: Any])?["c"] as? String ?? "").contains("PROBE_SAME_TEXT_FUNCTION * Hook"), "\(entry)")
        _ = try await release()
    }

    /// Issue f15e10c9: `comments` in the call that first defines a structure
    /// with an inline function member are placed, not a NullPointerException.
    func testCommentsInTheFirstDefinitionOfAStructureWithAFunctionMember() async throws {
        try await open(try image())
        let made = try await post("/v1/type", ["c": """
            #pragma pack(1)
            typedef struct _PROBE_ARI_SCAN_DATA {
              UINT32 (*Callback)(UINT32 Device, void *ScanData);
              void *StdHeader;
              UINT8 AriFound;
              UINT8 NextBus;
              UINT8 Reserved[2];
            } PROBE_ARI_SCAN_DATA;
            """, "description": "Probe.", "comments": ["Callback": "Called per device.", "StdHeader": "Written 0.",
                                                       "AriFound": "Set when found.", "NextBus": "Next bus.",
                                                       "Reserved": "Padding, not written."]])
        XCTAssertTrue((made["c"] as? String ?? "").contains("PROBE_ARI_SCAN_DATA_Callback * Callback"), "\(made)")
        let read = try await read("/v1/type?name=PROBE_ARI_SCAN_DATA")
        let c = (read["program"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(c.contains("Called per device."), "\(read)")
        XCTAssertTrue(c.contains("Set when found."), "\(read)")
        _ = try await release()
    }

    /// Issue ef6db511: two structures in one text with members of the same
    /// name each keep their own inline comments; none is merged into the
    /// other's or left unplaced.
    func testInlineCommentsStayWithTheStructureThatWritesThem() async throws {
        try await open(try image())
        let made = try await post("/v1/type", ["c": """
            #pragma pack(1)
            typedef struct _PROBE_OUTER_RECORD {
              UINT32 Signature; /* outer signature */
              LIST_ENTRY Link; /* outer link */
              UINT64 Signalled; /* outer only */
            } PROBE_OUTER_RECORD;
            typedef struct _PROBE_INNER_RECORD {
              UINT32 Signature; /* inner signature */
              LIST_ENTRY Link; /* inner link */
              VOID *Function; /* inner only */
            } PROBE_INNER_RECORD;
            #pragma pack()
            """])
        XCTAssertNil(made["comments_not_placed"], "\(made)")
        let outer = ((try await read("/v1/type?name=PROBE_OUTER_RECORD"))["program"] as? [String: Any])?["c"] as? String ?? ""
        let inner = ((try await read("/v1/type?name=PROBE_INNER_RECORD"))["program"] as? [String: Any])?["c"] as? String ?? ""
        for text in ["outer signature", "outer link", "outer only"] {
            XCTAssertTrue(outer.contains(text), outer)
            XCTAssertFalse(inner.contains(text), inner)
        }
        for text in ["inner signature", "inner link", "inner only"] {
            XCTAssertTrue(inner.contains(text), inner)
            XCTAssertFalse(outer.contains(text), outer)
        }
        _ = try await release()
    }

    /// Issue 4f6bb983: a function given its storage by hand takes off the
    /// stack what its RET does. FirmwareAuthenticationPei's 0x47D, made by
    /// hand where only its caller points, has an unknown purge until its
    /// signature; a plain RET there purges nothing, and its caller reads its
    /// own stack slots as they are.
    func testExplicitStorageKeepsThePurgeOfAPlainReturn() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_PURGE_MODULE"] else {
            throw XCTSkip("GHIDRA_PURGE_MODULE (FirmwareAuthenticationPei.efi) is not set")
        }
        try await open(try Data(contentsOf: URL(fileURLWithPath: path)))
        try await post("/v1/create/function", ["address": "0x5D2", "by": "agent"])
        try await post("/v1/create/function", ["address": "0x47D", "by": "agent"])
        let answer = try await post("/v1/set/signature", [
            "address": "0x47D",
            "signature": "EFI_STATUS FindIflashSignatureBlocks(UINT8 *Image, UINTN ImageSize, UINTN *SignedOffset, UINTN *SignedLength, UINTN *SignatureOffset, UINTN *SignatureLength)",
            "storage": ["ECX:4", "EDX:4", "Stack[0x4]:4", "Stack[0x8]:4", "Stack[0xc]:4", "Stack[0x10]:4"],
            "return_storage": "EAX:4", "by": "agent", "reason": "test"])
        let function = try await read("/v1/function/0x47D")
        XCTAssertEqual(function["stack_purge"] as? Int ?? 0, 0, "\(answer)")
        let caller = try await c("0x5D2")
        XCTAssertFalse(caller.contains("in_stack_"), caller)
        _ = try await release()
    }

    /// Issue 60431b90: Ghidra holds one variable per register at a first use,
    /// so naming the pair EDX:EAX would drop the name already on its EDX piece
    /// there. The rename is refused, and the first name stays.
    func testNamingARegisterPairDoesNotDropItsNamedPiece() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_PURGE_MODULE"] else {
            throw XCTSkip("GHIDRA_PURGE_MODULE (FirmwareAuthenticationPei.efi) is not set")
        }
        try await open(try Data(contentsOf: URL(fileURLWithPath: path)))
        let piece = try await post("/v1/rename/variable", ["function": "0xB671", "storage": "EDX:4",
                                                            "first_use": "0xB791", "name": "PHHHigh"])
        XCTAssertEqual(piece["name"] as? String, "PHHHigh", "\(piece)")
        let body = try JSONSerialization.data(withJSONObject: ["function": "0xB671", "storage": "EDX:4,EAX:4",
                                                               "first_use": "0xB791", "name": "PHH"])
        try await host.take(module)
        do {
            let answer = try await host.write(module, "/v1/rename/variable", body: body)
            XCTFail("the pair was named over its piece: \(String(data: answer, encoding: .utf8) ?? "")")
        } catch {
            XCTAssertTrue("\(error)".contains("PHHHigh"), "\(error)")
        }
        let locals = try await read("/v1/function/0xB671")["locals"] as? [[String: Any]] ?? []
        XCTAssertTrue(locals.contains { $0["name"] as? String == "PHHHigh" }, "\(locals.map { $0["name"] ?? "" })")
        _ = try await release()
    }

    /// Issue aff3367c: a frame's first slot typed as the whole buffer takes
    /// in the named slots that lie wholly inside it — they are its fields, and
    /// the answer lists them as `absorbed`. A slot it covers only in part is
    /// still refused, in words about stack slots.
    func testTypingTheFirstStackSlotAsTheBufferAbsorbsTheSlotsInside() async throws {
        try await open(try image())
        struct Slot { let start: Int; let size: Int; let storage: String }
        func slots(_ entry: String) async throws -> [Slot] {
            let locals = try await read("/v1/function/\(entry)")["locals"] as? [[String: Any]] ?? []
            let pattern = try NSRegularExpression(pattern: #"^Stack\[-0x([0-9a-fA-F]+)\]:(\d+)$"#)
            return locals.compactMap { local -> Slot? in
                // A stack local is the whole body's: it has no first use.
                guard let storage = local["storage"] as? String, local["first_use"] == nil,
                      let m = pattern.firstMatch(in: storage, range: NSRange(storage.startIndex..., in: storage)),
                      let offset = Int((storage as NSString).substring(with: m.range(at: 1)), radix: 16),
                      let size = Int((storage as NSString).substring(with: m.range(at: 2))) else { return nil }
                return Slot(start: -offset, size: size, storage: storage)
            }.sorted { $0.start < $1.start }
        }
        // A function with three stack slots that do not overlap, the last
        // wider than a byte, all named first: a review names a buffer before
        // it knows its type.
        var found: (entry: String, a: Slot, c: Slot)?
        for entry in try await entries() {
            let all = try await slots(entry)
            guard let a = all.first,
                  let b = all.first(where: { $0.start >= a.start + a.size }),
                  let c = all.first(where: { $0.start >= b.start + b.size && $0.size > 1 && $0.start + $0.size <= 0 })
            else { continue }
            var stayed = true
            for (slot, name) in [(b, "ProbePieceB"), (c, "ProbePieceC"), (a, "ProbeBuffer")] where stayed {
                let named = try? await post("/v1/rename/variable", ["function": entry, "storage": slot.storage,
                                                                    "name": name])
                stayed = named?["storage"] as? String == slot.storage
            }
            if stayed { found = (entry, a, c); break }
        }
        let (entry, a, c) = try XCTUnwrap(found, "no function with three stack slots apart")
        // Ending inside C: refused, and both names stay.
        let partial = try JSONSerialization.data(withJSONObject: [
            "function": entry, "storage": a.storage, "name": "ProbeBuffer",
            "type": "UINT8[\(c.start + 1 - a.start)]"])
        try await host.take(module)
        do {
            let answer = try await host.write(module, "/v1/rename/variable", body: partial)
            XCTFail("a slot covered in part was dropped: \(String(data: answer, encoding: .utf8) ?? "")")
        } catch {
            XCTAssertTrue("\(error)".contains("ProbePieceC"), "\(error)")
            XCTAssertTrue("\(error)".contains("stack slots"), "\(error)")
            XCTAssertFalse("\(error)".contains("register pair"), "\(error)")
        }
        let kept = try await read("/v1/function/\(entry)")["locals"] as? [[String: Any]] ?? []
        XCTAssertTrue(kept.contains { $0["name"] as? String == "ProbePieceB" }, "\(kept.map { $0["name"] ?? "" })")
        // Ending where C ends: both are absorbed.
        let merged = try await post("/v1/rename/variable", [
            "function": entry, "storage": a.storage, "name": "ProbeBuffer",
            "type": "UINT8[\(c.start + c.size - a.start)]"])
        let absorbed = (merged["absorbed"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(absorbed), ["ProbePieceB", "ProbePieceC"], "\(merged)")
        XCTAssertTrue((merged["absorbed"] as? [[String: Any]] ?? []).contains { $0["storage"] as? String == c.storage },
                      "\(merged)")
        _ = try await release()
    }

    /// Issue 25962cd2: an inline function-pointer parameter is not a type
    /// named after the parameter (`Table * * Table`): its function type is
    /// named after the function and the parameter, as a member's is after the
    /// structure and the field.
    func testAnInlineFunctionPointerParameterIsNamedAfterTheFunction() async throws {
        try await open(try image())
        let first = try await entries().first
        let entry = try XCTUnwrap(first)
        let answer = try await post("/v1/set/signature", ["address": entry,
                                    "signature": "BOOLEAN ProbeCallTable(BOOLEAN (**Table)(void))",
                                    "by": "agent", "reason": "test"])
        let signature = answer["signature"] as? String ?? ""
        XCTAssertTrue(signature.contains("ProbeCallTable_Table * * Table"), "\(answer)")
        let stray = try? await read("/v1/type?name=Table")
        XCTAssertNil((stray?["program"] as? [String: Any])?["c"], "\(stray ?? [:])")
        _ = try await release()
    }

    /// Issue bab008b6: an EDK2 prototype in a member — `VOID`, `IN`, `OUT`,
    /// `OPTIONAL`, `EFIAPI` — parses as the signatures do; a comment keeps
    /// the words as they were written.
    func testAMemberPrototypeTakesEDK2Spelling() async throws {
        try await open(try image())
        _ = try await post("/v1/type", ["c": """
            #pragma pack(1)
            typedef struct _PROBE_BLOCK_WRITE_PPI {
              EFI_STATUS (EFIAPI *WriteBlocks)(IN EFI_PEI_SERVICES **PeiServices, IN VOID *This,
                                              IN UINTN DeviceIndex, IN OUT VOID *Buffer OPTIONAL);
              CONST VOID *Context; // IN VOID stays as written here
            } PROBE_BLOCK_WRITE_PPI;
            #pragma pack()
            """])
        let ppi = try await read("/v1/type?name=PROBE_BLOCK_WRITE_PPI")
        let c = (ppi["program"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(c.contains("PROBE_BLOCK_WRITE_PPI_WriteBlocks * WriteBlocks"), "\(ppi)")
        let member = try await read("/v1/type?name=PROBE_BLOCK_WRITE_PPI_WriteBlocks")
        let prototype = (member["program"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(prototype.contains("void * Buffer"), "\(member)")
        _ = try await release()
    }

    /// Issue 4a95c0c1: a text of two structures named only the last one's
    /// members, and the parser, numbering its `_func_N` from one again,
    /// rewrote the program's `_func_1` that a third structure used.
    func testATextOfTwoStructuresNamesBothAndLeavesAnotherTypesFuncAlone() async throws {
        try await open(try image())
        // A pointer to a function pointer is not named: the third structure
        // keeps the parser's `_func_1`.
        _ = try await post("/v1/type", ["c": """
            typedef struct _PROBE_THIRD { EFI_STATUS (**Decode)(UINTN Format, UINTN Image); } PROBE_THIRD;
            """])
        let before = try await read("/v1/type?name=_func_1")
        let held = (before["program"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(held.contains("Image"), "\(before)")
        _ = try await post("/v1/type", ["c": """
            typedef struct _PROBE_CONSOLE { EFI_STATUS (*SetMode)(void *This, UINT32 Mode); } PROBE_CONSOLE;
            typedef struct _PROBE_DECODER { EFI_STATUS (*DecodeImage)(UINTN Size); } PROBE_DECODER;
            """])
        let first = try await read("/v1/type?name=PROBE_CONSOLE")
        let firstC = (first["program"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(firstC.contains("PROBE_CONSOLE_SetMode"), "\(first)")
        let after = try await read("/v1/type?name=_func_1")
        XCTAssertEqual((after["program"] as? [String: Any])?["c"] as? String, held, "\(after)")
        _ = try await release()
    }

    /// Issue ce3740de: the owner's lease lapsed after an hour with no write
    /// and the host kept its token. A publish takes it again for its type
    /// step, as a write does, instead of failing with "take the write lease first".
    func testAPublishTakesALapsedOwnerLeaseAgain() async throws {
        try await open(try image())
        let all = try await entries()
        let entry = try XCTUnwrap(all.first)
        try await post("/v1/set/comment", ["address": entry, "kind": "plate", "text": "Before the lease lapsed."])
        await host.lapseOwnerLease(module)
        try await host.take(module)
        let published = try await host.publish(module, by: "agent")
        XCTAssertNil(published.libraryError, "\(String(describing: published.libraryError))")
        _ = try await release()
    }

    func testAPointerThatIsZeroReadsNull() async throws {
        try await open(try image())
        let exported = try await host.preview(module, "/v1/publish?dry_run=1", body: Data())
        let artifact = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let functions = try XCTUnwrap(artifact["functions"] as? [[String: Any]])
        let zeroPointer = try NSRegularExpression(pattern: #"\*\)0x0\b"#)
        let number = try NSRegularExpression(pattern: #"[!=]= 0\b"#)
        var nulls = 0
        var numbers = 0
        for function in functions {
            let text = function["c"] as? String ?? ""
            let whole = NSRange(text.startIndex..., in: text)
            XCTAssertEqual(zeroPointer.numberOfMatches(in: text, range: whole), 0, text)
            let units = Array(text.utf16)
            for span in function["c_spans"] as? [[Any]] ?? [] {
                guard let start = span[0] as? Int, let length = span[1] as? Int, start + length <= units.count,
                      String(decoding: units[start..<(start + length)], as: UTF16.self) == "NULL" else { continue }
                XCTAssertEqual(span[2] as? String, "constant", "\(function["entry"] ?? "")")
                nulls += 1
            }
            numbers += number.numberOfMatches(in: text, range: whole)
        }
        XCTAssertGreaterThan(nulls, 0, "no zero pointer in the whole module")
        XCTAssertGreaterThan(numbers, 0, "a zero that is no pointer must stay a number")
        let reading = try XCTUnwrap(functions.first { ($0["c"] as? String)?.contains("NULL") == true })
        let entry = try XCTUnwrap(reading["entry"] as? String)
        let live = try await c(entry)
        XCTAssertTrue(live.contains("NULL"), live)
        XCTAssertEqual(zeroPointer.numberOfMatches(in: live, range: NSRange(live.startIndex..., in: live)), 0, live)
    }

    // MARK: - Reproductions on copies of kept projects

    private func openCopy(of name: String) async throws {
        guard let kept = ProcessInfo.processInfo.environment["GHIDRA_COPY_KEPT"] else { throw XCTSkip("GHIDRA_COPY_KEPT is not set") }
        // A folder of kept projects — a server's — or any other value for the app's.
        var isFolder: ObjCBool = false
        let source = FileManager.default.fileExists(atPath: kept, isDirectory: &isFolder) && isFolder.boolValue
            ? URL(fileURLWithPath: kept, isDirectory: true) : GhidraHost.defaultProjectsRoot
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

    // MARK: - The lease of a write that wrote nothing

    /// Each kind of write the owner refuses, with an address that holds nothing.
    private static let refusedWrites: [(String, [String: Any])] = [
        ("/v1/rename/function", ["address": "0x1", "name": "ProbeName"]),
        ("/v1/rename/label", ["address": "0x1", "name": "ProbeLabel"]),
        ("/v1/create/function", ["address": "0x1", "name": "ProbeFunction"]),
        ("/v1/delete/function", ["address": "0x1"]),
        ("/v1/clear/locals", ["address": "0x1"]),
        ("/v1/merge/functions", ["from": "0x1", "into": "0x2"]),
        ("/v1/rename/variable", ["function": "0x1", "name": "ProbeVariable", "ordinal": 0]),
        ("/v1/set/signature", ["address": "0x1", "signature": "void Probe(void)"]),
        ("/v1/set/comment", ["address": "0x1", "kind": "plate", "text": "probe"]),
        ("/v1/function/extend", ["function": "0x1", "end": "0x2"]),
        ("/v1/redecode", ["start": "0x1", "end": "0x2"]),
        ("/v1/set/code-mode", ["start": "0x1", "end": "0x2", "bits": 16]),
        ("/v1/set/equate", ["address": "0x1", "name": "PROBE", "value": "0x1", "enum": "PROBE_ENUM"]),
        ("/v1/set/description", ["section": "### Probe", "text": "x"]),
        ("/v1/type", ["c": "this is not C"]),
        ("/v1/set/data", ["address": "0x1", "type": "UINT32"]),
    ]

    private func leased() async -> Bool { await host.summaries().first?.leased ?? false }

    private func published() throws -> ProjectState.Published? {
        try GhidraProject.all(in: directory.appendingPathComponent("projects")).first?.state().published
    }

    /// A refused write wrote nothing: the module stays in work, and a done after it has nothing to publish.
    func testEachRefusedWriteGivesBackTheLeaseItTook() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let writes = try await read("/v1/hello")["writes"] as? Int
        for (path, body) in Self.refusedWrites {
            do {
                try await post(path, body)
                XCTFail("\(path) answered")
            } catch let error as GhidraHostError {
                XCTAssertEqual(error.kind, .refused, "\(path): \(error)")
            }
            let held = await leased()
            XCTAssertTrue(held, "\(path): the module stays in work")
            let now = try await read("/v1/hello")["writes"] as? Int
            XCTAssertEqual(now, writes, path)
        }
        let done = try await release()
        XCTAssertNil(done, "the refused writes left nothing to publish")
    }

    /// A name outside the image is a review's way to name an MMIO register, and the answer says where it landed.
    func testANameOutsideTheImageIsKeptAndSaidToBeThere() async throws {
        try await open(try image())
        let answer = try await post("/v1/set/data", ["address": "0xFED81730", "name": "ProbeRegister"])
        XCTAssertEqual(answer["outside_memory"] as? Bool, true, "\(answer)")
        do {
            _ = try await post("/v1/set/data", ["address": "0xFED81734", "name": "TypedRegister", "type": "UINT8"])
            XCTFail("a type outside the image was taken")
        } catch let error as GhidraHostError {
            XCTAssertTrue("\(error)".contains("without `type`"), "\(error)")
        }
        // Inside the image, past a function's entry: the entry itself is
        // the function's name, which set_data refuses.
        let all = try await entries()
        let entry = try XCTUnwrap(all.first)
        let code = try await read("/v1/disassembly/\(entry)")["instructions"] as? [[String: Any]] ?? []
        let inside = code.dropFirst().first?["address"] as? String
        let named = try await post("/v1/set/data", ["address": try XCTUnwrap(inside), "name": "ProbeInside"])
        XCTAssertNil(named["outside_memory"], "\(named)")
        let removed = try await post("/v1/set/data", ["address": "0xFED81730", "name": ""])
        XCTAssertEqual(removed["outside_memory"] as? Bool, true, "\(removed)")
    }

    /// A kept module differs from this exporter's artifact, and that alone makes no revision.
    func testADoneMakesNoRevisionWhereNothingWasWritten() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        _ = try await read("/v1/functions?limit=5")
        let afterReading = try await release()
        XCTAssertNil(afterReading)
        do { try await post("/v1/set/description", ["section": "### Probe", "text": "x"]) } catch {}
        let afterRefusal = try await release()
        XCTAssertNil(afterRefusal)
        XCTAssertEqual(try published()?.rev, before?.rev)
        XCTAssertEqual(try published()?.artifact, before?.artifact)
        XCTAssertEqual(try published()?.at, before?.at)
    }

    /// A refusal takes back only what it took: an earlier write's lease stays and publishes at the done.
    func testARefusalKeepsTheLeaseOfAnEarlierWrite() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe"])
        do { try await post("/v1/rename/function", ["address": "0x1", "name": "ProbeName"]) } catch {}
        let held = await leased()
        XCTAssertTrue(held)
        let done = try await release()
        XCTAssertNotNil(done)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 1)
        let after = await leased()
        XCTAssertFalse(after)
    }

    /// A write can count and change nothing. Each of these holds the lease, and a done makes no revision for it.
    func testAWriteThatChangesNothingMakesNoRevision() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        let function = try await read("/v1/function/0x9A11A49")
        let name = try XCTUnwrap(function["name"] as? String)
        let plate = try XCTUnwrap(function["plate"] as? String)
        let described = try await read("/v1/description")
        let description = try XCTUnwrap(described["text"] as? String)
        let writes: [(String, [String: Any])] = [
            ("/v1/rename/function", ["address": "0x9A11A49", "name": name]),
            ("/v1/set/comment", ["address": "0x9A11A49", "kind": "plate", "text": plate]),
            ("/v1/set/description", ["text": description]),
        ]
        for (path, body) in writes {
            try await post(path, body)
            let held = await leased()
            XCTAssertTrue(held, path)
            let done = try await release()
            XCTAssertNil(done, path)
            XCTAssertEqual(try published()?.rev, before?.rev, path)
            XCTAssertEqual(try published()?.at, before?.at, path)
            let after = await leased()
            XCTAssertFalse(after, path)
        }
    }

    /// The name it already has, with no reason given, keeps the reason it has; a new name does not.
    func testARenameToTheSameNameKeepsItsReason() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let function = try await read("/v1/function/0x9A11A49")
        let name = try XCTUnwrap(function["name"] as? String)
        let reason = try XCTUnwrap(function["name_reason"] as? String)
        let writes = try await read("/v1/hello")["writes"] as? Int
        try await post("/v1/rename/function", ["address": "0x9A11A49", "name": name])
        let same = try await read("/v1/function/0x9A11A49")
        XCTAssertEqual(same["name_reason"] as? String, reason)
        let now = try await read("/v1/hello")["writes"] as? Int
        XCTAssertEqual(now, writes)
        try await post("/v1/rename/function", ["address": "0x9A11A49", "name": name + "Renamed"])
        let renamed = try await read("/v1/function/0x9A11A49")
        XCTAssertNil(renamed["name_reason"], "\(renamed)")
    }

    /// A publish leaves the lease held and nothing written since: the done that follows has nothing to do.
    func testADoneRightAfterAPublishMakesNoRevision() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe"])
        _ = try await host.publish(module, by: "agent")
        let after = try published()
        let held = await leased()
        XCTAssertTrue(held)
        let done = try await release()
        XCTAssertNil(done)
        XCTAssertEqual(try published()?.rev, after?.rev)
        let released = await leased()
        XCTAssertFalse(released)
    }

    /// What a real write leaves behind still reaches the store at a done.
    func testADoneStillPublishesARealWrite() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe"])
        let done = try await release()
        XCTAssertNotNil(done)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 1)
    }

    /// A run of refused first writes pays for one export, and what follows it is judged as ever: a real write
    /// publishes, and a baseline older than that write does not make the next session's no-op look like a change.
    func testRefusedWritesShareABaselineAndARealWriteStillPublishes() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        let taken = await host.leaseBaselinesTaken
        for _ in 0..<3 {
            do { try await post("/v1/rename/function", ["address": "0x1", "name": "ProbeName"]) } catch {}
        }
        let afterRefusals = await host.leaseBaselinesTaken
        XCTAssertEqual(afterRefusals, taken + 1)

        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe"])
        let afterWrite = await host.leaseBaselinesTaken
        XCTAssertEqual(afterWrite, taken + 1)
        let done = try await release()
        XCTAssertNotNil(done)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 1)

        do { try await post("/v1/rename/function", ["address": "0x1", "name": "ProbeName"]) } catch {}
        let afterPublish = await host.leaseBaselinesTaken
        XCTAssertEqual(afterPublish, taken + 2)
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe"])
        let noOp = try await release()
        XCTAssertNil(noOp)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 1)
    }

    /// A placeholder the C prints that no local or parameter carries — a
    /// zero-hash temporary has no storage and first use to be named by — is in
    /// `leftovers.fragment_names`, so a function that still prints one never
    /// reads as finished (issue bf1f1b38: CpuPei's MtrrLib functions printed
    /// `uVar1`, `uVar2`, `iVar1` with `leftovers` empty).
    func testEveryPlaceholderTheCPrintsIsLeftOver() async throws {
        try await openCopy(of: "CpuPei")
        let placeholder = try NSRegularExpression(pattern:
            #"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*Var\d+|local_[0-9a-fA-F]+|extraout_[A-Z0-9]+|in_[A-Z0-9]+|unaff_[A-Z0-9]+)(?![A-Za-z0-9_])"#)
        var unlisted: [String] = []
        var printedOnly = 0
        for entry in try await entries() {
            let function = try await read("/v1/function/\(entry)")
            let c = (function["c"] as? String ?? "")
                .replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: " ", options: .regularExpression)
            let carried = Set(((function["locals"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                + ((function["parameters"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
            let printed = Set(placeholder.matches(in: c, range: NSRange(c.startIndex..., in: c)).compactMap {
                Range($0.range(at: 1), in: c).map { String(c[$0]) }
            })
            let leftovers = function["leftovers"] as? [String: Any]
            let listed = Set(leftovers?["fragment_names"] as? [String] ?? [])
            for name in printed.subtracting(carried) {
                printedOnly += 1
                if !listed.contains(name) { unlisted.append("\(entry) \(function["name"] ?? "") \(name)") }
            }
        }
        XCTAssertEqual(unlisted, [], "printed in the C, carried by no variable, and not left over")
        print("bf1f1b38: \(printedOnly) printed-only placeholders in CpuPei")
    }

    /// A write the store has not got is what a done is for, whatever the session that finds it does first: the
    /// owner stopped between them, and neither a refusal nor a no-op may make it look like nothing was written.
    func testADoneInALaterSessionPublishesAnEarlierWrite() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe"])
        await host.stop(module)

        do { try await post("/v1/rename/function", ["address": "0x1", "name": "ProbeName"]) } catch {}
        let refused = try await release()
        XCTAssertNotNil(refused)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 1)

        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe two"])
        await host.stop(module)
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe two"])
        let noOp = try await release()
        XCTAssertNotNil(noOp)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 2)
    }

    /// A publish moves the count, so a baseline from before it says nothing about the next session's no-op.
    func testABaselineFromBeforeAPublishIsNotKept() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe"])
        _ = try await host.publish(module, by: "agent")
        await host.stop(module)
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe"])
        let noOp = try await release()
        XCTAssertNil(noOp)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 1)
    }

    /// A real write landing while a done compares a no-op is published, not recorded as nothing.
    func testAWriteDuringADonesComparisonIsPublished() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        let function = try await read("/v1/function/0x9A11A49")
        let plate = try XCTUnwrap(function["plate"] as? String)
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "plate", "text": plate])
        await landWrite(at: .compared)
        let done = try await release()
        XCTAssertNotNil(done)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 1)
    }

    /// One landing just after a done gave the lease back holds its own lease, and the next done publishes it.
    func testAWriteAfterADoneGaveTheLeaseBackIsPublishedByTheNext() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        let function = try await read("/v1/function/0x9A11A49")
        let plate = try XCTUnwrap(function["plate"] as? String)
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "plate", "text": plate])
        await landWrite(at: .givenBack)
        let first = try await release()
        XCTAssertNil(first)
        await host.setReleaseStep(nil)
        let second = try await release()
        XCTAssertNotNil(second)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 1)
    }

    private func landWrite(at wanted: GhidraHost.ReleaseStep) async {
        let (host, module) = (host!, module!)
        let body = try! JSONSerialization.data(withJSONObject: ["address": "0x9A11A49", "kind": "eol", "text": "landed"])
        await host.setReleaseStep { step in
            guard step == wanted else { return }
            await host.setReleaseStep(nil)
            _ = try? await host.write(module, "/v1/set/comment", body: body)
        }
    }

    private func restartHost() async {
        let (configuration, writer) = (await host.configuration, await host.writer)
        host = GhidraHost(configuration: configuration, writer: writer)
    }

    /// A restarted server holds no lease, and a done with no new write still publishes what the project holds.
    func testADoneAfterARestartPublishesAnEarlierWrite() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe"])
        await restartHost()
        let done = try await release()
        XCTAssertNotNil(done)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 1)
        let again = try await release()
        XCTAssertNil(again)
    }

    /// The same with the owner gone as well: it starts to publish, and only for that.
    func testADoneWithNoOwnerPublishesAnEarlierWriteAndStartsNoneForNothing() async throws {
        try await openCopy(of: "FirmwareRevisionSyncPei")
        let before = try published()
        try await post("/v1/set/comment", ["address": "0x9A11A49", "kind": "eol", "text": "probe"])
        await host.stop(module)
        await restartHost()
        let done = try await release()
        XCTAssertNotNil(done)
        XCTAssertEqual(try published()?.rev, (before?.rev ?? 0) + 1)

        await host.stop(module)
        let owner = await host.project(module).ownerURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: owner.path))
        let nothing = try await release()
        XCTAssertNil(nothing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owner.path))
    }

    // MARK: - The patched language

    /// `GHIDRA_PATCHED_HOME` names a copy from Scripts/make-patched-ghidra.sh.
    func testAPatchedGhidraSaysSoAndItsSIDTReadsLimitAndBase() async throws {
        guard let patched = ProcessInfo.processInfo.environment["GHIDRA_PATCHED_HOME"] else {
            throw XCTSkip("GHIDRA_PATCHED_HOME is not set")
        }
        let image = try image()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerReadBack-\(UUID().uuidString)", isDirectory: true)
        let projects = directory.appendingPathComponent("projects")
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: projects, ghidraHome: URL(fileURLWithPath: patched),
                                               idle: 300, holder: "GhidraOwnerReadBackTests"), writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
        let hello = try await read("/v1/hello")
        XCTAssertEqual(hello["language_patch"] as? String, "descriptor-tables-1")

        let preview = try await host.preview(module, "/v1/publish?dry_run=1", body: Data())
        let artifact = try XCTUnwrap(JSONSerialization.jsonObject(with: preview) as? [String: Any])
        XCTAssertEqual(artifact["language_patch"] as? String, "descriptor-tables-1")
        let functions = try XCTUnwrap(artifact["functions"] as? [[String: Any]])
        let readers = functions.filter { (($0["instructions"] as? [[String: Any]]) ?? []).contains { $0["mnemonic"] as? String == "SIDT" } }
        XCTAssertFalse(readers.isEmpty)
        for function in readers {
            let c = try XCTUnwrap(function["c"] as? String, "\(function["entry"] ?? "")")
            XCTAssertTrue(c.contains("InterruptDescriptorTableBase()"), c)
            XCTAssertFalse(c.contains("InterruptDescriptorTableRegister()"), c)
        }

        try await post("/v1/set/comment", ["address": try XCTUnwrap(readers[0]["entry"] as? String), "kind": "plate", "text": "probe"])
        let published = try await host.publish(module, by: "t")
        XCTAssertTrue(published.manifest.recipe.id.contains("-ghidra-12.2-lang-descriptor-tables-1"), published.manifest.recipe.id)
        await host.stop(module)

        // The same project on a stock Ghidra opens, reads old C, and may not publish over it.
        let stock = GhidraHost(configuration: .init(projectsRoot: projects, idle: 300, holder: "GhidraOwnerReadBackTests"), writer: store)
        let plain = try JSONSerialization.jsonObject(with: await stock.read(module, "/v1/hello")) as? [String: Any]
        XCTAssertNil(plain?["language_patch"])
        do {
            _ = try await stock.publish(module, by: "t")
            XCTFail("a stock Ghidra published over a patched recipe")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)")
        }
        await stock.stop(module)
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

    /// A call through a register holding a constant is in the stored call graph, both ways.
    func testAStoredAnalysisListsAHeldCallBothWays() async throws {
        let made = try imageWithAnIndirectCall()
        try await open(made.image)
        let stub = "0x" + String(made.stub, radix: 16, uppercase: true)
        let target = "0x" + String(made.target, radix: 16, uppercase: true)
        let all = try await entries()
        try await post("/v1/set/comment", ["address": try XCTUnwrap(all.first), "kind": "plate", "text": "One."])
        let done = try await host.publish(module, by: "agent")
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let code = try store.artifact(for: done.manifest)
        let caller = try XCTUnwrap(code.functions.first { $0.entry.description == stub })
        let callee = try XCTUnwrap(code.functions.first { $0.entry.description == target })
        XCTAssertTrue(caller.callees.contains { $0.description == target }, "\(caller.callees)")
        XCTAssertTrue(callee.callers.contains { $0.description == stub }, "\(callee.callers)")
    }

    /// The same on a real one, where analysis left no reference at the call:
    /// SecCore's exception entry calls through EAX what the register was given.
    func testAHeldCallAnalysisLeftNoReferenceForIsListedBothWays() async throws {
        try await openCopy(of: "SecCore")
        let exported = try await host.write(module, "/v1/publish?dry_run=1", body: Data())
        let artifact = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let functions = try XCTUnwrap(artifact["functions"] as? [[String: Any]])
        func function(_ entry: String) throws -> [String: Any] {
            try XCTUnwrap(functions.first { $0["entry"] as? String == entry })
        }
        XCTAssertTrue((try function("0x9DFBDD1")["callees"] as? [String])?.contains("0x9DFBF90") == true)
        XCTAssertTrue((try function("0x9DFBF90")["callers"] as? [String])?.contains("0x9DFBDD1") == true)
    }

    /// `ghidra_done` on a module only read holds no lease, so nothing is published.
    func testADoneAfterOnlyReadingPublishesNothing() async throws {
        try await open(try image())
        _ = try await entries()
        let done = try await release()
        XCTAssertNil(done)
        let state = try GhidraProject.all(in: directory.appendingPathComponent("projects")).first?.state()
        XCTAssertNil(state?.published?.rev, "\(String(describing: state?.published))")
    }

    /// Asking what an equate would do takes no lease and writes nothing.
    func testAnEquateDryRunWritesNothing() async throws {
        try await open(try image())
        let all = try await entries()
        let before = try await read("/v1/hello")
        let body = try JSONSerialization.data(withJSONObject: ["functions": all, "name": "PreviewName", "value": "0x10"])
        let answer = try JSONSerialization.jsonObject(with: await host.preview(module, "/v1/preview/equate", body: body)) as? [String: Any]
        XCTAssertEqual(answer?["dry_run"] as? Bool, true, "\(answer ?? [:])")
        XCTAssertNotNil(answer?["applied"], "\(answer ?? [:])")
        let after = try await read("/v1/hello")
        XCTAssertEqual(before["modification"] as? Int, after["modification"] as? Int)
        // The module is in work from the take; a dry run counts as no write under it.
        let lease = await host.workLease(module)
        XCTAssertNotNil(lease)
        XCTAssertNil(lease?.writes, "a dry run is not a write")
    }

    /// An owner left alone exits, and what its last lease wrote is there when it opens again.
    func testAnIdleOwnerExitsAndKeepsWhatWasWritten() async throws {
        let image = try image()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GhidraOwnerReadBack-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 10,
                                               holder: "GhidraOwnerReadBackTests"), writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(SHA256Digest(data: image))
        let all = try await entries()
        let entry = try XCTUnwrap(all.first)
        try await post("/v1/rename/function", ["address": entry, "name": "SavedWhenIdle", "by": "agent", "reason": "test"])
        let record = try await host.owner(of: module)
        // A child that has exited still answers kill(0), and a request would keep it alive.
        func running() throws -> Bool {
            let ps = Process(), pipe = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "stat=", "-p", String(record.pid)]
            ps.standardOutput = pipe
            try ps.run()
            ps.waitUntilExit()
            let stat = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !stat.isEmpty && !stat.hasPrefix("Z")
        }
        var waited = 0
        while try running(), waited < 60 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            waited += 2
        }
        XCTAssertFalse(try running(), "still up after \(waited) s")
        let name = try await read("/v1/function/\(entry)")["name"] as? String
        XCTAssertEqual(name, "SavedWhenIdle")
    }

    /// A signal to the owner keeps what was written too: the save is not left to race
    /// Ghidra's own shutdown hook.
    func testASignaledOwnerKeepsWhatWasWritten() async throws {
        try await open(try image())
        let all = try await entries()
        let entry = try XCTUnwrap(all.first)
        try await post("/v1/rename/function", ["address": entry, "name": "SavedOnSignal", "by": "agent", "reason": "test"])
        let record = try await host.owner(of: module)
        kill(pid_t(record.pid), SIGTERM)
        for _ in 0..<30 where (try? await GhidraHost.call(record.port, "GET", "/v1/hello", timeout: 1)) != nil {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let name = try await read("/v1/function/\(entry)")["name"] as? String
        XCTAssertEqual(name, "SavedOnSignal")
    }

    /// A kill loses what was not saved, and the next open says so; an orderly end says nothing.
    func testAKilledOwnersLostWritesAreSaidAtTheNextOpen() async throws {
        try await open(try image())
        let all = try await entries()
        let entry = try XCTUnwrap(all.first)
        try await post("/v1/rename/function", ["address": entry, "name": "SavedByPublish", "by": "agent", "reason": "test"])
        _ = try await host.publish(module, by: "agent")
        await host.stop(module)
        let orderly = try await read("/v1/hello")
        XCTAssertNil(orderly["writes_lost"], "\(orderly)")
        try await post("/v1/rename/function", ["address": entry, "name": "NeverSaved", "by": "agent", "reason": "test"])
        let record = try await host.owner(of: module)
        kill(pid_t(record.pid), SIGKILL)
        for _ in 0..<30 where (try? await GhidraHost.call(record.port, "GET", "/v1/hello", timeout: 1)) != nil {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let after = try await read("/v1/hello")
        let said = try XCTUnwrap(after["writes_lost"] as? String, "\(after)")
        XCTAssertTrue(said.contains("were not saved"), said)
        let row = await host.summaries().first { $0.module == module.hex }
        XCTAssertEqual(row?.writesLost?.contains("were not saved"), true)
        let name = try await read("/v1/function/\(entry)")["name"] as? String
        XCTAssertEqual(name, "SavedByPublish")
    }

    /// A signature written on a function analysis left at `unknown` clears the
    /// decompiler's warning, and only that: the places and the rest of the C stay.
    /// The callback ends in a plain RET, so it is EFIAPI's `__cdecl` and purges
    /// nothing; the windows spec's `default` would purge its arguments.
    func testASignatureOnAnUnknownFunctionClearsTheWarningOnly() async throws {
        try await openCopy(of: "InitPortConfigPei")
        let entry = "0x9A00548"
        let held = try await read("/v1/function/\(entry)")
        XCTAssertEqual(held["calling_convention"] as? String, "unknown")
        let before = try await c(entry)
        XCTAssertTrue(before.contains("WARNING: Unknown calling convention"), before)
        func places(_ function: [String: Any]) -> [String] {
            (function["parameters"] as? [[String: Any]])?.map { $0["storage"] as? String ?? "?" } ?? []
        }
        let answer = try await post("/v1/set/signature", ["address": entry, "signature": try XCTUnwrap(held["signature"] as? String),
                                                          "by": "agent", "reason": "test"])
        XCTAssertNil(answer["convention_stays_unknown"], "\(answer)")
        let now = try await read("/v1/function/\(entry)")
        XCTAssertEqual(now["calling_convention"] as? String, "__cdecl")
        XCTAssertNil(now["stack_purge"], "\(now)")
        XCTAssertEqual(places(now), places(held))
        let after = try await c(entry)
        let unwarned = before.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("WARNING: Unknown calling") }.joined(separator: "\n")
        // The head now names the convention, and the decompiler lays it out anew.
        func flat(_ text: String) -> String {
            text.replacingOccurrences(of: "__cdecl", with: "").filter { !$0.isWhitespace }
        }
        XCTAssertEqual(flat(after), flat(unwarned))
    }

    /// An entry whose function was left at `unknown` says nothing about the
    /// convention: applying it does not take away the one a function has.
    func testAnEntrysUnknownConventionIsNotWrittenOnAFunction() async throws {
        try await openCopy(of: "InitPortConfigPei")
        let rows = try await read("/v1/functions?limit=50")["functions"] as? [[String: Any]] ?? []
        var named: [String: Any]?
        for row in rows {
            let function = try await read("/v1/function/\(row["entry"] as? String ?? "")")
            if function["calling_convention"] as? String == "__cdecl" { named = function; break }
        }
        let function = try XCTUnwrap(named)
        let entry = try XCTUnwrap(function["entry"] as? String)
        let parameters = (function["parameters"] as? [[String: Any]] ?? []).map { ["name": $0["name"] ?? "", "type": $0["type"] ?? "", "storage": $0["storage"] ?? ""] }
        let applied = try await post("/v1/library/apply", ["items": [[
            "address": entry, "id": "1a-test", "version": 1, "mode": "link",
            "entry": ["name": function["name"] ?? "", "signature": function["signature"] ?? "",
                      "calling_convention": "unknown", "params": parameters] as [String: Any]
        ] as [String: Any]]])
        let results = try XCTUnwrap(applied["items"] as? [[String: Any]])
        XCTAssertEqual(results.first?["ok"] as? Int, 1, "\(results)")
        let now = try await read("/v1/function/\(entry)")
        XCTAssertEqual(now["calling_convention"] as? String, "__cdecl")
    }

    /// A helper that never writes EDX keeps it for its callers: with
    /// `unaffected`, the caller's C reads EDX across the call (issue 6cbeb000,
    /// DebugMaskPei's CopyGenericVariableGuid at 0x9A0FD2A, called from
    /// 0x9A0FC4F).
    func testARegisterTheCalleeKeepsReadsAcrossTheCall() async throws {
        let bytes = try image()
        guard SHA256Digest(data: bytes).hex.hasPrefix("98290ef9") else { throw XCTSkip("GHIDRA_TYPE_MODULE is not DebugMaskPei") }
        try await open(bytes)
        let before = try await read("/v1/function/0x9A0FC4F")["c"] as? String ?? ""
        XCTAssertTrue(before.contains("extraout_EDX"), "the call kills EDX as the plain convention says: \(before)")
        let signature = "EFI_GUID * CopyGenericVariableGuid(EFI_GUID *DestinationGuid)"
        let set = try await post("/v1/set/signature", ["address": "0x9A0FD2A", "signature": signature,
                                                       "storage": ["ECX:4"], "return_storage": "EAX:4",
                                                       "unaffected": ["edx"]])
        XCTAssertEqual(set["unaffected_kept"] as? [String], ["EDX"], "\(set)")
        let root = try XCTUnwrap((set["calling_convention"] as? String)?.components(separatedBy: "_keeps_").first)
        XCTAssertEqual(set["calling_convention"] as? String, "\(root)_keeps_EDX", "\(set)")
        XCTAssertEqual(set["storage"] as? [String], ["ECX:4"], "the places stay: \(set)")
        let callee = try await read("/v1/function/0x9A0FD2A")
        XCTAssertEqual(callee["unaffected_kept"] as? [String], ["EDX"])
        let after = try await read("/v1/function/0x9A0FC4F")["c"] as? String ?? ""
        print("CALLER BEFORE\n\(before)\nCALLER AFTER\n\(after)")
        XCTAssertFalse(after.contains("extraout_EDX"), "the caller's C reads EDX across the call: \(after)")

        // A second function keeping the same register shares the convention;
        // [] goes back to the plain one.
        let plain = try await post("/v1/set/signature", ["address": "0x9A0FD2A", "signature": signature,
                                                         "storage": ["ECX:4"], "return_storage": "EAX:4",
                                                         "unaffected": [String]()])
        XCTAssertNil(plain["unaffected_kept"], "\(plain)")
        XCTAssertEqual(plain["calling_convention"] as? String, root)
        do {
            _ = try await post("/v1/set/signature", ["address": "0x9A0FD2A", "signature": signature, "unaffected": ["XYZ"]])
            XCTFail("a register the language has not got")
        } catch {}
    }

    /// ECX can be kept too: it is all of x86's `likelytrash`, and a list
    /// emptied by the keep leaves the convention, which Ghidra refused
    /// whole (issue 1413016b, Ps2KeyboardPei's IsTscFrequencyGuid).
    func testECXCanBeKeptThoughItIsAllOfTheLikelyTrash() async throws {
        let bytes = try image()
        guard SHA256Digest(data: bytes).hex.hasPrefix("98290ef9") else { throw XCTSkip("GHIDRA_TYPE_MODULE is not DebugMaskPei") }
        try await open(bytes)
        let signature = "EFI_GUID * CopyGenericVariableGuid(EFI_GUID *DestinationGuid)"
        let set = try await post("/v1/set/signature", ["address": "0x9A0FD2A", "signature": signature,
                                                       "storage": ["EDX:4"], "return_storage": "EAX:4",
                                                       "unaffected": ["ecx"]])
        XCTAssertEqual(set["unaffected_kept"] as? [String], ["ECX"], "\(set)")
        XCTAssertTrue((set["calling_convention"] as? String)?.hasSuffix("_keeps_ECX") == true, "\(set)")
        XCTAssertEqual(set["storage"] as? [String], ["EDX:4"], "the places stay: \(set)")
        let both = try await post("/v1/set/signature", ["address": "0x9A0FD2A", "signature": signature,
                                                        "storage": ["EDX:4"], "return_storage": "EAX:4",
                                                        "unaffected": ["ecx", "edx"]])
        XCTAssertEqual(both["unaffected_kept"] as? [String], ["ECX", "EDX"], "\(both)")
        let callee = try await read("/v1/function/0x9A0FD2A")
        XCTAssertEqual(callee["unaffected_kept"] as? [String], ["ECX", "EDX"])
    }

    /// A function that ends by jumping to another function's entry reads the
    /// jump as a tail call once both are functions, whichever was made
    /// second; `set/flow` takes the mark back and puts it again (issue
    /// 5872c498, PlatformStage2Pei's _ModuleEntryPoint at 0x9A16D90 jumping
    /// to 0x9A16DC6).
    func testAJumpToAnotherFunctionsEntryIsATailCall() async throws {
        let bytes = try image()
        guard SHA256Digest(data: bytes).hex.hasPrefix("b7d73a20") else { throw XCTSkip("GHIDRA_TYPE_MODULE is not PlatformStage2Pei") }
        try await open(bytes)
        try await post("/v1/delete/function", ["address": "0x9A16D90"])
        try await post("/v1/create/function", ["address": "0x9A16DC6", "name": "PlatformStage2PeiEntryPoint"])
        let made = try await post("/v1/create/function", ["address": "0x9A16D90"])
        let tails = try XCTUnwrap(made["tail_calls"] as? [[String: Any]], "\(made)")
        XCTAssertEqual(tails.count, 1, "\(tails)")
        XCTAssertEqual(tails.first?["to"] as? String, "0x9A16DC6")
        XCTAssertEqual(tails.first?["entry"] as? String, "0x9A16D90")
        let jump = try XCTUnwrap(tails.first?["address"] as? String)
        let c = try await read("/v1/function/0x9A16D90")["c"] as? String ?? ""
        XCTAssertFalse(c.contains("Exceeded maximum restarts"), c)
        XCTAssertTrue(c.contains("PlatformStage2PeiEntryPoint("), "the C calls the other function: \(c)")

        let plain = try await post("/v1/set/flow", ["address": jump, "override": "none"])
        XCTAssertEqual(plain["override"] as? String, "none")
        let inlined = try await read("/v1/function/0x9A16D90")["c"] as? String ?? ""
        XCTAssertFalse(inlined.contains("PlatformStage2PeiEntryPoint("), "the jump is flow again: \(inlined)")
        let marked = try await post("/v1/set/flow", ["address": jump, "override": "call_return"])
        XCTAssertEqual(marked["override"] as? String, "call_return")
        XCTAssertEqual(marked["entry"] as? String, "0x9A16D90")
        let again = try await read("/v1/function/0x9A16D90")["c"] as? String ?? ""
        XCTAssertTrue(again.contains("PlatformStage2PeiEntryPoint("), again)
        do {
            _ = try await post("/v1/set/flow", ["address": "0x9A16D90", "override": "call_return"])
            XCTFail("an instruction that is not a jump")
        } catch {}
    }

    /// After a tail call, EAX holds two values in one function: the PPI a
    /// call at the entry returns and the tail call's status. Named with the
    /// type it already has, the PPI keeps both calls' answers and the status
    /// keeps its own name (issue 537ef101).
    func testTwoValuesInEAXAfterATailCallAreNamedApart() async throws {
        let bytes = try image()
        guard SHA256Digest(data: bytes).hex.hasPrefix("b7d73a20") else { throw XCTSkip("GHIDRA_TYPE_MODULE is not PlatformStage2Pei") }
        try await open(bytes)
        try await post("/v1/delete/function", ["address": "0x9A16D90"])
        try await post("/v1/create/function", ["address": "0x9A16DC6", "name": "PlatformStage2PeiEntryPoint"])
        try await post("/v1/create/function", ["address": "0x9A16D90"])
        for (address, signature) in [
            ("0x9A176B6", "EFI_PEI_PCD_PPI * GetPiPcdPpi(void)"),
            ("0x9A16DC6", "EFI_STATUS PlatformStage2PeiEntryPoint(EFI_PEI_FILE_HANDLE FileHandle, EFI_PEI_SERVICES **PeiServices)"),
            ("0x9A16D90", "EFI_STATUS _ModuleEntryPoint(EFI_PEI_FILE_HANDLE FileHandle, EFI_PEI_SERVICES **PeiServices)")
        ] {
            try await post("/v1/set/signature", ["address": address, "signature": signature, "by": "agent", "reason": "test"])
        }
        // As on the live server: the jump read as flow and decompiled so,
        // then marked a tail call in the running owner.
        try await post("/v1/set/flow", ["address": "0x9A16DC1", "override": "none"])
        _ = try await read("/v1/function/0x9A16D90")
        try await post("/v1/set/flow", ["address": "0x9A16DC1", "override": "call_return"])
        var locals = try await read("/v1/function/0x9A16D90")
        if let status = ((locals["locals"] as? [[String: Any]]) ?? []).first(where: { ($0["first_use"] as? String) == "0x9A16DC1" }) {
            try await post("/v1/rename/variable", ["function": "0x9A16D90", "storage": status["storage"] as Any,
                                                  "first_use": "0x9A16DC1", "name": "Status"])
        }
        locals = try await read("/v1/function/0x9A16D90")
        let all = ((locals["locals"] as? [[String: Any]]) ?? []) + ((locals["variables"] as? [[String: Any]]) ?? [])
        let eax = all.filter { ($0["storage"] as? String) == "EAX:4" }
        let first = try XCTUnwrap(eax.first(where: { ($0["first_use"] as? String)?.uppercased() == "0X9A16D90" }), "\(all)")
        let named = try await post("/v1/rename/variable", ["function": "0x9A16D90", "storage": "EAX:4",
                                                           "first_use": first["first_use"] as Any, "name": "PcdPpi",
                                                           "type": "EFI_PEI_PCD_PPI *"])
        XCTAssertEqual(named["name"] as? String, "PcdPpi", "\(named)")
        let c = try await read("/v1/function/0x9A16D90")["c"] as? String ?? ""
        XCTAssertEqual(c.components(separatedBy: "PcdPpi = GetPiPcdPpi()").count - 1, 2,
                       "both calls' answers are PcdPpi: \(c)")
        XCTAssertTrue(c.contains("Status = PlatformStage2PeiEntryPoint("), c)
    }

    /// A typedef over the type a local already has is a change the C prints:
    /// UINT32 over Ghidra's `uint` is applied, and the answer says the type
    /// the local holds. Sent again, the type is said to be unchanged rather
    /// than dropped under a plain ok (issue 57972088).
    func testATypedefOverTheSameBaseTypeIsAppliedAndAnUnchangedTypeIsSaid() async throws {
        try await open(try image())
        let functions = (try await read("/v1/functions?limit=200")["functions"] as? [[String: Any]]) ?? []
        var found: (function: String, local: [String: Any])?
        for function in functions {
            guard let entry = function["entry"] as? String else { continue }
            let locals = (try await read("/v1/function/\(entry)")["locals"] as? [[String: Any]]) ?? []
            if let local = locals.first(where: { ($0["type"] as? String) == "uint" && $0["first_use"] is String }) {
                found = (entry, local)
                break
            }
        }
        let (function, local) = try XCTUnwrap(found, "no local typed uint in the test module")
        let typed = try await post("/v1/rename/variable", ["function": function, "storage": local["storage"] as Any,
                                                           "first_use": local["first_use"] as Any, "name": "Counted",
                                                           "type": "UINT32"])
        XCTAssertEqual(typed["type"] as? String, "UINT32", "\(typed)")
        XCTAssertNil(typed["type_unchanged"], "\(typed)")
        let again = try await post("/v1/rename/variable", ["function": function, "storage": typed["storage"] as Any,
                                                           "first_use": typed["first_use"] as Any, "name": "CountedAgain",
                                                           "type": "UINT32"])
        XCTAssertEqual(again["type_unchanged"] as? String, "UINT32", "\(again)")
        XCTAssertEqual(again["name"] as? String, "CountedAgain")
    }

    /// An owner left with no record — its host stopped before it wrote
    /// `owner.json` — keeps the project's lock; the next open stops it and
    /// opens (issues f9bb8693, d3b03c04).
    func testAnOwnerNoRecordNamesIsStoppedAndTheProjectOpens() async throws {
        try await open(try image())
        _ = try await read("/v1/hello")
        let project = await host.project(module)
        let record = try JSONDecoder().decode(OwnerRecord.self, from: Data(contentsOf: project.ownerURL))
        try FileManager.default.removeItem(at: project.ownerURL)
        XCTAssertTrue(Subprocess.isAlive(record.pid), "the owner runs on with no record")
        let orphans = OwnerOrphans.find(projectsRoot: project.folder.deletingLastPathComponent(), module: module.hex)
        XCTAssertEqual(orphans.map(\.pid), [record.pid])

        let hello = try await read("/v1/hello")
        XCTAssertNotNil(hello["functions"], "\(hello)")
        XCTAssertFalse(Subprocess.isAlive(record.pid), "the orphan was stopped")
        let now = try JSONDecoder().decode(OwnerRecord.self, from: Data(contentsOf: project.ownerURL))
        XCTAssertNotEqual(now.pid, record.pid, "a new owner, with its record")
    }

    /// A gap's range is half-open like every other: `end` is `start` + `size`.
    func testAGapEndsAtTheByteAfterIt() async throws {
        try await open(try image())
        let gaps = try await read("/v1/gaps?limit=500")
        let rows = try XCTUnwrap(gaps["gaps"] as? [[String: Any]])
        guard !rows.isEmpty else { throw XCTSkip("no gap in the image") }
        for gap in rows {
            let start = try XCTUnwrap(UInt64((gap["start"] as? String ?? "").dropFirst(2), radix: 16))
            let end = try XCTUnwrap(UInt64((gap["end"] as? String ?? "").dropFirst(2), radix: 16))
            let size = try XCTUnwrap(gap["size"] as? Int)
            XCTAssertEqual(end, start + UInt64(size), "\(gap)")
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
        if try GhidraInstall.find().decompilerPatch == nil {
            let moved = try XCTUnwrap(answer["aligned"] as? [[String: Any]], "\(answer)")
            XCTAssertEqual(moved.compactMap { $0["name"] as? String }, ["Address", "Buffer"])
            XCTAssertEqual(moved.first?["convention"] as? String, "Stack[0x14]:8", "\(answer)")
        } else {
            // stack-params-1: the convention puts them there, nothing is moved.
            XCTAssertNil(answer["aligned"], "\(answer)")
        }
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
        _ = try await release()
        let second = try published()
        XCTAssertEqual(second.at, first.at, "a publish that stored nothing new keeps its time")
        XCTAssertEqual(second.rev, first.rev)
        XCTAssertEqual(second.artifact, first.artifact)
        XCTAssertGreaterThan(second.writes ?? 0, first.writes ?? 0, "holdsUnpublishedWrites compares these")
    }

    // MARK: - Reproductions of the queue, printing what they find

    /// A `###` is no section: naming one changes nothing and says where it is.
    func testASubsectionIsRefusedAsASection() async throws {
        try await open(try image())
        let text = "Summary.\n\n## Flow\n\nBody.\n\n### Sub\n\nSubtext.\n"
        try await post("/v1/set/description", ["text": text])
        await assertRefused("is a `###` subsection of `## Flow`") { _ = try await self.post("/v1/set/description", ["section": "Sub", "text": "New."]) }
        await assertRefused("section names a `## ` heading") { _ = try await self.post("/v1/set/description", ["section": "### Sub", "text": "New."]) }
        let now = try await read("/v1/description")["text"] as? String
        XCTAssertEqual(now, text)
    }

    /// The conflict Ghidra blames on concurrency says what holds the name.
    func testASignatureSaysWhichLocalHoldsAName() async throws {
        try await open(try image())
        let rows = try await read("/v1/functions?limit=500")["functions"] as? [[String: Any]] ?? []
        for row in rows {
            let entry = try XCTUnwrap(row["entry"] as? String)
            let stored = (try await read("/v1/function/\(entry)")["locals"] as? [[String: Any]] ?? [])
                .first { ($0["storage"] as? String)?.hasPrefix("Stack[-") == true }
            guard let stored else { continue }
            try await post("/v1/rename/variable", ["function": entry, "storage": stored["storage"] as Any, "name": "TakenName"])
            await assertRefused("is held by a local") {
                _ = try await self.post("/v1/set/signature", ["address": entry, "signature": "void QFn(UINT32 TakenName)"])
            }
            return
        }
        throw XCTSkip("no function with a local on the stack")
    }

    private func assertRefused(_ words: String, _ call: () async throws -> Void, line: UInt = #line) async {
        do {
            try await call()
            XCTFail("not refused", line: line)
        } catch {
            XCTAssertTrue("\(error)".contains(words), "\(error)", line: line)
        }
    }


    /// A label on an `EFI_GUID` datum is the GUID registry's name for the
    /// bytes there: another name is refused with the registry's, a GUID the
    /// registry lacks is refused until it is added, the registry's name is
    /// taken.
    func testAGuidLabelIsCheckedAgainstTheRegistry() async throws {
        try await open(try image())
        let data = try await read("/v1/data?limit=5000")["data"] as? [[String: Any]] ?? []
        let datum = try XCTUnwrap(data.first { ($0["type"] as? String) == "EFI_GUID" }, "no EFI_GUID datum")
        let address = try XCTUnwrap(datum["address"] as? String)
        let at = try await read("/v1/guid-at?address=\(address)")
        let guid = try XCTUnwrap(at["guid"] as? String)
        XCTAssertEqual(at["datum_type"] as? String, "EFI_GUID")

        // A seeded registry that lacks this GUID.
        _ = try store.offerGuid(GuidOffer(guid: "11111111-2222-3333-4444-555555555555", name: "gOtherPpiGuid",
                                          kind: .ppi, source: .review(module: module, address: "0x1")), by: "seed")
        do {
            try await post("/v1/set/data", ["address": address, "name": "gTestPpiGuid"])
            XCTFail("a GUID the registry lacks")
        } catch let error as GhidraHostError {
            XCTAssertTrue(error.message.contains("ghidra_guid_add"), error.message)
        }
        _ = try store.offerGuid(GuidOffer(guid: guid, name: "gTestPpiGuid", kind: .ppi,
                                          source: .review(module: module, address: address)), by: "seed")
        do {
            try await post("/v1/set/data", ["address": address, "name": "gWrongPpiGuid", "type": "EFI_GUID"])
            XCTFail("another name than the registry's")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409)
            XCTAssertTrue(error.message.contains("gTestPpiGuid"), error.message)
        }
        try await post("/v1/set/data", ["address": address, "name": "gTestPpiGuid"])
        let named = try await read("/v1/data?limit=5000")["data"] as? [[String: Any]] ?? []
        XCTAssertEqual(named.first { ($0["address"] as? String) == address }?["name"] as? String, "gTestPpiGuid")
    }
}
