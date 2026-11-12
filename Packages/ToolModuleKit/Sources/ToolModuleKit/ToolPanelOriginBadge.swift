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
public final class ToolPanelOriginBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private let frameLayer = CAShapeLayer()
    private var hue: NSColor = .secondaryLabelColor
    private var inferred = false

    /// The word's size: three quarters of the panel's text by default; a
    /// header that names the module in its title font passes its own.
    public var pointSize: CGFloat = ToolPanelOriginBadge.pointSize {
        didSet { label.font = .systemFont(ofSize: pointSize, weight: .semibold) }
    }

    public convenience init() { self.init(frame: .zero) }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(frameLayer)
        frameLayer.fillColor = nil
        frameLayer.lineWidth = 1
        label.font = .systemFont(ofSize: pointSize, weight: .semibold)
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

    override public var tag: Int { ToolPanelTable.codeOriginTag }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Three quarters of the panel's text: a tag, not a second name.
    public static var pointSize: CGFloat { (ToolPanelFont.size * 0.75).rounded() }

    /// The row's selection, as the cell is told it: on a selected row the
    /// badge is drawn in the selection's text colour, as the glyphs beside it
    /// are, since the category's colour does not read on the accent.
    public var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }
    public var isEmphasized: Bool { backgroundStyle == .emphasized }

    /// The word on the badge, for the tests.
    public var word: String { label.stringValue }
    public var isDashed: Bool { inferred }

    /// Shows `origin`, or hides the badge for nil and `unknown`.
    public func show(_ origin: ModuleOrigin?) {
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

    override public var wantsUpdateLayer: Bool { true }

    /// The colours are read again on each change of theme.
    override public func updateLayer() {
        let ink = isEmphasized ? NSColor.alternateSelectedControlTextColor : hue
        effectiveAppearance.performAsCurrentDrawingAppearance {
            frameLayer.strokeColor = ink.cgColor
            layer?.backgroundColor = inferred ? nil : ink.withAlphaComponent(isEmphasized ? 0.2 : 0.12).cgColor
            label.textColor = inferred ? ink.withAlphaComponent(0.75) : ink
        }
    }

    override public func layout() {
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

public extension ToolPanelOriginBadge {
    /// The badge as a picture, for a place a view cannot stand — inside a
    /// line of text, as the code panel's Search tab puts it before a module's
    /// name. Drawn when it is shown, so the colours follow the theme. Nil for
    /// no origin and `unknown`, which draw nothing.
    static func image(for origin: ModuleOrigin?, pointSize: CGFloat) -> NSImage? {
        guard let origin, let word = origin.badgeWord else { return nil }
        let inferred = origin.confidence == .inferred
        let hue = origin.category.badgeColor
        let font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        let text = NSAttributedString(string: word, attributes: [.font: font])
        let size = NSSize(width: ceil(text.size().width) + 8, height: ceil(font.ascender - font.descender) + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if !inferred {
                hue.withAlphaComponent(0.12).setFill()
                path.fill()
            } else {
                path.setLineDash([2, 2], count: 2, phase: 0)
            }
            hue.setStroke()
            path.lineWidth = 1
            path.stroke()
            let ink = inferred ? hue.withAlphaComponent(0.75) : hue
            NSAttributedString(string: word, attributes: [.font: font, .foregroundColor: ink])
                .draw(at: NSPoint(x: 4, y: (rect.height - (font.ascender - font.descender)) / 2 - font.descender))
            return true
        }
        image.accessibilityDescription = origin.badgeToolTip
        return image
    }
}
