import Foundation

/// An AMI BIOS Guard update file — "PFAT" in AMI's own tag, `<model>.3xx` on
/// an ASUS support page (`UEFI_IMAGE_FORMAT.md` §1.2).
///
/// Not an image: the BIOS region cut into signed blocks, each with the script
/// the chipset runs to write it, behind a table naming what the blocks are.
/// What a bench wants of it is the region it carries, laid out as the chip
/// holds it, and which part of that region each name covers — so that is what
/// a parse is. The scripts and the signatures are read past, not checked:
/// checking a signature needs the vendor's key, and nothing here writes a
/// block the way the chipset would.
///
/// The layout is read off one vendor's file against a dump of the same board,
/// not off a published description, and the help says so.
public struct BIOSGuardUpdate: Equatable, Sendable {
    /// One line of the file's table: a part of the BIOS region the flasher
    /// writes as a unit, made of `blockCount` blocks.
    public struct Entry: Equatable, Sendable {
        /// What the table calls it — `FV_MAIN_WRAPPER`, `NVRAM`, `AsusNVRAM`.
        public var name: String
        /// The flasher's switch for it — `/P`, `/N`, `/OA` — or empty where the
        /// line names none.
        public var key: String
        public var blockCount: Int
        /// Where it lies in the BIOS region, from the region's first byte.
        public var range: Range<UInt64>

        public init(name: String, key: String, blockCount: Int, range: Range<UInt64>) {
            self.name = name
            self.key = key
            self.blockCount = blockCount
            self.range = range
        }
    }

    /// The `PlatformID` the blocks carry — `RAPTORLAKE` — as the file writes it.
    public var platform: String
    public var entries: [Entry]
    /// The BIOS region the blocks make up, in the order the chip holds it.
    public var region: [UInt8]

    /// How many blocks the file carries.
    public var blockCount: Int { entries.reduce(0) { $0 + $1.blockCount } }

    public init(platform: String, entries: [Entry], region: [UInt8]) {
        self.platform = platform
        self.entries = entries
        self.region = region
    }

    /// Why a file did not read as an update.
    public enum Problem: Error, Equatable, Sendable {
        /// No `_AMIPFAT` header at the start.
        case notAnUpdate
        /// A header whose table names no blocks.
        case noEntries
        /// The file ends inside a block: its index, from 0.
        case truncated(block: Int)
        /// What stands where a block should start does not read as one.
        case notABlock(block: Int)
    }

    static let tag = Array("_AMIPFAT".utf8)
    /// Size, checksum, tag and flags: where the table's text begins.
    static let textStart = 0x11
    static let blockHeaderSize = 0x30
    /// The signature's own header, then an RSA-2048 or an RSA-3072 key and
    /// signature: modulus, a 4-byte exponent, signature.
    static let signatureSizes = [8 + 256 + 4 + 256, 8 + 384 + 4 + 384]

    /// Whether the bytes start as an update file — what lets a caller say "this
    /// is not one" before anything else is read.
    public static func isUpdate(_ bytes: [UInt8]) -> Bool {
        bytes.count >= textStart && Array(bytes[8..<16]) == tag
    }

    public static func parse(_ bytes: [UInt8]) -> Result<BIOSGuardUpdate, Problem> {
        guard isUpdate(bytes) else { return .failure(.notAnUpdate) }
        let headerSize = Int(word(bytes, 0))
        guard headerSize >= textStart, headerSize <= bytes.count else { return .failure(.notAnUpdate) }

        let lines = table(in: bytes[textStart..<headerSize])
        let total = lines.reduce(0) { $0 + $1.blockCount }
        guard total > 0 else { return .failure(.noEntries) }

        var region: [UInt8] = []
        var sizes: [Int] = []
        var platform = ""
        var at = headerSize
        for index in 0..<total {
            guard at + blockHeaderSize <= bytes.count else { return .failure(.truncated(block: index)) }
            let id = platformID(bytes, at + 4)
            guard let id, index == 0 || id == platform else { return .failure(.notABlock(block: index)) }
            platform = id
            let attributes = word(bytes, at + 0x14)
            let scriptSize = Int(word(bytes, at + 0x1C))
            let dataSize = Int(word(bytes, at + 0x20))
            let dataStart = at + blockHeaderSize + scriptSize
            guard dataStart + dataSize <= bytes.count else { return .failure(.truncated(block: index)) }
            region.append(contentsOf: bytes[dataStart..<(dataStart + dataSize)])
            sizes.append(dataSize)
            at = dataStart + dataSize
            if attributes & 1 != 0 {
                guard let signature = signatureSize(bytes, after: at, platform: platform,
                                                    isLast: index == total - 1)
                else { return .failure(.truncated(block: index)) }
                at += signature
            }
        }

        var entries: [Entry] = []
        var block = 0
        var offset: UInt64 = 0
        for line in lines {
            let length = sizes[block..<(block + line.blockCount)].reduce(0) { $0 + UInt64($1) }
            entries.append(Entry(name: line.name, key: line.key, blockCount: line.blockCount,
                                 range: offset..<(offset + length)))
            block += line.blockCount
            offset += length
        }
        return .success(BIOSGuardUpdate(platform: platform, entries: entries, region: region))
    }

    /// The table's lines, `<n> /<KEY> <blocks> ;<NAME>`, after the title line.
    /// A line that does not read as one is not an entry; a key is optional.
    static func table(in text: ArraySlice<UInt8>) -> [(name: String, key: String, blockCount: Int)] {
        let string = String(decoding: text, as: UTF8.self)
        return string.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let parts = line.split(separator: ";", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            let fields = parts[0].split(whereSeparator: \.isWhitespace)
            guard !name.isEmpty, let last = fields.last, let count = Int(last), count > 0 else { return nil }
            let key = fields.dropLast().first { $0.hasPrefix("/") }.map(String.init) ?? ""
            return (name, key, count)
        }
    }

    /// A block's `PlatformID`: printable ASCII, NUL-padded to 16 bytes, at
    /// least one character. Nil when the 16 bytes are anything else — which is
    /// how a block that is not where it should be is told.
    static func platformID(_ bytes: [UInt8], _ at: Int) -> String? {
        let field = bytes[at..<(at + 16)]
        let text = field.prefix { $0 != 0 }
        guard !text.isEmpty, text.allSatisfy({ (0x20...0x7E).contains($0) }),
              field.dropFirst(text.count).allSatisfy({ $0 == 0 })
        else { return nil }
        return String(decoding: text, as: UTF8.self)
    }

    /// How long the signature after a block's data is. The file does not say,
    /// so each size a key can have is tried: the right one is where the next
    /// block starts with the same platform. After the last block, or where no
    /// size leads to one, it is the first that fits in the file — and a next
    /// block that is not there is then said to be missing, not this signature.
    static func signatureSize(_ bytes: [UInt8], after at: Int, platform: String, isLast: Bool) -> Int? {
        let fitting = signatureSizes.filter { at + $0 <= bytes.count }
        guard !isLast else { return fitting.first }
        return fitting.first { size in
            at + size + blockHeaderSize <= bytes.count && platformID(bytes, at + size + 4) == platform
        } ?? fitting.first
    }

    static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
