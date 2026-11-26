import AppKit
import Localization

/// A navigator tab for one kind of record a review keeps — an EC image's
/// interrupts, host commands, EC RAM and so on, as the module's analysis
/// profile declares them.
///
/// The records are not in the review document yet, so for now the section
/// says honestly that it has none. It is a view of its own so that, once the
/// review carries the records, it can be given rows without the pane around
/// it changing.
final class CodeRecordSectionView: NSView {
    /// The record id the section shows, nil before the first `show`.
    private(set) var recordID: String?
    private let titleLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        // The same quiet, centred words as the navigator's empty lists.
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isSelectable = false
        for label in [titleLabel, emptyLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            emptyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
    }

    /// As the Interfaces and Search tabs: the window's fill, so the list the
    /// section stands over does not show through.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the section of record `id`, `fallbackTitle` being the profile's
    /// English title for an id the app has no words for.
    func show(id: String, fallbackTitle: String, font: NSFont) {
        recordID = id
        titleLabel.stringValue = Self.title(of: id, fallback: fallbackTitle)
        emptyLabel.font = font
        emptyLabel.stringValue = Self.emptyText
    }

    /// The words of the section, for tests.
    var shownTitle: String { titleLabel.stringValue }
    var shownEmptyText: String { emptyLabel.stringValue }

    /// What a section with no records says.
    static var emptyText: String {
        L("The review has recorded none yet. They appear here when the review is published.")
    }

    /// The section's title in the reader's language: the profiles carry
    /// English, and an id not listed here keeps the profile's word.
    static func title(of id: String, fallback: String) -> String {
        switch id {
        case "irq_map": L("Interrupts")
        case "host_commands": L("Host commands")
        case "ec_ram": L("EC RAM")
        case "smbus_peers": L("SMBus and I2C")
        case "gpio": L("GPIO")
        case "eflash_area": L("Flash data area")
        default: fallback
        }
    }
}
