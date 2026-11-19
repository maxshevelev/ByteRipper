import Foundation
import IntelCPUID

/// The processor tables the app's tests read: the copy of
/// `github.com/maxshevelev/IntelCPUID`'s two files the IntelCPUID package's
/// tests keep in `Packages/IntelCPUID/Tests/Fixtures`, read off the source
/// tree. The app has no copy of its own, and a test does not reach GitHub —
/// so a suite that shows processor names installs these as its source.
///
/// The app links the IntelCPUID package itself, so this bundle and the app
/// share one store: what is installed here is what the FIT panel and the
/// lookup window read.
struct FixtureProcessorTables: ProcessorTablesSource {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/IntelCPUID/Tests/Fixtures", isDirectory: true)

    static let tables: ProcessorTables = {
        let names = try! Data(contentsOf: folder.appendingPathComponent("IntelCPUIDBrandNames.json"))
        let signatures = try! Data(contentsOf: folder.appendingPathComponent("IntelMicrocodeSignatures.json"))
        return try! ProcessorTables.decode(brandNames: names, signatures: signatures)
    }()

    /// Makes the fixtures the source and installs them now, so a panel that
    /// opens next reads them without waiting for a refresh.
    static func use() {
        ProcessorTables.source = FixtureProcessorTables()
        ProcessorTables.install(tables)
    }

    /// The repository again, and nothing installed — as a launch finds it.
    static func restore() {
        ProcessorTables.source = IntelCPUIDRepository.shared
        ProcessorTables.install(.empty)
    }

    func refresh() async {}
}
