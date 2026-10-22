# Kept-format fixtures

What a workspace keeps in `Kept/`, as the build of each workspace version
wrote it: `v<N>/history.log` (a `HistoryLog`, pinned at the length and hash
`KeptFormatVersionTests` names) and `v<N>/file.edits` (an `OverlayEdits`, as
`ContentKeeper` encodes it). Never rewritten: a later build must read them as
they are.
