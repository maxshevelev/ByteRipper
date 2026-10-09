import Foundation
import LenovoDMI
import UEFIImage

/// Which drivers of the image ask for which entries of the store — the
/// firmware's own answer to "what is this entry for".
///
/// Read off the image itself rather than written down from one dump: the
/// drivers differ from platform to platform (an IdeaPad has no RGB keyboard
/// driver to read `0x0015`), and a list taken from one machine would be a
/// claim about another. Every PE and TE image in the tree is searched for the
/// keys it names (`LenovoDMIKeyReferences`).
public struct LenovoDMIFirmwareReaders: Equatable, Sendable {
    /// The drivers that name each key, by the name the image gives them —
    /// the UI section's, or the file's GUID — sorted.
    public var drivers: [LenovoDMIKey: [String]]

    public init(drivers: [LenovoDMIKey: [String]]) {
        self.drivers = drivers
    }

    public func drivers(of key: LenovoDMIKey) -> [String] { drivers[key] ?? [] }

    /// Parses `image` and searches each driver for keys under `namespaces` —
    /// the namespaces the store holds, so a key under one the store does not
    /// use is not looked for. Seconds for an image with compressed volumes;
    /// run it off the main actor.
    public static func scan(_ image: [UInt8], namespaces: [[UInt8]]) -> LenovoDMIFirmwareReaders {
        let parsed = UEFIParser.parse(image, readsProtectedRanges: false)
        let readers = SpaceReaders(file: ImageReader(image))
        var found: [LenovoDMIKey: Set<String>] = [:]
        // Each code section belongs to the file nearest above it: a driver
        // inside a compressed volume is that driver, not the file the volume
        // is stored in.
        func walk(_ node: UEFINode, in file: UEFINode?) {
            let file = node.kind == .file ? node : file
            if node.kind == .section, let file,
               node.name.contains("PE32") || node.name.contains("TE"),
               let reader = readers.reader(for: node.space), let code = reader.bytes(node.body) {
                let name = file.name.isEmpty ? (file.guid.map { "\($0)" } ?? "") : file.name
                for key in LenovoDMIKeyReferences.keys(in: code, namespaces: namespaces) {
                    found[key, default: []].insert(name)
                }
            }
            for child in node.children { walk(child, in: file) }
        }
        for root in parsed.roots { walk(root, in: nil) }
        return LenovoDMIFirmwareReaders(drivers: found.mapValues { $0.sorted() })
    }
}
