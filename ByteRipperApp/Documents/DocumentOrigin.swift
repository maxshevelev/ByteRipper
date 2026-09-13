import CryptoKit
import Foundation
import ByteRipperCore
import UEFIImage

/// Where an untitled tab's bytes came from: a part of another open document — a
/// zone, or what a compressed section decompressed to
/// (`Design/UEFI/UPDATE_IN_PARENT.md` §2).
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

    private(set) weak var parent: PaneViewModel?
    private weak var parentDocument: BinaryDocument?
    /// The source's bytes in the parent's file: the zone, or the outermost
    /// compressed section a decompressed body came out of.
    let sourceRange: Range<UInt64>
    /// What the part is called there — the zone's or the section's name.
    let partName: String
    /// What the bytes are, for a tool-module opened on the tab (§2.1): a
    /// decompressed body is a run of sections, not an image to scan.
    let layout: UEFIRootLayout

    private let fingerprint: SHA256.Digest?
    private var lastParentName: String
    /// The last verdict, and the parent's content generation it was reached
    /// at: the source is hashed again only after the parent's bytes changed.
    private var checked: (generation: Int, state: State)?

    init?(parent: PaneViewModel, source: Range<UInt64>, partName: String, layout: UEFIRootLayout) {
        guard let document = parent.document else { return nil }
        self.parent = parent
        parentDocument = document
        sourceRange = source
        self.partName = partName
        self.layout = layout
        fingerprint = Self.digest(of: source, in: document)
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

    private static func digest(of range: Range<UInt64>, in document: BinaryDocument) -> SHA256.Digest? {
        guard range.upperBound <= document.size,
              let bytes = try? document.read(at: range.lowerBound, length: Int(range.count))
        else { return nil }
        return SHA256.hash(data: bytes)
    }
}
