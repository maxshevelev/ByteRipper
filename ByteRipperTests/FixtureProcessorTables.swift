import Foundation
@testable import FITToolUI

/// The processor tables the app's tests read: the copy of
/// `github.com/maxshevelev/IntelCPUID`'s two files the FITTool module's tests
/// keep in `Modules/FITTool/Tests/Fixtures/IntelCPUID`, read off the source
/// tree. The app has no copy of its own, and a test does not reach GitHub —
/// so a suite that shows processor names installs these as its source.
struct FixtureProcessorTables: ProcessorTablesSource {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Modules/FITTool/Tests/Fixtures/IntelCPUID", isDirectory: true)

    static let names = try! Data(contentsOf: folder.appendingPathComponent("IntelCPUIDBrandNames.json"))
    static let signatures = try! Data(contentsOf: folder.appendingPathComponent("IntelMicrocodeSignatures.json"))

    /// Makes the fixtures the source and installs them now, so a panel that
    /// opens next reads them without waiting for a refresh. Installed through
    /// FITToolUI, whose copy of the tables the app reads
    /// (`ProcessorTablesForTesting`).
    @MainActor static func use() {
        FITToolSession.processorTablesSource = FixtureProcessorTables()
        try! ProcessorTablesForTesting.install(brandNames: names, signatures: signatures)
    }

    func refresh() async {}
}
