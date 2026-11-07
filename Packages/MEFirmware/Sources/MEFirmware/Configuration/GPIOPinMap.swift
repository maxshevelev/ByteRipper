import Foundation

/// The pins the CSME firmware may drive, as Flash Image Tool names them.
///
/// The tool's layout documents carry five value classes behind a feature pin —
/// the feature set (`GPIO_TOUCH_FEATURE_ID`), the usage (`INTEGRATED_TOUCH_1`),
/// the owner (`CSME_MODE`), the pad mode (`NATIVE_FUNCTION_1`) and the GPIO
/// group (`GPP_E`) — and the image carries the configured pins in
/// `/home/gpio/csme_pins`, the file the `MeFeaturePins` class's
/// `ProcessFeatureGpios` action writes. Neither the file nor the names are in
/// any published specification: the map is emitted from the tool's own classes
/// by `Skills/me-eom-structures/scripts/gpio_map.py`, and `GPIOPinReader` reads
/// the file's records through it.
///
/// The record's shape is the generation's, not the map's:
///
/// - **CSME 11** writes 20-byte records of five little-endian dwords — usage,
///   group, pad, ownership, pad mode — the fields its `GpioCsmeFeature` class
///   declares. Verified on a CSME 11 image: every record's usage, group and pad
///   match the defaults Flash Image Tool 11 gives the same usage
///   (`NFC_RST` = GPP_E_4, `NFC_IRQ` = GPP_E_12, `FWUPDATE` = GPP_B_15).
/// - **CSME 12 and later** write 12-byte records of packed bytes — feature id,
///   group, pad, reserved, usage, reserved, ownership, pad mode, then four
///   reserved bytes — the field set FIT 12's class declares, plus the pad mode
///   the file keeps. Verified on four CSME 12 images: an SMT set (feature 3,
///   usage 12/13, group C, pads 6/7, native function 1), a CPU detection pin
///   (feature 2, usage 5) and two touch pins (feature 1, usage 0/1).
///
/// A file whose records do not validate against the map is not read: the reader
/// returns nil rather than names for numbers it cannot stand behind.
public struct GPIOPinMap: Sendable {
    /// The map's name for people, not for the screen.
    public var name: String
    /// Feature set (`GpioCsmeFeatureIdValues`). Empty on CSME 11, whose pin
    /// file carries no feature id.
    public var features: [Int: String]
    /// Usage (`GpioCsmeFunctionValues`).
    public var usages: [Int: String]
    /// Owner (`GpioOwnershipValues`).
    public var ownerships: [Int: String]
    /// Pad mode (`GpioPadModeValues`).
    public var padModes: [Int: String]
    /// GPIO group (`GpioGroupValues`). A number the tool's documents disagree
    /// about — GPP_J and GPD both take 9 in one family — is absent, and the
    /// reading shows the number instead of a name.
    public var groups: [Int: String]

    public init(name: String, features: [Int: String] = [:],
                usages: [Int: String], ownerships: [Int: String],
                padModes: [Int: String], groups: [Int: String]) {
        self.name = name
        self.features = features
        self.usages = usages
        self.ownerships = ownerships
        self.padModes = padModes
        self.groups = groups
    }

    /// The map of a ME generation's major number, or nil where none was emitted
    /// (CSME 16 and 18 keep their settings in MFIT's database, which does not
    /// carry these classes).
    public static func forME(major: Int) -> GPIOPinMap? {
        switch major {
        case 11: return .csme11
        case 12: return .csme12
        case 13: return .csme13
        case 14: return .csme14
        case 15: return .csme15
        default: return nil
        }
    }
}

/// One configured feature pin.
public struct GPIOPin: Codable, Sendable, Equatable {
    /// The feature set's name (`GPIO_TOUCH_FEATURE_ID`); nil on CSME 11, whose
    /// record carries none, and where the number has no name in the map.
    public var feature: String?
    public var featureID: Int?
    /// The usage's name (`INTEGRATED_TOUCH_1`), nil where the map has none.
    public var usage: String?
    public var usageID: Int
    /// The group's name (`GPP_E`), nil where the tool's documents disagree.
    public var group: String?
    public var groupID: Int
    public var pad: Int
    public var ownership: String
    public var ownershipID: Int
    public var padMode: String
    public var padModeID: Int

