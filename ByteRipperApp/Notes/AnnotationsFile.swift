import ByteRipperCore
import Foundation
import Localization
import UEFIImage

/// Where the annotations are kept between launches, and in what shape.
///
/// `~/Library/Application Support/ByteRipper/Annotations.json`, beside the
/// favourites (`FavoritesFile`), on this Mac only: nothing carries them to
/// another. Everything an annotation holds is kept — the file it is on, by
/// path and by identity, so a file renamed since is still found; the place,
/// the node, the decoded bytes and their codecs; the title and the note; the
/// relations, the author — and with them the order of the cards in the
/// Annotations window and which ones are still new. An annotation on a
/// document never saved is not kept: it goes with the document.
///
/// A test host never defaults to the file — its Application Support is the
/// user's own — so a test that wants one gives it (`url`).
enum AnnotationsFile {
    /// The file the app reads at launch and writes after every change; nil —
    /// under test — keeps the annotations for the run alone.
    static var url: URL? = defaultURL()

    static func defaultURL() -> URL? {
        guard !AppDefaults.isUnderTest else { return nil }
        return FavoritesFile.directory(in: FavoritesFile.applicationSupport)
            .appendingPathComponent("Annotations.json")
    }

    /// What the file holds.
    struct Contents: Codable, Equatable {
        /// The annotations in the order they were made, oldest first — the
        /// order an agent lists them in.
        var annotations: [Stored]
        /// The cards' order in the window, first card first.
        var order: [String]
        /// Not yet marked new in the window: marked the next time it is in
        /// view.
        var fresh: [String]
        /// The agent's among them, counted on the toolbar's button.
        var unseen: [String]
        /// The number the next annotation's id is made with.
        var nextID: Int
    }

    /// One annotation as it is written: `AgentAnnotation` with its file as a
    /// path and an identity.
    struct Stored: Codable, Equatable {
        var id: String
        var path: String
        var identity: FileIdentity
        var range: Range<UInt64>?
        var node: String?
        var title: String
        var note: String
        var decoded: AgentAnnotation.Decoded?
        var relatedTo: [String]
        var site: AgentAnnotation.Site?
        var author: AgentAnnotation.Author

        /// Nil for one on a document never saved, which is not kept.
        init?(_ annotation: AgentAnnotation) {
            guard case .disk(let url, let identity) = annotation.file else { return nil }
            id = annotation.id
            path = url.path
            self.identity = identity
            range = annotation.range
            node = annotation.node
            title = annotation.title
            note = annotation.note
            decoded = annotation.decoded
            relatedTo = annotation.relatedTo
            site = annotation.site
            author = annotation.author
        }

        var annotation: AgentAnnotation {
            AgentAnnotation(id: id, file: .disk(URL(fileURLWithPath: path), identity), range: range, node: node,
                            title: title, note: note, decoded: decoded, relatedTo: relatedTo, site: site,
                            author: author)
        }
    }

    /// What `url` holds; nil where there is no file, or one that cannot be
    /// read — the app then starts with no annotations rather than not at all.
    static func read(_ url: URL) -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: data)
    }

    /// Writes `contents` to `url` whole, in one step: a launch never finds
    /// half of a file.
    static func write(_ contents: Contents, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(contents).write(to: url, options: .atomic)
    }
}
