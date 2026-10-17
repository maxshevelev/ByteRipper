import Foundation

/// The strap containers a CSME 18 image's **MIP table** keeps beside the CPU
/// message — the CSME (DBC), PMC IOE and IOE blocks of its `MipDescNvar`.
///
/// The table is the FITC partition's `smip` nvar (`MIPTableReader`): a MIP
/// descriptor of contiguous blocks, each a container the tool stitches into
/// the nvar. The block types are the tool's, and the layouts are its harness
/// documents:
///
///     type 0   CSME / DBC    CSME_smip      8 bytes
///     type 2   PMC IOE       PMC_IOE_smip   0x40
///     type 4   IOE           IOE_smip       0x3C (MTL-M) or 0xD0 (MTL-P / ARL-P)
///
/// The IOE container has two layouts at hand and they place the shared names
/// at different offsets, so a layout is chosen by the block's own length —
/// which the MIP descriptor states — and both are in the map. The CPU message
/// is a container too, but its own map (`CPUStrapMap`) reads it.
///
/// A field's place is a **bit range of its block**: `offset*8 + bit_low …
/// offset*8 + bit_high` in the document's terms, kept here as `bitOffset` and
/// `count`. The documents are byte-addressed, so a field can start at any
/// byte and still be read the same way.
public struct MIPStrapMap: Sendable {
    public struct Field: Sendable, Equatable {
        public var name: String
        /// The first bit of the block, counted from its first byte's LSB.
        public var bitOffset: Int
        public var count: Int
        public var label: String?
        public var section: String?
        public var help: String?
        public var options: [Int: String]?

        public init(name: String, bitOffset: Int, count: Int,
                    label: String? = nil, section: String? = nil,
                    help: String? = nil, options: [Int: String]? = nil) {
            self.name = name
            self.bitOffset = bitOffset
            self.count = count
            self.label = label
            self.section = section
            self.help = help
            self.options = options
        }
    }

    /// One block of the MIP descriptor, with the block type and the length
    /// that identify its layout.
    public struct Container: Sendable, Equatable {
        public var name: String
        public var blockType: Int
        /// The block's length in bytes, as the MIP descriptor states it.
        public var length: Int
        public var fields: [Field]

        public init(name: String, blockType: Int, length: Int, fields: [Field]) {
            self.name = name
            self.blockType = blockType
            self.length = length
            self.fields = fields
        }
    }

    public var name: String
    public var containers: [Container]

    public init(name: String, containers: [Container]) {
        self.name = name
        self.containers = containers
    }

    /// The layouts of a generation's non-CPU MIP containers, or nil where the
    /// generation keeps none this way.
    public static func forME(major: Int) -> MIPStrapMap? {
        major == 18 ? .csme18 : nil
    }

    public static var all: [MIPStrapMap] { [.csme18] }
}

/// One strap of a container as an image holds it.
public struct MIPStrapReading: Codable, Sendable, Equatable {
    public var name: String
    public var value: Int

    public init(name: String, value: Int) {
        self.name = name
        self.value = value
    }
}

/// One container of the image's MIP table, read through its layout.
public struct MIPStrapContainerReadings: Codable, Sendable, Equatable {
    /// "CSME", "PMC IOE" or "IOE" — the tool's container name.
    public var name: String
    public var blockType: Int
    public var length: Int
    public var readings: [MIPStrapReading]

    public init(name: String, blockType: Int, length: Int,
                readings: [MIPStrapReading]) {
        self.name = name
        self.blockType = blockType
        self.length = length
        self.readings = readings
    }
}

extension MIPTableReader {
    /// Every container of the payload's MIP table that `map` has a layout for,
    /// in the map's order. Nil where the payload holds no MIP table, or none
    /// of the map's blocks is there.
    ///
    /// A container is read only where its block type **and** length match the
    /// map — the IOE layouts of MTL-M and MTL-P differ in place, not only in
    /// size, and the wrong one would name the wrong bits.
    public static func containers(in payload: Data, map: MIPStrapMap)
        -> [MIPStrapContainerReadings]? {
        guard let table = mipTable(in: payload) else { return nil }
        var results: [MIPStrapContainerReadings] = []
        for container in map.containers {
            guard let block = table.blocks.first(where: {
                $0.type == container.blockType && $0.length == container.length
            }), block.offset >= 0, block.offset + block.length <= payload.count
            else { continue }
            let data = payload.subdata(in: block.offset..<(block.offset + block.length))
            var readings: [MIPStrapReading] = []
            for field in container.fields {
                guard field.count > 0, field.count <= 32, field.bitOffset >= 0 else { continue }
                let byte = field.bitOffset / 8
                let shift = field.bitOffset % 8
                let needed = (shift + field.count + 7) / 8
                guard needed <= 8, byte + needed <= data.count else { continue }
                var word: UInt64 = 0
                for index in 0..<needed {
                    word |= UInt64(data[byte + index]) << (8 * index)
                }
                let mask: UInt64 = field.count == 64 ? .max : (1 << UInt64(field.count)) - 1
                readings.append(MIPStrapReading(
                    name: field.name,
                    value: Int(word >> UInt64(shift) & mask)))
            }
            guard !readings.isEmpty else { continue }
            results.append(MIPStrapContainerReadings(
                name: container.name, blockType: container.blockType,
                length: container.length, readings: readings))
        }
        return results.isEmpty ? nil : results
    }
}
