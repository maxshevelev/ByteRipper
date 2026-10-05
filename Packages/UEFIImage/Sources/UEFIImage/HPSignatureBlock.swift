import Foundation

/// The block HP puts in front of what it signs (`UEFI_IMAGE_FORMAT.md` §9):
/// on a 4 KiB boundary, in the padding before the main volume and before the
/// boot block, two ranges, an RSA signature and a payload naming the BIOS
/// version and its date. Found on four HP boards, Intel and AMD; the layout is
/// read off those dumps and nothing published, and the help says so.
///
/// ```
/// 0x00  0, version (2 or 3), 0, S — the signature's length (0x100, 0x180)
/// 0x10  two ranges: address, length, 0xFFFFFFFF, 0
/// 0x30  the signature, S bytes, then S bytes of FF
/// 0x30+2S  the payload's length L, a second dword, then L bytes:
///          +0x08 a word, +0x10 the BIOS version (16 bytes, NUL-padded),
///          +0x20 the date — a 32-bit year, a 16-bit month and day
/// then     3 × S bytes nobody has read
/// ```
///
/// A version-3 payload also holds a 40-character hex id at `0x368`, the same
/// in both blocks of a board, and a 48-byte digest at `0x43A`: in the block
/// whose two ranges start at one address, SHA-384 of the second range — on
/// all three boards that carry one. What the other block's digest covers is
/// not known, and a version-2 block holds no digest of its ranges.
public struct HPSignatureBlock: Equatable, Sendable {
    public struct SignedRange: Equatable, Sendable {
        public var address: UInt32
        public var length: UInt32
    }

    public static let alignment: UInt64 = 0x1000

    public var offset: UInt64
    public var version: UInt32
    /// Bytes: 0x180 is RSA-3072, 0x100 RSA-2048.
    public var signatureLength: UInt32
    public var ranges: [SignedRange]
    public var payloadLength: UInt32
    public var biosVersion: String
    public var year: UInt32
    public var month: UInt16
    public var day: UInt16
    /// Version 3's 40-character hex id.
    public var identifier: String?
    /// Version 3's digest, where the layout puts it.
    public var digest: [UInt8]?
    /// Header, signature, payload and the three blocks after it.
    public var length: UInt64

    public var range: Range<UInt64> { offset..<(offset + length) }

    /// `YYYY-MM-DD`.
    public var date: String { String(format: "%04u-%02u-%02u", year, month, day) }

    /// The signature's algorithm by its length.
    public var signatureName: String {
        switch signatureLength {
        case 0x100: return "RSA-2048"
        case 0x180: return "RSA-3072"
        default: return String(format: "%u bytes", signatureLength)
        }
    }

    /// Whether the digest is the one this layout is known to hold: SHA-384 of
    /// the second range, in a version-3 block whose ranges start at one
    /// address. Any other block's is shown and not checked.
    public var digestCoversSecondRange: Bool {
        version == 3 && digest != nil && ranges.count == 2 && ranges[0].address == ranges[1].address
    }

    static let identifierOffset: UInt64 = 0x368
    static let digestOffset: UInt64 = 0x43A
    static let digestLength: UInt64 = 48

    /// The block at `offset`, when every field reads as one and its length
    /// ends before `limit`; nil otherwise, saying nothing.
    public static func read(at offset: UInt64, limit: UInt64, in reader: ImageReader) -> HPSignatureBlock? {
        guard reader.uint32(at: offset) == 0,
              let version = reader.uint32(at: offset + 4), version == 2 || version == 3,
              reader.uint32(at: offset + 8) == 0,
              let signature = reader.uint32(at: offset + 12), signature == 0x100 || signature == 0x180
        else { return nil }
        var ranges: [SignedRange] = []
        for index in 0..<UInt64(2) {
            let record = offset + 0x10 + index * 0x10
            guard let address = reader.uint32(at: record), address != 0,
                  let length = reader.uint32(at: record + 4), length != 0,
                  reader.uint32(at: record + 8) == 0xFFFF_FFFF,
                  reader.uint32(at: record + 12) == 0
            else { return nil }
            ranges.append(SignedRange(address: address, length: length))
        }
        let s = UInt64(signature)
        let payload = 0x30 + 2 * s
        // The signature is followed by as many bytes of nothing.
        guard reader.isFilled((offset + 0x30 + s)..<(offset + payload), with: 0xFF),
              let payloadLength = reader.uint32(at: offset + payload), payloadLength >= 0x28
        else { return nil }
        let length = payload + 8 + UInt64(payloadLength) + 3 * s
        guard length <= alignment, offset + length <= limit,
              let fields = reader.bytes(at: offset + payload, count: 0x28)
        else { return nil }
        let at = offset + payload
        guard let year = reader.uint32(at: at + 0x20), (2000...2099).contains(year),
              let month = reader.uint16(at: at + 0x24), (1...12).contains(month),
              let day = reader.uint16(at: at + 0x26), (1...31).contains(day)
        else { return nil }
        let versionBytes = fields[0x10..<0x20].prefix { $0 != 0 }
        guard !versionBytes.isEmpty, versionBytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }

        var identifier: String?
        var digest: [UInt8]?
        if version == 3, digestOffset + digestLength <= payload + 8 + UInt64(payloadLength) {
            if let text = reader.bytes(at: offset + identifierOffset, count: 40),
               text.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) {
                identifier = String(decoding: text, as: UTF8.self)
            }
            digest = reader.bytes(at: offset + digestOffset, count: digestLength)
        }
        return HPSignatureBlock(
            offset: offset, version: version, signatureLength: signature, ranges: ranges,
            payloadLength: payloadLength, biosVersion: String(decoding: versionBytes, as: UTF8.self),
            year: year, month: month, day: day, identifier: identifier, digest: digest, length: length
        )
    }
}

extension Parser {
    /// `nodes` with HP's signature blocks in their padding read out as rows,
    /// each stretch keeping its place, range and name (§9). Looked for on the
    /// 4 KiB boundaries of the file inside every stretch of written padding,
    /// and in the padding rows read into one.
    func readingHPSignatureBlocks(_ nodes: [UEFINode], emptyByte: UInt8) -> [UEFINode] {
        nodes.map { node in
            guard node.kind == .padding, !ECImage.isECFirmwarePadding(node) else { return node }
            var read = node
            if !node.children.isEmpty {
                read.children = readingHPSignatureBlocks(node.children, emptyByte: emptyByte)
                return read
            }
            guard !node.isErased else { return node }
            let body = node.body
            var blocks: [HPSignatureBlock] = []
            var at = (body.lowerBound + HPSignatureBlock.alignment - 1) / HPSignatureBlock.alignment
                * HPSignatureBlock.alignment
            while at + 0x30 <= body.upperBound {
                if let block = HPSignatureBlock.read(at: at, limit: body.upperBound, in: reader) {
                    blocks.append(block)
                }
                at += HPSignatureBlock.alignment
            }
            guard !blocks.isEmpty else { return node }
            var rows: [UEFINode] = []
            var claimed = body.lowerBound
            for block in blocks {
                rows += padding(from: claimed, to: block.offset, emptyByte: emptyByte)
                rows.append(UEFINode(
                    kind: .hpSignatureBlock,
                    name: "HP signature block \(block.biosVersion)",
                    header: block.offset..<(block.offset + 0x30),
                    body: (block.offset + 0x30)..<block.range.upperBound,
                    // What it signs is named by address: it stays where it is.
                    isFixed: true
                ))
                claimed = block.range.upperBound
            }
            read.children = rows + padding(from: claimed, to: body.upperBound, emptyByte: emptyByte)
            return read
        }
    }
}
