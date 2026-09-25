import Foundation
import Localization

/// Something wrong with the table, or with the image around it.
///
/// Collected and shown, never thrown: a FIT worth opening a tool on is usually
/// one somebody has already edited by hand, and the defects are what the user
/// came to see. Each problem carries the offset to look at, so the panel can
/// send the dump there.
public struct FITProblem: Equatable, Sendable {
    public enum Severity: Sendable {
        /// The table breaks a rule the specification states as one (§8).
        case error
        /// Worth saying, but the table still works.
        case warning
    }

    public enum Kind: Equatable, Sendable {
        case imageHasNoPointer
        case pointerLeadsOutsideTheImage(address: UInt64)
        case noTableAtThePointer(address: UInt64)
        case tableHasNoEntries
        case tableRunsPastTheEnd(entries: UInt32)
        case firstEntryIsNotTheHeader(type: UInt8)
        case secondHeader
        /// Rows must not decrease in type: a FIT handler is allowed to stop
        /// looking at the first type past the one it wants (§3).
        case typesOutOfOrder(previous: UInt8, type: UInt8)
        case checksumMismatch(stored: UInt8, computed: UInt8)
        case noMicrocodeEntry
        case addressOutsideTheImage(address: UInt64)
        case addressNotAligned(address: UInt64)
        /// A microcode row pointing at something that is neither a microcode
        /// header nor an empty slot — the defect §11 is a post-mortem of, and
        /// the reason a tool must read what it wrote an address to.
        case notMicrocodeAtTheAddress(address: UInt64)
        case reservedIsNotZero(value: UInt8)
        /// The image keeps a Top Swap backup of the block the FIT is in, and
        /// there is no table where the backup's pointer leads.
        case topSwapBackupHasNoTable(backupAt: UInt64)
        /// The backup's FIT is not byte for byte this one.
        case topSwapTableDiffers(at: UInt64)
        /// A backup row, or what it points at inside the block, is not the same
        /// as the top block's.
        case topSwapEntryDiffers
        /// The backup holds the same FIT, but other bytes of the block differ —
        /// which is what refuses a microcode change until the copies agree.
        case topSwapBlockDiffers(backup: Range<UInt64>)
    }

    public var kind: Kind
    /// The row it is about, when it is about one.
    public var entryIndex: Int?
    /// Where to send the dump.
    public var offset: UInt64?
    /// Found in the Top Swap backup's copy of the table rather than in the
    /// table itself: `entryIndex` is a row of that copy.
    public var inBackup: Bool

    public init(_ kind: Kind, entry: Int? = nil, at offset: UInt64? = nil, inBackup: Bool = false) {
        self.kind = kind
        self.entryIndex = entry
        self.offset = offset
        self.inBackup = inBackup
    }

    public var severity: Severity {
        switch kind {
        case .reservedIsNotZero, .topSwapBackupHasNoTable, .topSwapTableDiffers,
             .topSwapEntryDiffers, .topSwapBlockDiffers:
            return .warning
        default:
            return .error
        }
    }

    public var message: String {
        inBackup ? L("Top Swap backup: %1$@", ownMessage) : ownMessage
    }

    private var ownMessage: String {
        switch kind {
        case .imageHasNoPointer:
            return L("The image is too small to hold a FIT pointer")
        case .pointerLeadsOutsideTheImage(let address):
            return L("The FIT pointer, %1$@, is outside this image", hex(address))
        case .noTableAtThePointer(let address):
            return L("No FIT signature at %1$@, where the pointer leads", hex(address))
        case .tableHasNoEntries:
            return L("The header says the table has no entries")
        case .tableRunsPastTheEnd(let entries):
            return L("The header claims %1$@ entries, which runs past the end of the image", entries)
        case .firstEntryIsNotTheHeader(let type):
            return L("The first entry is type %1$@, not the header", hex(UInt64(type)))
        case .secondHeader:
            return L("A second header entry, where there may be only one")
        case .typesOutOfOrder(let previous, let type):
            return L("Type %1$@ after type %2$@: entries must not decrease in type",
                     hex(UInt64(type)), hex(UInt64(previous)))
        case .checksumMismatch(let stored, let computed):
            return L("The table checksum is %1$@, and should be %2$@",
                     hex(UInt64(stored)), hex(UInt64(computed)))
        case .noMicrocodeEntry:
            return L("No microcode entry, and there must be at least one")
        case .addressOutsideTheImage(let address):
            return L("%1$@ is outside this image", hex(address))
        case .addressNotAligned(let address):
            return L("%1$@ is not aligned to 16 bytes", hex(address))
        case .notMicrocodeAtTheAddress(let address):
            return L("No microcode header at %1$@, and it is not an empty slot", hex(address))
        case .reservedIsNotZero(let value):
            return L("The reserved byte is %1$@, and should be zero", hex(UInt64(value)))
        case .topSwapBackupHasNoTable(let backupAt):
            return L("The Top Swap backup at %1$@ has no FIT where its pointer leads", hex(backupAt))
        case .topSwapTableDiffers(let at):
            return L("The Top Swap backup's FIT at %1$@ is not the same as this one", hex(at))
        case .topSwapEntryDiffers:
            return L("this entry, or what it points at, is not the same as in the top block")
        case .topSwapBlockDiffers(let backup):
            return L("The Top Swap backup at %1$@ holds the same FIT, but other bytes of the block differ, so microcode changes are refused until the copies agree",
                     hex(backup.lowerBound))
        }
    }

    private func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }
}
