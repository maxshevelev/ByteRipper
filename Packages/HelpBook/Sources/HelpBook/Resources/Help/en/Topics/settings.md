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
- **Editing** — the confirmations raised before edits that change the length of the file ([[topic:editing|Editing Bytes]]). They are enabled by default, and this is the same setting as the "do not ask again" box in the dialogs themselves.
- **Text Decoding** — the encoding the text column decodes with.
- **Search Patterns** — the named search patterns, and the folder through which the library can be synchronised between installations ([[topic:search|Finding Bytes and Text]]).
- **File Types** — which extensions open in ByteRipper from the Finder. `.rom` and `.dump` belong to the program; `.bin` and the others are offered here because the system already holds a handler for them.
- **Agent** — whether agents may connect to ByteRipper, and the text a client program is set up with ([[topic:agent|Working with an Agent]]).
- **Language** — whether the program follows the language of the Mac or uses a chosen one. The help book changes language immediately; menus and windows change after a restart. Firmware terms remain in English in every language, those being the names datasheets and tools give them.

Settings apply to the program rather than to a window: a font size chosen here applies to every open dump.