    public init(feature: String?, featureID: Int?, usage: String?, usageID: Int,
                group: String?, groupID: Int, pad: Int,
                ownership: String, ownershipID: Int,
                padMode: String, padModeID: Int) {
        self.feature = feature
        self.featureID = featureID
        self.usage = usage
        self.usageID = usageID
        self.group = group
        self.groupID = groupID
        self.pad = pad
        self.ownership = ownership
        self.ownershipID = ownershipID
        self.padMode = padMode
        self.padModeID = padModeID
    }

    /// The pin as the tool writes a setting (`GPP_E_4`), or its number where
    /// the group's name is one the documents disagree about.
    public var pinName: String {
        group.map { "\($0)_\(pad)" } ?? "\(groupID):\(pad)"
    }
}

/// Reads `/home/gpio/csme_pins`.
public enum GPIOPinReader {
    /// The record's bytes each generation writes, from the shapes verified on
    /// the images at hand (`GPIOPinMap` says which images).
    static func recordSize(forMajor major: Int) -> Int {
        major == 11 ? 20 : 12
    }

    /// The pins the file records, or nil where its bytes are not a pin file of
    /// this generation's shape: an empty file (what a platform images with no
    /// feature pins carries), a length that is not whole records, or a record
    /// whose owner, pad mode or padding cannot be true of any pin.
    public static func pins(in bytes: Data, map: GPIOPinMap,
                            major: Int) -> [GPIOPin]? {
        let size = recordSize(forMajor: major)
        guard !bytes.isEmpty, bytes.count % size == 0,
              bytes.count / size <= 256 else { return nil }
        let count = bytes.count / size
        var pins: [GPIOPin] = []
        pins.reserveCapacity(count)
        for index in 0..<count {
            let base = bytes.startIndex + index * size
            let featureID: Int?
            let usageID: Int
            let groupID: Int
            let pad: Int
            let ownershipID: Int
            let padModeID: Int
            if major == 11 {
                featureID = nil
                usageID = Int(u32(bytes, at: base))
                groupID = Int(u32(bytes, at: base + 4))
                pad = Int(u32(bytes, at: base + 8))
                ownershipID = Int(u32(bytes, at: base + 12))
                padModeID = Int(u32(bytes, at: base + 16))
            } else {
                featureID = Int(bytes[base])
                groupID = Int(bytes[base + 1])
                pad = Int(bytes[base + 2])
                usageID = Int(bytes[base + 4])
                ownershipID = Int(bytes[base + 6])
                padModeID = Int(bytes[base + 7])
            }
            // A pin's owner is one of four modes and its pad mode one of five,
            // and a pad number is a byte of a GPIO community. A record that
            // says otherwise is not this file's shape, whatever its length.
            guard (0...3).contains(ownershipID), (0...4).contains(padModeID),
                  pad < 64, groupID < 32 || groupID == 0xFF else { return nil }
            pins.append(GPIOPin(
                feature: featureID.flatMap { map.features[$0] },
                featureID: featureID,
                usage: map.usages[usageID],
                usageID: usageID,
                group: map.groups[groupID],
                groupID: groupID,
                pad: pad,
                ownership: map.ownerships[ownershipID] ?? "\(ownershipID)",
                ownershipID: ownershipID,
                padMode: map.padModes[padModeID] ?? "\(padModeID)",
                padModeID: padModeID))
        }
        return pins
    }

    private static func u32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(data[index]) | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }
}

public extension GPIOPinMap {
    /// The feature pin maps emitted from Flash Image Tool's own classes, one per
    /// generation (`gpio_map.py`).
    static var all: [GPIOPinMap] {
        [.csme11, .csme12, .csme13, .csme14, .csme15]
    }
}
