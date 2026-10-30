import Foundation
import XCTest
@testable import GhidraHost

final class UEFITypesTests: XCTestCase {
    func testGUIDsAreReadAsThePythonScriptReadsThem() {
        XCTAssertEqual(UEFITypes.registryGUID("4CF5B200-68B8-4CA5-9EEC-B23E3F50029A"),
                       "00B2F54CB868A54C9EECB23E3F50029A")
        XCTAssertNil(UEFITypes.registryGUID("4CF5B200-68B8-4CA5-9EEC"))
        XCTAssertEqual(UEFITypes.canonicalName("EfiPeiMemoryDiscoveredPpi"), "gEfiPeiMemoryDiscoveredPpiGuid")
        XCTAssertEqual(UEFITypes.canonicalName("gEfiFooGuid"), "gEfiFooGuid")
        XCTAssertEqual(UEFITypes.canonicalName("amd apob"), "gAmdapobGuid")
        XCTAssertNil(UEFITypes.canonicalName("1st"))
        let dec = """
          gEfiPeiMemoryDiscoveredPpiGuid = { 0xf894643d, 0xc449, 0x42d1, { 0x8e, 0xa8, 0x85, 0xbd, 0xd8, 0xc6, 0x5b, 0xde }}
          gSecond = { 0xf894643d, 0xc449, 0x42d1, { 0x8e, 0xa8, 0x85, 0xbd, 0xd8, 0xc6, 0x5b, 0xde }}
        """
        let found = UEFITypes.decGUIDs(dec)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.1, "gEfiPeiMemoryDiscoveredPpiGuid")
        XCTAssertEqual(found.first?.0, "3D6494F849C4D1428EA885BDD8C65BDE")
    }

    /// The table built here from the cached EDK2 and catalogue equals the
    /// cached one; skipped where no cache was built on this machine.
    func testTheTableEqualsTheCachedOne() throws {
        let paths = UEFITypes.Paths(root: UEFITypes.cacheRoot)
        guard FileManager.default.fileExists(atPath: paths.guidsTSV.path),
              FileManager.default.fileExists(atPath: paths.edk2.path) else {
            throw XCTSkip("no GUID table built on this machine")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("guids-\(UUID()).tsv")
        defer { try? FileManager.default.removeItem(at: out) }
        try UEFITypes.writeTable(edk2: paths.edk2, csv: paths.guidsCSV, to: out)
        XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: paths.guidsTSV))
    }
}

/// The tarball path against the cached headers: the same ones. Downloads EDK2
/// from GitHub; run with `FETCH_EDK2=1`.
final class UEFITypesFetchTests: XCTestCase {
    func testTheTarballHoldsTheCachedHeaders() async throws {
        guard ProcessInfo.processInfo.environment["FETCH_EDK2"] == "1" else {
            throw XCTSkip("FETCH_EDK2 is not 1")
        }
        let clone = UEFITypes.Paths(root: UEFITypes.cacheRoot).edk2
        guard FileManager.default.fileExists(atPath: clone.path) else { throw XCTSkip("no clone to compare with") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("edk2-\(UUID())")
        defer { try? FileManager.default.removeItem(at: target) }
        try await UEFITypes.fetchEDK2(into: target)
        func files(_ given: URL) -> Set<String> {
            var found = Set<String>()
            let root = given.resolvingSymlinksInPath()
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
                if !path.hasPrefix(".git") { found.insert(path) }
            }
            return found
        }
        let ours = files(target)
        XCTAssertEqual(ours, files(clone))
        for path in ours.sorted().prefix(50) {
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(path)),
                           try Data(contentsOf: clone.appendingPathComponent(path)), path)
        }
        print("EDK2 tarball: \(ours.count) files")
    }
}
