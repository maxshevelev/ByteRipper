import Foundation

/// One VSS or VSS2 variable's header, taken apart (§9): which of the four
/// header forms it is, the fields that form carries, and where its name and
/// its value lie.
///
/// The form is decided by the state and the attribute bits, the way the
/// reference parser's Kaitai struct decides it — Intel legacy by its own
/// states, authenticated by an authentication bit or by a size field that
/// reads zero, Apple by the data-checksum bit, the standard form otherwise.
/// VSS2 has neither the Intel nor the Apple form. The parser and the detail
/// panel read a variable through this one decision, so they never disagree
/// on where its value is.
///
/// The header carries no type for the value: what the value is comes from
/// the variable's name and from the bytes themselves (`NvramValue`).
public struct VSSVariable: Equatable, Sendable {
    public enum Form: Equatable, Sendable {
        /// `VARIABLE_HEADER`: 32 bytes.
        case standard
        /// The standard header and a CRC32 of the data after the GUID: 36.
        case apple
        /// `AUTHENTICATED_VARIABLE_HEADER`: a monotonic count, a time stamp
        /// and a public key index before the sizes; 60.
        case authenticated
        /// Intel's legacy header: one total size and the GUID; the name runs
        /// to its terminator and the data follows it. 28.
        case intelLegacy
    }

    public var form: Form
    public var state: UInt8
    public var reserved: UInt8
    public var attributes: UInt32
    /// The fixed header, before the name.
    public var header: Range<UInt64>
    /// The UCS-2 name, its terminator included.
    public var name: Range<UInt64>
    /// The value.
    public var data: Range<UInt64>
    public var vendorGuid: EFIGUID?
    /// The name and data sizes as the header states them; nil on the Intel
    /// form, which states only `totalSize`.
    public var nameSize: UInt32?
    public var dataSize: UInt32?
    public var totalSize: UInt32?
    public var monotonicCount: UInt64?
    public var timestamp: EFITime?
    public var publicKeyIndex: UInt32?
    /// The Apple form's CRC32 of the data.
    public var dataCRC32: UInt32?

    /// Whether the state is one a live variable has.
    public var isValid: Bool {
        switch form {
        case .intelLegacy: return state == NVRAM.vssVariableIntelValid
        default: return state == NVRAM.vssVariableValid || state == NVRAM.vssVariableAdded
        }
    }

    /// Where the variable ends: past its name and its value.
    public var end: UInt64 { max(name.upperBound, data.upperBound) }

