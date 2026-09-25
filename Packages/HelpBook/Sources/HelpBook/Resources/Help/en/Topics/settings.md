# Settings

> ⌘, — the app-wide preferences.

@covers settings.layout
@covers settings.file-types
@covers settings.language
@covers menu.view.pane-layout
@covers menu.view.swap-panes

- **Appearance** — the monospaced font, its size and the row height for the hex view, and whether the app follows the system theme or is forced light or dark. The font size is also **⌘=** / **⌘−** from the View menu.
- **Layout** — how panes are arranged and what the window remembers.
- **Comparison** — how differences are shown and counted.
- **Editing** — the confirmations before length-changing edits ([[topic:editing|Editing]]). They are on by default; switching them off here is the same switch as the "do not ask again" box on the dialogs.
- **Text Decoding** — the encoding the text column decodes with.
- **Search Patterns** — the named search patterns, and the folder they can be synced from so a shop shares one pattern library ([[topic:search|Finding bytes]]).
- **File Types** — which extensions open in ByteRipper from Finder. `.rom` and `.dump` are the app's own; `.bin` and anything else are offered here because the system already has a handler for them.

Settings are app-wide, not per window: the font size you pick applies to every open dump, which is deliberate — a dump zoomed in one window and not in another would be an invisible second preference.
