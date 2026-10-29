import Localization
import PartCodec
import UEFITool

extension UEFICodeOpening {
    /// The read-only codec the part is opened with.
    public var codec: ReadOnlyPartCodec {
        ReadOnlyPartCodec(bytes, title: L("This cannot be put back"),
                          reason: L("A code analysis is a snapshot; edit the dump and analyze the module again."))
    }
}

extension UEFICodeOpening.Failure {
    /// What the panel shows, in the app's language.
    public var message: String { text.text }
}