    /// The variable whose header starts at `offset`, read no further than
    /// `limit`; nil when its fixed header is not all there. `inVss2` says the
    /// store is VSS2.
    public static func read(at offset: UInt64, limit: UInt64, inVss2: Bool, reader: ImageReader) -> VSSVariable? {
        guard let state = reader.uint8(at: offset + 2),
              let reserved = reader.uint8(at: offset + 3),
              let attributes = reader.uint32(at: offset + 4)
        else { return nil }

        if !inVss2, state == NVRAM.vssVariableIntelValid || state == NVRAM.vssVariableIntelInvalid {
            let size = NVRAM.vssIntelLegacyHeaderSize
            guard offset + size <= limit, let totalSize = reader.uint32(at: offset + 8) else { return nil }
            let end = min(max(offset + UInt64(totalSize), offset + size), limit)
            // The name is UCS-2 up to and including its terminator.
            var nameEnd = offset + size
            while nameEnd + 2 <= end {
                let unit = reader.uint16(at: nameEnd)
                nameEnd += 2
                if unit == 0 || unit == nil { break }
            }
            return VSSVariable(form: .intelLegacy, state: state, reserved: reserved, attributes: attributes,
                               header: offset..<(offset + size), name: (offset + size)..<nameEnd,
                               data: nameEnd..<end, vendorGuid: reader.guid(at: offset + 12),
                               totalSize: totalSize)
        }

        // The two size fields are read up front whatever the header turns out
        // to be: for an authenticated variable they are the monotonic count's
        // two halves. A standard variable always has a name and data, so a
        // field that reads zero cannot be one of its sizes — the variable is
        // authenticated, with a count that happens to be zero. Firmware that
        // never raises the count writes every variable this way, so the zero
        // check matters as much as the attribute bit.
        guard let sizeLow = reader.uint32(at: offset + 8),
              let sizeHigh = reader.uint32(at: offset + 12)
        else { return nil }
        let isAuth = attributes & (NVRAM.vssAttributeAuthWrite
            | NVRAM.vssAttributeTimeBasedAuth
            | NVRAM.vssAttributeAppendWrite) != 0
            || sizeLow == 0 || sizeHigh == 0

        let form: Form
        let size: UInt64
        if isAuth {
            form = .authenticated
            size = NVRAM.vssAuthHeaderSize
        } else if !inVss2, attributes & NVRAM.vssAttributeAppleDataChecksum != 0 {
            form = .apple
            size = NVRAM.vssAppleHeaderSize
        } else {
            form = .standard
            size = NVRAM.vssStandardHeaderSize
        }
        guard offset + size <= limit else { return nil }

        var variable = VSSVariable(form: form, state: state, reserved: reserved, attributes: attributes,
                                   header: offset..<(offset + size), name: 0..<0, data: 0..<0)
        let nameSize: UInt32, dataSize: UInt32
        switch form {
        case .authenticated:
            guard let n = reader.uint32(at: offset + 36), let d = reader.uint32(at: offset + 40) else { return nil }
            nameSize = n
            dataSize = d
            variable.monotonicCount = UInt64(sizeLow) | UInt64(sizeHigh) << 32
            variable.timestamp = reader.bytes(at: offset + 16, count: 16).map(EFITime.init)
            variable.publicKeyIndex = reader.uint32(at: offset + 32)
            variable.vendorGuid = reader.guid(at: offset + 44)
        case .apple:
            // The data CRC follows the GUID, which is where the standard
            // form's name would begin.
            nameSize = sizeLow
            dataSize = sizeHigh
            variable.vendorGuid = reader.guid(at: offset + 16)
            variable.dataCRC32 = reader.uint32(at: offset + 32)
        case .standard, .intelLegacy:
            nameSize = sizeLow
            dataSize = sizeHigh
            variable.vendorGuid = reader.guid(at: offset + 16)
        }
        let nameStart = offset + size
        let nameEnd = min(nameStart + UInt64(nameSize), limit)
        variable.name = nameStart..<nameEnd
        variable.data = nameEnd..<min(nameEnd + UInt64(dataSize), limit)
        variable.nameSize = nameSize
        variable.dataSize = dataSize
        return variable
    }

    /// The variable a parsed entry stands for. `inVss2` says its store is
    /// VSS2 — the one thing the entry cannot say for itself.
    public static func read(_ entry: UEFINode, inVss2: Bool, reader: ImageReader) -> VSSVariable? {
        guard entry.kind == .vssEntry else { return nil }
        return read(at: entry.header.lowerBound, limit: entry.range.upperBound, inVss2: inVss2, reader: reader)
    }

    /// The variable `entry` stands for, with its store looked up in `image`;
    /// an entry with no store above it is read as a `$VSS` one.
    public static func read(_ entry: UEFINode, in image: UEFIImage, reader: ImageReader) -> VSSVariable? {
        let store = entry.id.path.isEmpty ? nil : image.node(NodeID(Array(entry.id.path.dropLast())))
        return read(entry, inVss2: store?.kind == .vss2Store, reader: reader)
    }

    /// The name, UCS-2 up to its terminator; nil when it is not readable text.
    public func decodedName(reader: ImageReader) -> String? {
        guard let bytes = reader.bytes(name), bytes.count >= 2 else { return nil }
        var units: [UInt16] = []
        for index in stride(from: 0, to: bytes.count - 1, by: 2) {
            let unit = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        return units.isEmpty ? nil : String(decoding: units, as: UTF16.self)
    }
}

/// `EFI_TIME`, as an authenticated variable stamps its last write.
public struct EFITime: Equatable, Sendable {
    public var year: UInt16
    public var month: UInt8
    public var day: UInt8
    public var hour: UInt8
    public var minute: UInt8
    public var second: UInt8
    public var nanosecond: UInt32

    public init(_ bytes: [UInt8]) {
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        year = u16(0)
        month = bytes[2]
        day = bytes[3]
        hour = bytes[4]
        minute = bytes[5]
        second = bytes[6]
        nanosecond = UInt32(u16(8)) | UInt32(u16(10)) << 16
    }

    /// Nothing written: most firmware leaves the stamp at zero for a variable
    /// that is not time-based.
    public var isZero: Bool {
        year == 0 && month == 0 && day == 0 && hour == 0 && minute == 0 && second == 0 && nanosecond == 0
    }

    /// `2023-05-01 12:34:56`; nil when the fields are not a date. The zone
    /// is left out: the spec's revisions disagree on its sign.
    public var text: String? {
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        return String(format: "%04u-%02u-%02u %02u:%02u:%02u", year, month, day, hour, minute, second)
    }
}
