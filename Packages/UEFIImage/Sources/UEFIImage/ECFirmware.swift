import Foundation

/// An embedded controller's firmware image, recognised by what it carries
/// (`UEFI_IMAGE_FORMAT.md` §9): an ITE image by the signature block and
/// identification near its start (`ITEFirmware`), a Microchip MEC image by the
/// `PHCM` header it opens with.
///
/// A block that holds EC firmware often holds more than one image — a second
/// controller's, a copy for recovery — each on a 4 KiB boundary. Nothing in
/// either format that is known says how long an image is. An image whose bytes
/// begin with the whole of an earlier one is a copy of it and as long as it —
/// which keeps what follows the last copy, a Dell EC region's log, out of it;
/// any other image runs to its last written byte before the next one. An
/// erased run inside does not end it: an ITE image keeps data at the end of
/// its slot, past 40 KiB of erased bytes.
public struct ECImage: Equatable, Sendable {
    public enum Vendor: Equatable, Sendable {
        /// The identification the image carries, such as `ITE8380-EC-V1.43`.
        case ite(identification: String)
        /// A `PHCM` header. No string in the image names the chip or the
        /// version, and the header's fields are not decoded.
        case microchip
    }

    public var vendor: Vendor
    public var start: UInt64
    /// How long the image is: to its last written byte, or the length of the
    /// earlier image it copies.
    public var written: UInt64
    /// Where the earlier image this one copies byte for byte starts.
    public var copyOf: UInt64?

    /// What the image says it is, in the image's own words where it has any.
    public var name: String {
        switch vendor {
        case .ite(let identification): return identification
        case .microchip: return "Microchip MEC image"
        }
    }

    /// `PHCM`, `MCHP` reversed: the header Microchip's MEC boot ROM reads.
    static let microchipSignature: UInt32 = 0x4D43_4850
    static let step: UInt64 = 0x1000

    /// The image starting at `start`, or nil when none does.
    static func image(at start: UInt64, limit: UInt64, in reader: ImageReader) -> Vendor? {
        if reader.uint32(at: start) == microchipSignature { return .microchip }
        if let ite = ITEFirmware.read(at: start, limit: limit, in: reader) {
            return .ite(identification: ite.identification)
        }
        return nil
    }

    /// Every image in `range`, at each 4 KiB boundary, each running to its
    /// last written byte before the next one starts.
    public static func all(in range: Range<UInt64>, reader: ImageReader, emptyByte: UInt8 = 0xFF) -> [ECImage] {
        var starts: [(UInt64, Vendor)] = []
        var at = range.lowerBound
        while at < range.upperBound {
            if let vendor = image(at: at, limit: range.upperBound, in: reader) { starts.append((at, vendor)) }
            at += step
        }
        var images: [ECImage] = []
        for (index, found) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].0 : range.upperBound
            let written = lastWritten(in: found.0..<end, reader: reader, emptyByte: emptyByte) - found.0
            var image = ECImage(vendor: found.1, start: found.0, written: written)
            if let original = image.copied(from: images, reader: reader) {
                image.written = original.written
                image.copyOf = original.start
            }
            images.append(image)
        }
        return images
    }

    /// The image's bytes, as far as written: what a copy is told by.
    public var range: Range<UInt64> { start..<(start + written) }

    /// The end of the last byte in `range` that is not `emptyByte`, or the
    /// range's start when every byte is.
    static func lastWritten(in range: Range<UInt64>, reader: ImageReader, emptyByte: UInt8) -> UInt64 {
        var end = range.upperBound
        while end > range.lowerBound {
            let start = end - min(step, end - range.lowerBound)
            guard let bytes = reader.bytes(at: start, count: end - start) else { return end }
            if let last = bytes.lastIndex(where: { $0 != emptyByte }) {
                return start + UInt64(last) + 1
            }
            end = start
        }
        return range.lowerBound
    }

    /// The earlier image whose whole bytes this one begins with, if any — of
    /// the same vendor, and no longer than what this one has written.
    func copied(from earlier: [ECImage], reader: ImageReader) -> ECImage? {
        earlier.first { original in
            original.vendor == vendor && original.written > 0 && original.written <= written
                && reader.bytes(at: start, count: original.written) == reader.bytes(original.range)
        }
    }
}

extension ECImage {
    /// The node subtype an EC image row carries when it is a copy of an
    /// earlier image in the same block. Not UEFITool's — it classifies these
    /// bytes as padding — so it is free to say this.
    public static let copySubtype: UInt8 = 1
}

extension Parser {
    /// `node` — padding, an EC Firmware region of the flash device map, or the
    /// descriptor's EC region — read as the EC firmware it holds
    /// (`UEFI_IMAGE_FORMAT.md` §9): named by its first image, and, when it
    /// holds more than that one image at its start, given a row per image and
    /// padding for what lies between them. Nil when no image is there.
    func readingECFirmware(_ node: UEFINode, emptyByte: UInt8) -> UEFINode? {
        let images = ECImage.all(in: node.body, reader: reader, emptyByte: emptyByte)
        guard let first = images.first else { return nil }
        var read = node
        switch node.kind {
        case .padding:
            // Padding names only what opens it: an image further in is a guess
            // about the bytes before it.
            guard first.start == node.body.lowerBound else { return nil }
            read.name = "\(ITEFirmware.paddingNamePrefix)\(first.name))"
        default:
            read.name = "\(node.name) (\(first.name))"
        }
        guard images.count > 1 || first.start != node.body.lowerBound else { return read }

        var children: [UEFINode] = []
        var at = node.body.lowerBound
        for (index, image) in images.enumerated() {
            children += padding(from: at, to: image.start, emptyByte: emptyByte)
            let next = index + 1 < images.count ? images[index + 1].start : node.body.upperBound
            let end = min(image.start + roundedUp(max(image.written, 1)), next)
            children.append(UEFINode(
                kind: .ecImage,
                subtype: image.copyOf != nil ? ECImage.copySubtype : nil,
                name: image.name,
                header: image.start..<image.start,
                body: image.start..<end,
                isFixed: true
            ))
            at = end
        }
        children += padding(from: at, to: node.body.upperBound, emptyByte: emptyByte)
        read.children = children
        return read
    }

    private func roundedUp(_ size: UInt64) -> UInt64 {
        (size + ECImage.step - 1) / ECImage.step * ECImage.step
    }

    /// `nodes` with the padding and the EC Firmware map regions that hold EC
    /// firmware read as it.
    func readingECFirmware(_ nodes: [UEFINode], emptyByte: UInt8) -> [UEFINode] {
        nodes.map { node in
            let candidate = node.kind == .padding && !node.isErased
                || node.kind == .flashDeviceMapRegion && node.guid == FlashDeviceMap.ecFirmware
            guard candidate else { return node }
            return readingECFirmware(node, emptyByte: emptyByte) ?? node
        }
    }
}
