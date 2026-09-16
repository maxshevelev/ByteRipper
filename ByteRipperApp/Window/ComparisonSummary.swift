import ByteRipperCore

/// What the panes' status bar says about an open comparison (§14.4): how much
/// of it differs, as a share of the comparison's extent.
///
/// A value, not a view: the interesting parts — the extent the share is taken
/// out of, and the rounding — are then assertable without a window.
///
/// The share is rounded UP to one decimal place, which is what keeps the
/// readout honest at both ends. A comparison that differs by a single byte in
/// 16 MB says so (0.1%) instead of rounding away to nothing, and one that does
/// not differ at all says nothing at all rather than 0.0%, which is what the
/// bar would read as "no comparison is running".
struct ComparisonSummary: Equatable {
    /// The extent the share is taken out of: the longer file's length, which is
    /// what the block index covers (§8.1) and what both panes scroll over (§9) —
    /// so "differing 25.0%" is a quarter of what the user can scroll, not a
    /// quarter of whichever pane they happen to be reading.
    let extent: UInt64
    /// The offsets whose bytes differ between the two files, an EOF-only tail
    /// included (§8.1).
    let differingBytes: UInt64

    /// Reads an index. One pass over its blocks, which are byte-exact even where
    /// a hunk would merge them (§10.3) — the share is per byte, like the
    /// highlighting, so the grouping distance never moves it.
    init(index: DiffBlockIndex) {
        extent = index.maxSize
        differingBytes = index.blocks.reduce(0) { total, block in
            block.kind == .different ? total + block.count : total
        }
    }

    /// The status bar's part. Empty when there is nothing to report — the two
    /// files do not differ (or there are no bytes to compare at all), and the
    /// bar says nothing rather than "differing 0.0%".
    var text: String {
        let tenths = Self.tenthsOfPercent(differingBytes, of: extent)
        guard tenths > 0 else { return "" }
        // The decimal is always there, even at a whole value: the readout is a
        // number the user reads while editing, and "differing 25%" growing a
        // decimal place on the next keystroke would make it jump.
        return "differing \(tenths / 10).\(tenths % 10)%"
    }

    /// The share in tenths of a percent, rounded up — the smallest number of
    /// tenths that covers `differing` out of `of`.
    ///
    /// Ceiling division of two exact integers, not `ceil` over a Double: a
    /// percentage that lands exactly on a tenth has to come out on that tenth,
    /// and a Double that arrives a hair above it (or a hair below a tie) would
    /// move it a tenth the wrong way. The multiplication goes through the
    /// full-width form so a difference in the petabytes cannot overflow it.
    private static func tenthsOfPercent(_ differing: UInt64, of extent: UInt64) -> UInt64 {
        guard differing > 0, extent > 0 else { return 0 }
        guard differing < extent else { return 1000 }  // every byte, and the EOF tail
        // `differing < extent` bounds the quotient below 1000, so it fits in a
        // single word and the division cannot trap.
        let (high, low) = differing.multipliedFullWidth(by: 1000)
        let (quotient, remainder) = extent.dividingFullWidth((high: high, low: low))
        return quotient + (remainder == 0 ? 0 : 1)
    }
}
