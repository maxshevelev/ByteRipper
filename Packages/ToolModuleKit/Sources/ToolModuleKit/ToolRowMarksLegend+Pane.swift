import AppKit

extension ToolRowMarksLegend {
    /// Lays a list and its legend out in one pane of a split: the list from the
    /// top, the legend under it, both as wide as the pane.
    ///
    /// The pane is placed by `ALSplitView` from its own bounds, and those are
    /// nothing at all while the tool panel is still closed or opening from
    /// zero — so the pane spends its first layout passes 0 × 0. The legend has
    /// a size it cannot go under: its margins, a 19-point sample beside every
    /// line, the buttons in its header. Pinned to the pane's bottom and
    /// trailing edges as required, that is a pair of rules no zero-sized pane
    /// can meet, and AppKit breaks one of the legend's own constraints to
    /// recover — a console full of conflicts on every panel that opens.
    ///
    /// So the two edges the legend is pushed against give way — and below the
    /// priority its own content resists being squeezed at, not merely below
    /// required. An edge at 999 would still outrank a button's compression
    /// resistance (750), so a zero-wide pane would crush the header's "Legend"
    /// to one letter a line, and a wrapped title does not unwrap when the pane
    /// grows. At any size the pane can hold the legend the edges are met
    /// exactly and nothing changes; below it the legend keeps its own shape and
    /// runs past the pane instead of being squeezed to fit.
    public func install(below list: NSScrollView, in pane: NSView) {
        list.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(list)
        pane.addSubview(self)

        let bottom = bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        let trailing = trailingAnchor.constraint(equalTo: pane.trailingAnchor)
        for edge in [bottom, trailing] {
            edge.priority = .defaultHigh - 1
        }
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: pane.topAnchor),
            list.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            topAnchor.constraint(equalTo: list.bottomAnchor, constant: 4),
            leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            trailing,
            bottom
        ])
    }
}
