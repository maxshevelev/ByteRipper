import AppKit
import AppPalette
import CodeAnalysis
import HelpUI
import Localization

// help: panel.uefi.module-origin
/// A module's origin beside its name: a short word in a frame of the
/// category's colour — `EDK2`, `EDK2*`, `AMD`, `Intel`, the vendor's name.
/// A solid frame on a light wash is an origin the review established; a
/// dashed one, with fainter text, an origin it inferred. `unknown` draws
/// nothing: a word saying "unknown" beside every module nobody placed would
/// say nothing the absence does not.
final class ToolPanelOriginBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private let frameLayer = CAShapeLayer()
    private var hue: NSColor = .secondaryLabelColor
    private var inferred = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(frameLayer)
        frameLayer.fillColor = nil
        frameLayer.lineWidth = 1
        label.font = .systemFont(ofSize: Self.pointSize, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalTo: label.heightAnchor, constant: 1),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    override var tag: Int { ToolPanelTable.codeOriginTag }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Three quarters of the panel's text: a tag, not a second name.
    static var pointSize: CGFloat { (ToolPanelFont.size * 0.75).rounded() }

    /// The word on the badge, for the tests.
    var word: String { label.stringValue }
    var isDashed: Bool { inferred }

    /// Shows `origin`, or hides the badge for nil and `unknown`.
    func show(_ origin: ModuleOrigin?) {
        guard let origin, let word = origin.badgeWord else {
            isHidden = true
            label.stringValue = ""
            ControlHelp.describe(self, nil)
            return
        }
        label.stringValue = word
        hue = origin.category.badgeColor
        inferred = origin.confidence == .inferred
        frameLayer.lineDashPattern = inferred ? [2, 2] : nil
        ControlHelp.describe(self, origin.badgeToolTip)
        isHidden = false
        needsDisplay = true
        needsLayout = true
    }

    override var wantsUpdateLayer: Bool { true }

    /// The colours are read again on each change of theme.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            frameLayer.strokeColor = hue.cgColor
            layer?.backgroundColor = inferred ? nil : hue.withAlphaComponent(0.12).cgColor
            label.textColor = inferred ? hue.withAlphaComponent(0.75) : hue
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 3
        frameLayer.frame = bounds
        frameLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3,
                                 transform: nil)
    }
}

extension ModuleOrigin.Category {
    var badgeColor: NSColor {
        switch self {
        case .edk2: return RowMarks.originEDK2
        case .edk2Modified: return RowMarks.originEDK2Modified
        case .amd: return RowMarks.originAMD
        case .intel: return RowMarks.originIntel
        case .vendor: return RowMarks.originVendor
        case .unknown: return .secondaryLabelColor
        }
    }
}

public extension ModuleOrigin {
    /// The word on the badge; nil for `unknown`, which draws none. Names of
    /// code bases are the same in every language; only "Vendor", for a vendor
    /// the review did not name, is translated.
    var badgeWord: String? {
        switch category {
        case .edk2: return "EDK2"
        case .edk2Modified: return "EDK2*"
        case .amd: return "AMD"
        case .intel: return "Intel"
        case .vendor: return vendor ?? L("Vendor")
        case .unknown: return nil
        }
    }

    /// What the pointer reads: whose code, and how sure.
    var badgeToolTip: String {
        let whose: String
        switch category {
        case .edk2: whose = L("EDK2: the code matches EDK2")
        case .edk2Modified:
            whose = vendor.map { L("EDK2 with changes: an EDK2 module changed by %1$@", $0) }
                ?? L("EDK2 with changes: an EDK2 module changed by the firmware vendor")
        case .amd: whose = L("AMD: AGESA code")
        case .intel: whose = L("Intel: FSP or reference code")
        case .vendor:
            whose = vendor.map { L("%1$@: the firmware vendor's own code", $0) }
                ?? L("The firmware vendor's own code")
        case .unknown: whose = L("Origin unknown")
        }
        switch confidence {
        case .established:
            return whose + "\n" + L("Established: compared with the source, or named in the module's own bytes")
        case .inferred:
            return whose + "\n" + L("Inferred: concluded from strings, interfaces or linked libraries")
        case nil:
            return whose
        }
    }
}
