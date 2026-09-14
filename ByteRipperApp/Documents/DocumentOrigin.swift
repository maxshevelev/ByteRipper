import CryptoKit
import Foundation
import ByteRipperCore
import UEFIImage

/// Where an untitled tab's bytes came from: a part of another open document — a
/// zone, or what a compressed section decompressed to
/// (`Design/UEFI/UPDATE_IN_PARENT.md` §2) — and the way back (§3).
///
/// The parent is held weakly, by its pane and by the document the pane had at
/// the time: a pane that closed, or has opened another file since, is no longer
/// the parent. The link lives in memory with the documents and is never written
/// down — a tab saved to disk is a file, and a file has no parent.
@MainActor final class DocumentOrigin {
    /// Whether the link still leads to what the bytes were taken from.
    enum State: Equatable {
        case intact
        /// The parent tab was closed, or holds another file now.
        case parentClosed
        /// The parent's bytes at the source are no longer the bytes taken out.
        case sourceChanged
    }

    /// How the tab's bytes stand to the source.
    enum Kind: Equatable {
        /// The source's own bytes, copied out: a zone, a part a tool-module
        /// took. They go back as they are.
        case copy
        /// What the source decompresses to: it goes back compressed again.
        case decompressed
    }

    /// What putting the tab back would do, or why it cannot — decided before a
    /// byte is written.
    enum Update: Equatable {
        /// `bytes` over the parent at `offset`; `confirm` when the source has
        /// changed there since, and the overwrite has to be asked for.
        case overwrite(offset: UInt64, bytes: [UInt8], confirm: Bool)
        /// `bytes` through the rebuild planner (§6) — a decompressed body, or a
        /// zone that is a structure of the image, of whatever length.
        case rebuild(target: UEFIRebuild.Target, bytes: [UInt8], confirm: Bool)
        case refused(title: String, message: String)
    }

    private(set) weak var parent: PaneViewModel?
    private weak var parentDocument: BinaryDocument?
    /// The source's bytes in the parent's file: the zone, or the outermost
    /// compressed section a decompressed body came out of. It moves with an
    /// update that changed its length.
    private(set) var sourceRange: Range<UInt64>
    /// What the part is called there — the zone's or the section's name.
    let partName: String
    /// What the bytes are, for a tool-module opened on the tab (§2.1): a
    /// decompressed body is a run of sections, not an image to scan.
    let layout: UEFIRootLayout
    let kind: Kind
    /// Where the bytes go back to through the rebuild planner, when the part is
    /// something the image's structure can be laid out again around.
    let rebuildTarget: UEFIRebuild.Target?

    /// The tab's bytes as they were taken out: what its bytes read as modified
    /// against, and what Revert to Original goes back to. It does not move on
    /// an update — putting the bytes into the parent does not make them the
    /// ones the tab was opened with.
    let original: any ByteStorage
    /// The source's bytes as last taken out or put back.
    private var fingerprint: SHA256.Digest?
    /// The tab's content as last taken out or put back — what "has changes to
    /// put back" is measured against (§2.1).
    private var baseline: SHA256.Digest
    private var lastParentName: String
    /// The last verdicts, with the content generation each was reached at: a
    /// side is hashed again only after its bytes could have changed.
    private var checked: (generation: Int, state: State)?
    private var childChecked: (generation: Int, changed: Bool)?

    /// - Parameter content: the tab's bytes as it opens with them.
    init?(
        parent: PaneViewModel,
        source: Range<UInt64>,
        partName: String,
        layout: UEFIRootLayout,
        kind: Kind = .copy,
        rebuildTarget: UEFIRebuild.Target? = nil,
        content: [UInt8]
    ) {
        guard let document = parent.document else { return nil }
        self.parent = parent
        parentDocument = document
        sourceRange = source
        self.partName = partName
        self.layout = layout
        self.kind = kind
        self.rebuildTarget = rebuildTarget
        fingerprint = Self.digest(of: source, in: document)
        // Shares the array the tab's own storage was built from: nothing is
        // copied until one of them is written, and neither ever is.
        original = MemoryBackedStorage(bytes: content)
        baseline = SHA256.hash(data: content)
        lastParentName = parent.status.fileName
        checked = (parent.contentGeneration, fingerprint == nil ? .sourceChanged : .intact)
    }

    var state: State {
        guard let parent, let document = parent.document, document === parentDocument else {
            return .parentClosed
        }
        let generation = parent.contentGeneration
        if let checked, checked.generation == generation { return checked.state }
        let digest = Self.digest(of: sourceRange, in: document)
        let state: State = digest != nil && digest == fingerprint ? .intact : .sourceChanged
        checked = (generation, state)
        return state
    }

