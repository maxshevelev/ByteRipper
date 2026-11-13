import Foundation
@testable import FITTool

/// The processor tables the tests read: a copy of
/// `github.com/maxshevelev/IntelCPUID`'s two files in
/// `Tests/Fixtures/IntelCPUID`, read off the source tree. The app has no copy
/// of its own — it reads the repository at run time — so a test that asks
/// what a CPUID is installs these first. Refresh them from the repository
/// when its data changes what a test asserts.
enum TestTables {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/IntelCPUID", isDirectory: true)

    static let tables: ProcessorTables = {
        let names = try! Data(contentsOf: folder.appendingPathComponent("IntelCPUIDBrandNames.json"))
        let signatures = try! Data(contentsOf: folder.appendingPathComponent("IntelMicrocodeSignatures.json"))
        return try! ProcessorTables.decode(brandNames: names, signatures: signatures)
    }()

    static func install() { ProcessorTables.install(tables) }
}
