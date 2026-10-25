import Localization
import PartCodec

extension PartBadge {
    /// The badge a code screen wears: the panel is the code reader, not a
    /// part of the file that merely happens to be read-only. The codec's own
    /// `Read-only` badge is still what refuses Update in Parent; this one says
    /// what the reader is looking at.
    static var code: PartBadge {
        PartBadge(
            L("Code"),
            explanation: L("This panel reads the module's stored code analysis. Its bytes are a read-only snapshot."),
            symbolName: "ellipsis.curlybraces")
    }
}