    /// The parent's name now — it follows a Save As — or the last name it had
    /// while it was still the parent.
    var parentName: String {
        if state != .parentClosed, let parent {
            lastParentName = parent.status.fileName
        }
        return lastParentName
    }

    /// What the header's link says under the pointer.
    var explanation: String {
        let from = "Opened from “\(partName)” in \(parentName)"
        switch state {
        case .intact: return from + ". Click to show it there."
        case .parentClosed: return from + ", which is no longer open."
        case .sourceChanged: return from + ", which has changed there since."
        }
    }

    /// Whether `child` — the tab this origin belongs to — holds anything the
    /// parent does not have back yet.
    func hasChanges(in child: PaneViewModel) -> Bool {
        guard let document = child.document else { return false }
        let generation = child.contentGeneration
        if let childChecked, childChecked.generation == generation { return childChecked.changed }
        let changed = (try? document.read(at: 0, length: Int(document.size)))
            .map { SHA256.hash(data: $0) != baseline } ?? true
        childChecked = (generation, changed)
        return changed
    }

    /// What Update in Parent would do with `child`'s bytes (§3, §4): through
    /// the rebuild planner when the part is a structure of the image, the same
    /// length back over the source otherwise, or a refusal that says why.
    func planUpdate(from child: PaneViewModel) -> Update {
        guard let parent, state != .parentClosed else {
            return .refused(
                title: "The parent is closed",
                message: "“\(parentName)” is no longer open, so there is nothing to put “\(partName)” back into."
            )
        }
        guard !parent.status.isReadOnly else {
            return .refused(
                title: "“\(parentName)” is read-only",
                message: "Its bytes cannot be changed, so “\(partName)” cannot be put back into it."
            )
        }
        guard let document = child.document,
              let bytes = try? document.read(at: 0, length: Int(document.size))
        else {
            return .refused(title: "The tab could not be read", message: "Nothing was changed in \(parentName).")
        }
        if let rebuildTarget {
            return .rebuild(target: rebuildTarget, bytes: bytes, confirm: state == .sourceChanged)
        }
        guard kind == .copy else {
            return .refused(
                title: "This cannot be put back",
                message: "These bytes were decompressed from “\(partName)” in \(parentName), "
                    + "and where they belong in it was not recorded when the tab was opened."
            )
        }
        guard UInt64(bytes.count) == UInt64(sourceRange.count) else {
            return .refused(
                title: "The length changed",
                message: "“\(partName)” is \(Self.hex(sourceRange.count)) bytes in \(parentName), "
                    + "and this tab is \(Self.hex(bytes.count)). A part goes back only at its own length: "
                    + "the bytes after it in the file are not this tab's to move."
            )
        }
        return .overwrite(offset: sourceRange.lowerBound, bytes: bytes, confirm: state == .sourceChanged)
    }

    /// The link's verdicts before an update, to put back if the write fails.
    struct Snapshot {
        fileprivate let fingerprint: SHA256.Digest?
        fileprivate let baseline: SHA256.Digest
        fileprivate let sourceRange: Range<UInt64>
    }

    /// Takes `tabBytes` as what the tab holds and `sourceBytes` at
    /// `sourceRange` as what the parent will — called just before the write, so
    /// the change notice it posts already finds the link intact and nothing
    /// left to put back. Hands back what to restore if the write fails.
    func adopt(tabBytes: [UInt8], sourceBytes: [UInt8], sourceRange newRange: Range<UInt64>) -> Snapshot {
        let snapshot = Snapshot(fingerprint: fingerprint, baseline: baseline, sourceRange: sourceRange)
        fingerprint = SHA256.hash(data: sourceBytes)
        baseline = SHA256.hash(data: tabBytes)
        sourceRange = newRange
        checked = nil
        childChecked = nil
        return snapshot
    }

    func restore(_ snapshot: Snapshot) {
        fingerprint = snapshot.fingerprint
        baseline = snapshot.baseline
        sourceRange = snapshot.sourceRange
        checked = nil
        childChecked = nil
    }

    private static func digest(of range: Range<UInt64>, in document: BinaryDocument) -> SHA256.Digest? {
        guard range.upperBound <= document.size,
              let bytes = try? document.read(at: range.lowerBound, length: Int(range.count))
        else { return nil }
        return SHA256.hash(data: bytes)
    }

    private static func hex<T: BinaryInteger>(_ value: T) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }
}
