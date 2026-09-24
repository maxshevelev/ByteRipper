import Foundation

/// A pane's view of a bookmark list: the list itself, and where the pane's
/// byte 0 sits in it (§20.7).
///
/// One list serves a window — its panes *and* every fragment panel opened out
/// of them — because a bookmark is an offset in the file, not in whatever
/// happens to be showing it. A panel shows a part of that file starting at
/// `origin`, so one mark is one byte at two addresses: `0x1F400` in the dump,
/// `0x400` in the part taken out at `0x1F000`. Marking a row in either place
/// marks it in the other.
///
/// Every verb here takes and returns the **pane's** offsets, and the
/// translation lives in this one type: nothing outside it has to remember which
/// of the two spaces the number in its hand belongs to.
///
/// A part whose bytes are not the file's bytes — a decompressed body — has no
/// space at all. Its pane is given none, and with none there is nothing to draw
/// and nothing to add: the file's offsets do not reach those bytes, so a mark
/// in one would mean nothing in the other.
///
/// A value, not an object: the list is the shared thing, and where a pane sits
/// in it is a fact about the pane that never changes while it is there.
@MainActor
struct BookmarkSpace {
    /// The list the marks live in — the window's.
    let store: BookmarkStore
    /// The pane's byte 0 in `store`'s address space. Zero for a pane showing a
    /// file whole, the part's offset in its file for a fragment panel.
    let origin: UInt64

    init(store: BookmarkStore, origin: UInt64 = 0) {
        self.store = store
        self.origin = origin
    }

    /// Whether the pane's offsets are not the list's — true exactly for a panel
    /// showing a part taken out past the start of its file. What decides
    /// whether a mark has an address elsewhere worth saying (§20.7).
    var isShifted: Bool { origin != 0 }

    // MARK: - The two spaces

    /// The list's row a mark made on this pane's row containing `local` belongs
    /// on.
    ///
    /// Rounded **up** to the list's grid, and that is not an arbitrary half of
    /// a coin toss: a part need not begin on a row boundary, and of the sixteen
    /// byte offsets the pane's row covers in the list exactly one is a row of
    /// the list — the first at or after `local + origin`. Rounding down would
    /// pick the row *before* the pane's, and the mark would read back one row
    /// higher than it was made. Rounding up makes `localRow(forStoreRow:)` this
    /// function's inverse, which is what stops a mark drifting every time it is
    /// looked at.
    func storeRow(forRowContaining local: UInt64) -> UInt64 {
        let step = UInt64(HexLayout.bytesPerRow)
        let absolute = BookmarkStore.row(containing: local) + origin
        let remainder = absolute % step
        return remainder == 0 ? absolute : absolute + (step - remainder)
    }

    /// Where the list's row `row` shows in this pane, or nil when it falls
    /// before the part's first byte — a mark on the file's rows above the part
    /// is not in the part.
    ///
    /// Past the part's last byte needs no answer here: the dump draws no rows
    /// it has no bytes for, so a mark beyond the end is simply never asked
    /// about (§9), and the window's list keeps it either way.
    func localRow(forStoreRow row: UInt64) -> UInt64? {
        guard row >= origin else { return nil }
        return BookmarkStore.row(containing: row - origin)
    }

    // MARK: - Reading

    /// The marks as this pane has them: the list's, at this pane's offsets,
    /// without the ones that fall before its first byte. Sorted, because the
    /// list is and the translation is monotonic.
    var bookmarks: [Bookmark] {
        store.bookmarks.compactMap { mark in
            localRow(forStoreRow: mark.row).map { Bookmark(row: $0, name: mark.name) }
        }
    }

    /// The mark on the pane's row containing `local`, at that row.
    func bookmark(atRowContaining local: UInt64) -> Bookmark? {
        guard let mark = store.bookmark(atRowContaining: storeRow(forRowContaining: local)) else {
            return nil
        }
        return Bookmark(row: BookmarkStore.row(containing: local), name: mark.name)
    }

    /// The pane's marked rows in `range`, a range of the pane's own offsets.
    func rows(in range: Range<UInt64>) -> Set<UInt64> {
        guard !range.isEmpty else { return [] }
        // Asked in the list's space and answered in the pane's. Both ends are
        // taken to the list's row their own row maps to, so a drawn row whose
        // last bytes fall past the range — the file's final, part-full row —
        // still brings its mark with it.
        let lower = storeRow(forRowContaining: range.lowerBound)
        let upper = storeRow(forRowContaining: range.upperBound - 1)
        return Set(store.rows(in: lower..<(upper + 1)).compactMap(localRow(forStoreRow:)))
    }

    // MARK: - Writing

    @discardableResult
    func toggle(rowContaining local: UInt64) -> Bookmark? {
        store.toggle(rowContaining: storeRow(forRowContaining: local))
            .map { Bookmark(row: BookmarkStore.row(containing: local), name: $0.name) }
    }

    @discardableResult
    func add(rowContaining local: UInt64, name: String = "") -> Bookmark {
        let mark = store.add(rowContaining: storeRow(forRowContaining: local), name: name)
        return Bookmark(row: BookmarkStore.row(containing: local), name: mark.name)
    }

    @discardableResult
    func rename(rowContaining local: UInt64, to name: String) -> Bookmark? {
        store.rename(rowContaining: storeRow(forRowContaining: local), to: name)
            .map { Bookmark(row: BookmarkStore.row(containing: local), name: $0.name) }
    }

    @discardableResult
    func remove(rowContaining local: UInt64) -> Bool {
        store.remove(rowContaining: storeRow(forRowContaining: local))
    }

    @discardableResult
    func edit(rowContaining from: UInt64, to target: UInt64, name: String) -> Bookmark? {
        store.edit(rowContaining: storeRow(forRowContaining: from),
                   to: storeRow(forRowContaining: target),
                   name: name)
            .map { Bookmark(row: BookmarkStore.row(containing: target), name: $0.name) }
    }

    /// Drags the mark on the pane's row containing `from` to the row containing
    /// `to`, with `lastRow` the last row the pane draws (§20.6).
    ///
    /// The store decides where it lands — rows another mark holds are jumped
    /// over — and the answer comes back in the pane's offsets. Nil also when
    /// the landing row is outside the part: the mark is still in the window's
    /// list, at a row this panel does not reach.
    @discardableResult
    func move(rowContaining from: UInt64, to: UInt64, lastRow: UInt64) -> UInt64? {
        store.move(rowContaining: storeRow(forRowContaining: from),
                   to: storeRow(forRowContaining: to),
                   lastRow: storeRow(forRowContaining: lastRow))
            .flatMap(localRow(forStoreRow:))
    }
}
