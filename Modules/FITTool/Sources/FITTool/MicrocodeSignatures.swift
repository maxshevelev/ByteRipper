import Foundation
import IntelCPUID
import UEFIImage

/// The shared-microcode table (`IntelCPUID.MicrocodeSignatures`), asked about
/// what this module holds: a file of the microcode catalogue, a signature.
///
/// A file newer than the commit the table was read at is matched by what its
/// name says of the update — revision, date, platforms and size, which a copy
/// keeps — and one that matches nothing has no extended CPUIDs said for it:
/// unknown, not none.
extension MicrocodeSignatures {
    /// The update a catalogue file is a copy of, where it serves several
    /// CPUIDs: by its path, or else by what its name says of the update.
    public func update(for entry: MicrocodeCatalogueEntry) -> Update? {
        guard entry.vendor == .intel else { return nil }
        if let update = update(file: entry.path) { return update }
        // A copy the table has not seen: same revision, date and
        // platforms as one it has, under a CPUID that update names.
        return updates.first { update in
            update.revision == entry.revisionText && update.date == entry.date
                && update.signatures.contains {
                    $0.cpuid == entry.cpuidText
                        && UInt32($0.platforms, radix: 16) == entry.platformID
                }
        }
    }

    /// The other CPUIDs a catalogue file's update serves, in the update's
    /// order, each once. Empty for an update that serves one.
    public func extendedCPUIDs(of entry: MicrocodeCatalogueEntry) -> [String] {
        update(for: entry)?.others(than: [entry.cpuidText]) ?? []
    }

    /// The CPUIDs that share a microcode update with this signature: those of
    /// the newest update that serves it and others, without it, each once.
    public func sharing(_ cpuid: UInt32) -> [String] {
        sharing(MicrocodeHeader.cpuid(cpuid))
    }
}
