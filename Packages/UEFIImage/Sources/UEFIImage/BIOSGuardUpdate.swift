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
    static let textStart: UInt64 = 0x11
    static let blockHeaderSize: UInt64 = 0x30
    /// The signature's own header, then an RSA-2048 or an RSA-3072 key and
    /// signature: modulus, a 4-byte exponent, signature.
    static let signatureSizes: [UInt64] = [8 + 256 + 4 + 256, 8 + 384 + 4 + 384]

    /// Whether the bytes start as an update file — what lets a caller say "this
    /// is not one" before anything else is read.
    public static func isUpdate(_ bytes: [UInt8]) -> Bool {
        isUpdate(in: ImageReader(bytes), at: 0)
    }

    /// Whether an update file starts at `offset`.
    public static func isUpdate(in reader: ImageReader, at offset: UInt64) -> Bool {
        reader.bytes(at: offset + 8, count: 8) == tag
    }

    /// Where everything in an update file is, read from its headers alone: the
    /// table, and where each block's data lies. Nothing of the data is copied
    /// — a tree that only wants to list the entries reads a few kilobytes of a
    /// file of tens of megabytes.
    public struct Layout: Equatable, Sendable {
        public var headerSize: UInt64
        public var platform: String
        /// The entries, placed in the region the blocks make up.
        public var entries: [Entry]
        /// Each block's data, in the reader's offsets, in the order the region
        /// holds them.
        public var blocks: [Range<UInt64>]
        /// Where the last block — its signature included — ends. What follows
        /// is the vendor's own and not part of the update.
        public var end: UInt64

        /// The size of the BIOS region the blocks make up.
        public var regionSize: UInt64 {
            blocks.reduce(0) { $0 + UInt64($1.count) }
        }
    }

    public static func layout(in reader: ImageReader, at offset: UInt64 = 0) -> Result<Layout, Problem> {
        guard isUpdate(in: reader, at: offset), let size = reader.uint32(at: offset) else {
            return .failure(.notAnUpdate)
        }
        let headerSize = UInt64(size)
        guard headerSize >= textStart, offset + headerSize <= reader.count,
              let text = reader.bytes(at: offset + textStart, count: headerSize - textStart)
        else { return .failure(.notAnUpdate) }

        let lines = table(in: text[...])
        let total = lines.reduce(0) { $0 + $1.blockCount }
        guard total > 0 else { return .failure(.noEntries) }

        var blocks: [Range<UInt64>] = []
        var platform = ""
        var at = offset + headerSize
        for index in 0..<total {
            guard at + blockHeaderSize <= reader.count else { return .failure(.truncated(block: index)) }
            guard let id = platformID(reader, at + 4), index == 0 || id == platform else {
                return .failure(.notABlock(block: index))
            }
            platform = id
            guard let attributes = reader.uint32(at: at + 0x14),
                  let scriptSize = reader.uint32(at: at + 0x1C),
                  let dataSize = reader.uint32(at: at + 0x20)
            else { return .failure(.truncated(block: index)) }
            let dataStart = at + blockHeaderSize + UInt64(scriptSize)
            let dataEnd = dataStart + UInt64(dataSize)
            guard dataEnd <= reader.count else { return .failure(.truncated(block: index)) }
            blocks.append(dataStart..<dataEnd)
            at = dataEnd
            if attributes & 1 != 0 {
                guard let signature = signatureSize(reader, after: at, platform: platform,
                                                    isLast: index == total - 1)
                else { return .failure(.truncated(block: index)) }
                at += signature
            }
        }

        var entries: [Entry] = []
        var block = 0
        var start: UInt64 = 0
        for line in lines {
            let length = blocks[block..<(block + line.blockCount)].reduce(0) { $0 + UInt64($1.count) }
            entries.append(Entry(name: line.name, key: line.key, blockCount: line.blockCount,
                                 range: start..<(start + length)))
            block += line.blockCount
            start += length
        }
        return .success(Layout(headerSize: headerSize, platform: platform, entries: entries,
                               blocks: blocks, end: at))
    }

    /// The BIOS region the blocks make up, read out of `reader`; nil when the
    /// reader no longer holds them.
    public static func region(of layout: Layout, in reader: ImageReader) -> [UInt8]? {
        var region: [UInt8] = []
        region.reserveCapacity(Int(layout.regionSize))
        for block in layout.blocks {
            guard let bytes = reader.bytes(block) else { return nil }
            region += bytes
        }
        return region
    }

    public static func parse(_ bytes: [UInt8]) -> Result<BIOSGuardUpdate, Problem> {
        let reader = ImageReader(bytes)
        return layout(in: reader).flatMap { layout in
            guard let region = region(of: layout, in: reader) else { return .failure(.truncated(block: 0)) }
            return .success(BIOSGuardUpdate(platform: layout.platform, entries: layout.entries, region: region))
        }
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
    static func platformID(_ reader: ImageReader, _ at: UInt64) -> String? {
        guard let field = reader.bytes(at: at, count: 16) else { return nil }
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
    static func signatureSize(_ reader: ImageReader, after at: UInt64, platform: String, isLast: Bool) -> UInt64? {
        let fitting = signatureSizes.filter { at + $0 <= reader.count }
        guard !isLast else { return fitting.first }
        return fitting.first { size in
            at + size + blockHeaderSize <= reader.count && platformID(reader, at + size + 4) == platform
        } ?? fitting.first
    }
}

extension Parser {
    /// The update file starting at `offset`, as the node over its header and
    /// blocks; nil when there is none, which is the usual answer.
    ///
    /// Its children are not read here: they are in the region the blocks
    /// assemble to, which is a copy of megabytes, and the tree makes it when
    /// the row is opened (`TreeMaterialization`), as it decodes a compressed
    /// section then.
    func parseBIOSGuardUpdate(at offset: UInt64, limit: UInt64, depth: Int) -> UEFINode? {
        guard BIOSGuardUpdate.isUpdate(in: reader, at: offset),
              case .success(let layout) = BIOSGuardUpdate.layout(in: reader, at: offset),
              layout.end <= limit
        else { return nil }
        return UEFINode(
            kind: .biosGuardUpdate,
            name: "AMI BIOS Guard update",
            header: offset..<(offset + layout.headerSize),
            body: (offset + layout.headerSize)..<layout.end,
            compression: SectionCompression(algorithm: "BIOS Guard", decodes: true),
            isExpandable: true,
            childDepth: depth + 1
        )
    }

    /// The entries of the update whose header is at `offset`, as rows over the
    /// assembled region: each a stretch of it, left closed until it is opened.
    func biosGuardEntries(at offset: UInt64, depth: Int) -> [UEFINode] {
        guard case .success(let layout) = BIOSGuardUpdate.layout(in: reader, at: offset) else { return [] }
        return layout.entries.map { entry in
            UEFINode(
                kind: .biosGuardEntry,
                name: entry.name,
                header: entry.range.lowerBound..<entry.range.lowerBound,
                body: entry.range,
                isExpandable: !entry.range.isEmpty,
                childDepth: depth + 1
            )
        }
    }
}
