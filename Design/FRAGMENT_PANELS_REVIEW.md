# Fragment panels — code review

Review of the commit series that added opening dump fragments in separate
panels, `a4b8050` ("Settle where a part opens: a panel over its parent, not a
tab") through `bdfe776` ("Switch between panels without the flight"). Full app
diff (~6 700 lines) plus the package diff (~670 lines); every candidate finding
was checked against the source before it was kept.

Four confirmed bugs, all in the new fragment-panel feature. Two independent
review passes each surfaced three; they disagreed on one, and the union of the
two was re-verified by hand. What follows is that verified union, most severe
first.

## 1. A drop on a fragment's tool panel replaces the tab's file — HIGH

`ByteRipperApp/Window/DocumentSurface.swift:165`

`wireToolPanel`'s `onDropFiles` resolves its target with
`host.paneIndex(of: self.tools.boundPane)`, and the public `paneIndex(of:)`
(`MainViewController.swift:560`) is `pane === windowModel.pane2 ? 1 : 0`. A
fragment pane is neither `pane1` nor `pane2`, so it always answers **0**, and
the drop then calls `openFiles(into: 0, urls:)`, which opens into
`windowModel.pane1`.

Scenario: open a UEFI image, open a node as a panel, activate a tool on the
panel (Tools ▸ …, which binds to the pinned fragment pane), then drop another
file on the panel's tool panel. The drop zone says "Replace Current File," but
the tab's pane‑0 file is what gets replaced (after the dirty‑confirm), while the
fragment's file is untouched.

The sibling callbacks in the same wiring are guarded against exactly this —
`onSelectPane` (line 176) and `paneDropTitle` (line 179) check
`pinnedPane == nil` — `onDropFiles` is the one that is not.

## 2. A search in a fragment never re‑marks the fragment's own minimap — MEDIUM

`ByteRipperApp/Window/MainViewController.swift:5930`

`searchAppearanceChanged()` only touches the tab's surface:
`surface.minimapPanelVisible`, `surface.minimapView.invalidateCells()`,
`surface.minimap.scheduleMatchSync()`. But a fragment pane's `onMatchesChanged`
(wired in `wireFragmentPaneView`, `MainViewController.swift:182`) routes to this
same method. Every other fragment‑pane callback correctly targets the fragment's
own `surface.minimap` — `onEdit` calls `surface.minimap.repaint(after:mapIndex:)`,
`onFullInvalidation` calls `surface.minimap.refreshMaps()` — the match overlay is
the one that doesn't.

Scenario: show the minimap, open a fragment panel, search inside it. The
fragment's minimap syncs once when shown, but each subsequent search or ‹ › step
only refreshes the tab's minimap, so the fragment's match marks stay stale or
empty.

Note: the comment at the top of `wireFragmentPaneView` ("What is deliberately
**not** here is the minimap's … that is the next piece of work, not an
omission") is stale — every surface now has a minimap of its own, and the
edit / full‑invalidation feeds already target the fragment's. Only the search
feed was left on the tab's.

## 3. The origin link in a nested panel is a silent no‑op — MEDIUM‑LOW

`ByteRipperApp/Window/MainViewController.swift:2281`

`revealOrigin` finds the parent's window through `controller(holding:)`
(~line 2296), which only matches `windowModel.pane1 === pane || pane2 === pane`.
A fragment pane is neither, so a fragment whose parent is itself a fragment is
never found and the function returns early.

Scenario: open a UEFI image, open a volume as a panel, then open a file inside
that volume (a nested panel whose `origin.parent` is the volume fragment —
reachable because `PaneToolHost.openPart` passes the bound fragment pane as
`from:`). The link in the inner panel is drawn active (the parent fragment is
open, not `.parentClosed`), but tapping it neither expands the parent nor
selects the source range. The same gap means "Update in Parent" from a nested
panel raises the parent panel but never selects the range that just landed.

## 4. Updating a folded panel leaves an unrelated panel covering the landing — MEDIUM

`ByteRipperApp/Window/MainViewController.swift:263`

`revealUpdateDestination(from:to:)` brings the destination to the front with two
branches: if the parent is itself a fragment panel, expand it; otherwise, if the
panel being updated is the one that is up, collapse it. There is no branch for
the case where *a different* panel is up.

Scenario: panel B is expanded, panel A is folded into its pill with edits. Close
A through its pill ✕ → the changes question → "Update in Parent." The bytes go
back into the tab's pane. In `revealUpdateDestination`: `parentPanel` is nil
(the parent is a tab pane) and `fragments.expanded == A` is false (B is up), so
neither branch fires. B stays expanded, covering the tab pane the bytes landed
in. `revealOrigin` then selects the range there, but it is behind B — the reader
never sees the change arrive. The function's own contract ("what they went into
comes to the front") is the thing that is broken.

## Checked and cleared (not bugs)

- `AppDelegate.applicationShouldTerminate` / `windowShouldClose` /
  `confirmClose` — the `inThisCall` + `reply(toApplicationShouldTerminate:)`
  deferred pattern is correct for both the synchronous and the sheet‑based
  answer; an abandoned Save As correctly leaves the window open.
- `PanelLanding.transform` / `landed` — the anchor‑point (0,0) scale‑about‑anchor
  plus translate math is algebraically consistent and lands exactly on the
  target; `fly` passes `layer.anchorPoint`, matching Core Animation.
- `PullDown.outcome` / `position`, and the `PaneHeaderView.mouseDragged` branch
  (`dy < 0 && -dy > abs(dx)`) — no inverted conditions.
- `OverviewBinning.start(ofRow:)` (returns `extent` at `row == rowCount`),
  `stretchedColumns`, `cells(of:)` — no off‑by‑one.
- `OverviewProgressSink` — NSLock‑guarded, hops to the main actor for the
  callback; no data race.
- `closeFragment` / `performUpdateInParent` / `closeFragmentIfPutBack` — the
  refused / overwritten / rebuild paths all re‑check `origin.hasChanges` and
  report correctly; a refused update keeps the panel open.
- `UEFIPresenter.nodeOpen` / `fileSource` / `nodeOpenTitle` — source range and
  rebuild‑target selection are correct for file vs. buffer spaces.
- `tearOffFragmentToNewTab` returning `true` when `makeSiblingTab` is nil — only
  reachable in test controllers (AppDelegate always sets it), so no real‑app
  misbehavior.
- `SurfaceMinimapController.updateLayout`'s `surface === self.surface` guard is
  dead (a self‑comparison, always true), but the following
  `panes().count > 1` guard produces the same result, so there is no behavioral
  impact.
