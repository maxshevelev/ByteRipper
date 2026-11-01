import AppKit

/// The band between the list's switch and the rows: one narrow strip whose
/// colours are the review's groups, each as wide as its share of the module's
/// functions. The module's readiness at a glance, in the colours the group
/// headings wear — a module nobody has touched is a red strip with a sliver
/// of teal, one that is done is the other way round.
///
/// The strip is 4 points tall with a small margin above and below, and the
/// view says in words what its colours are to a reader who cannot see them.
// help: panel.code.readiness
final class CodeReviewReadinessBar: NSView {
    /// The strip's height.
    static let stripHeight: CGFloat = 4
    /// The room above and below it.
    static let padding: CGFloat = 3
    /// What the view takes, and what it takes with no strip to draw.
    static var height: CGFloat { stripHeight + 2 * padding }

    /// The groups in the strip, in the order they are drawn, and how many
    /// functions each holds — nothing for a group with none.
    private(set) var segments: [(group: CodeReaderState.FunctionGroup, count: Int)] = []

    /// What a segment is as wide as, for a test.
    private(set) var segmentWidths: [CGFloat] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Paints the counts: a group with no functions takes no room.
    func show(_ counts: [CodeReaderState.FunctionGroup: Int]) {
        segments = CodeReaderState.FunctionGroup.allCases.compactMap { group in
            let count = counts[group] ?? 0
            return count > 0 ? (group, count) : nil
        }
        segmentWidths = Self.widths(segments.map(\.count), in: bounds.width)
        setAccessibilityLabel(Self.words(segments))
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // The widths follow the width the band has.
        segmentWidths = Self.widths(segments.map(\.count), in: bounds.width)
        needsDisplay = true
    }

    /// How wide each segment of `counts` is in `width`: proportional, and no
    /// group so small that its colour cannot be seen — a one-function group
    /// keeps a point, taken from the widest.
    static func widths(_ counts: [Int], in width: CGFloat) -> [CGFloat] {
        let total = counts.reduce(0, +)
        guard total > 0, width > 0 else { return counts.map { _ in 0 } }
        var widths = counts.map { CGFloat($0) / CGFloat(total) * width }
        let minimum: CGFloat = min(1, width / CGFloat(counts.count))
        // The smallest first, so a point taken from a wide neighbour never
        // makes that neighbour too small in turn.
        for _ in 0..<counts.count where widths.contains(where: { $0 < minimum }) {
            guard let smallest = widths.indices
                .filter({ widths[$0] < minimum })
                .min(by: { widths[$0] < widths[$1] }) else { break }
            let needed = minimum - widths[smallest]
            guard let widest = widths.indices
                .filter({ $0 != smallest && widths[$0] > minimum })
                .max(by: { widths[$0] < widths[$1] }) else { break }
            widths[widest] -= needed
            widths[smallest] = minimum
        }
        return widths
    }

    /// The colours in words, for the reader who cannot see the strip.
    static func words(_ segments: [(group: CodeReaderState.FunctionGroup, count: Int)]) -> String {
        segments.map { segment in
            CodePaneView.title(of: segment.group) + " " + String(segment.count)
        }.joined(separator: ", ")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !segments.isEmpty, bounds.width > 0 else { return }
        let strip = NSRect(x: 0, y: Self.padding,
                           width: bounds.width, height: Self.stripHeight)
        // The strip's own rounded ends; the segments inside it are square.
        let shape = NSBezierPath(roundedRect: strip,
                                 xRadius: Self.stripHeight / 2, yRadius: Self.stripHeight / 2)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        var x = strip.minX
        for (index, segment) in segments.enumerated() {
            let width = index < segmentWidths.count ? segmentWidths[index] : 0
            guard width > 0 else { continue }
            CodeNavigatorIcon.group(segment.group).color
                .setFill()
            NSRect(x: x, y: strip.minY, width: width, height: strip.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
