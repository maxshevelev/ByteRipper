import ByteRipperCore
import Foundation
import Localization
import UEFIImage

/// A short statement an agent made about a place in a file
/// (`Design/AGENT_PLAN.md`, "Annotations"; issue #37): what the bytes are,
/// or what it found there.
///
/// It belongs to the file, not to a window: it is kept while the app runs,
/// whether the file is open or not, and drawn over the bytes — a dashed
/// outline, the note on hover — whenever the file is on screen, in a tab or
/// in a part that keeps the file's addresses. It goes when the agent or the
/// person removes it; one on a document that was never saved goes with that
/// document.
struct AgentAnnotation: Equatable {
    /// `a1`, `a2`… — one counter for the app.
    let id: String
    let file: File
    /// Half-open, in the file's addresses — or, on a pane, in the pane's. Nil
    /// for a place known only as a UEFI node of a file that was not open.
    let range: Range<UInt64>?
    /// The UEFI node the annotation is about, when it was given as one.
    let node: String?
    /// A few words: what the bytes are.
    let title: String
    /// A sentence or two: why they matter, or what was found.
    let note: String
    /// Where the bytes are read decoded: the place is in what a compressed
    /// section decompresses to, or in a LENV block with its XOR removed, and
    /// is shown there — in a fragment panel of those bytes — not in the file.
    var decoded: Decoded? = nil
    /// The annotations this one is about — a pointer and what it points at,
    /// a checksum and what it covers.
    let relatedTo: [String]
    /// What its place is called on screen: the node as UEFI Structure names
    /// it — given, or the deepest one holding the range — and that node's id
    /// in the file's tree, for the link that opens it. Nil where the file has
    /// no tree, or was not open to read one.
    var site: Site? = nil

    struct Site: Equatable {
        let label: String
        let node: String
    }

    /// A place in bytes that are not the file's own, as a fragment panel
    /// opens them.
    struct Decoded: Equatable {
        /// The node the panel is opened from, in the file's tree: the
        /// compressed section, or the LENV block.
        let holder: String
        /// What the panel is linked to in the file: the bytes it is decoded
        /// from.
        let source: Range<UInt64>
        /// The buffer the panel shows; nil for a LENV block, whose bytes are
        /// the block's own, decoded.
        let space: ByteSpace?
        /// Half-open, in the panel's own addresses.
        let range: Range<UInt64>
        /// The badges of the codecs the bytes came through, outermost first —
        /// `LZMA`, `XOR C0` — as the panel's header shows them.
        let codecs: [String]
    }

    /// The file an annotation belongs to.
    enum File: Equatable {
        /// A file on disk, found again by its identity when it is opened.
        case disk(URL, FileIdentity)
        /// A document with no file — a copy, a part of one — which the
        /// annotation lives and dies with.
        case document(WeakDocument)

        var url: URL? {
            if case .disk(let url, _) = self { return url }
            return nil
        }
    }

    /// The same annotation at another range: the place as a pane shows it.
    func at(_ range: Range<UInt64>?) -> AgentAnnotation {
        AgentAnnotation(id: id, file: file, range: range, node: node, title: title, note: note, decoded: decoded,
                        relatedTo: relatedTo, site: site)
    }

    /// Without the relations to the ones `gone` names.
    func dropping(_ gone: Set<String>) -> AgentAnnotation {
        AgentAnnotation(id: id, file: file, range: range, node: node, title: title, note: note, decoded: decoded,
                        relatedTo: relatedTo.filter { !gone.contains($0) }, site: site)
    }

    /// What the pointer resting on the bytes shows: the title, the note and
    /// the annotations this one is about, named by `titles` where it knows them.
    func tooltip(titles: [String: String]) -> String {
        [title, note, relations(titles: titles)].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// "Related Annotations: a1 FIT pointer, a3", or "" for one about no other
    /// — the one place a relation reads, in the Agent window and over the dump.
    func relations(titles: [String: String]) -> String {
        guard !relatedTo.isEmpty else { return "" }
        let named = relatedTo.map { id in titles[id].map { "\(id) \($0)" } ?? id }
        return String(format: L("Related Annotations: %1$@"), named.joined(separator: ", "))
    }
}

/// A document held without keeping it open: an annotation on an untitled
/// document must not outlive it, and must not keep it alive.
final class WeakDocument: Equatable {
    private(set) weak var document: BinaryDocument?
    private let identifier: ObjectIdentifier

    init(_ document: BinaryDocument) {
        self.document = document
        identifier = ObjectIdentifier(document)
    }

    static func == (lhs: WeakDocument, rhs: WeakDocument) -> Bool { lhs.identifier == rhs.identifier }

    func holds(_ document: BinaryDocument) -> Bool { self.document === document }
}
