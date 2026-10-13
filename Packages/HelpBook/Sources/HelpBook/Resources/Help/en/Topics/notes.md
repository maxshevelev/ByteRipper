# Annotations

> Short notes on places in a file — made by the person at the bench or by a connected agent — drawn over the bytes and listed in a window of their own.

@covers window.notes
@covers menu.offset.note
@covers window.notes.edit
@covers panel.uefi.annotate-node
@covers menu.window.notes
@covers toolbar.notes

An annotation is a title and a note about a place in a file: what the bytes are, or what was found there. It is drawn over the bytes whenever its file is on screen — in a tab, or in a part that keeps the file's addresses — as a dashed outline with a light wash; when the pointer rests on the bytes, the title and the note are shown. Annotations made by hand are drawn in green, those made by an agent ([[topic:agent|Working with an Agent]]) in violet.

An annotation belongs to the file, not to the window. It is kept when the file closes and drawn again when the file is opened. An annotation on a document that was never saved goes with that document. Every other annotation is kept until it is removed, from one launch of ByteRipper to the next; annotations are stored on this Mac only.

## Making an annotation

Select the bytes, right-click inside the selection and choose **Add Annotation…**. Enter a title — a few words saying what the bytes are — and, if needed, a note under it, then click **Add**. In a fragment panel the annotation goes to the file the part came out of: at the same bytes where the part keeps the file's addresses, otherwise in the part's own bytes, where it is shown when that part is opened again.

A node of **UEFI Structure** is annotated the same way: right-click its row and choose **Add Annotation…**; the title starts as the node's name. The annotation is about the node, not only about its bytes: a node inside a compressed section, or an entry of a Lenovo LENV block stored encoded, is kept in the bytes it decompresses or decodes to, and its card shows the codecs as badges.

## The Annotations window

The annotations belong to ByteRipper, not to a window, so they are listed in one place: the **Annotations** window. **Window ▸ Annotations**, or the **Annotations** button in the toolbar after **Segments**, opens it as a tab beside the dumps' tabs, or brings it forward where it is. There is one such window. Its toolbar holds the help button and, while the agent service is on, the Agent button. It is there with no annotation in it too, and then says how to make one; it is closed like any tab, with **⌘W** or the ✕ on its tab, and opened again the same way. The annotations are kept while it is closed.

When an agent annotates a place while the window is closed or another tab is in front, the toolbar's **Annotations** button shows a round badge, violet as the agent's annotations are, with the number of annotations not yet looked at. The badge goes when the window is brought forward; an annotation made while it is in front is counted as seen.

The window shows every annotation, in every file, open or not, as cards in as many columns as the window is wide. A card is drawn as the annotation is over the dump, in the colour of whoever made it; an agent's card has the agent's plug icon before its title, and a card made by hand a pencil. A click on the pencil opens the title and the note for editing; **Save** keeps the change, and the place stays as it was. A card holds:

- the title, with a ✕ on the card's corner;
- the file, after a dot: filled while the file is open, hollow while it is not;
- the node of **UEFI Structure** the place lies in, after its parent, as the Contents search results name it — a link that shows the place. A place in decompressed or decoded bytes has badges with the codecs the bytes came through — `LZMA`, `XOR C0` — before it, as the header of a fragment panel shows them. A node name too long for the line continues on the next one, under its own start. In a file with no firmware tree the addresses are shown instead;
- the whole note;
- the annotations it is about — a pointer and its target, a checksum and what it covers — each a link to its card. Over the dump they are listed after the note, under **Related Annotations:**.

The newest card comes first and wears a **New** tag on its top edge — a card made while the window is open at once, one made while it is closed or behind another tab when the window is shown. The tags go when the window is left for another tab, closed or minimised.

A card can be dragged to another place with the mouse. While it is carried, the cards around it move aside to make room for it; when it is let go, the cards close up in order, with no gaps. Carried into the empty space below the last card of a column, a card goes to the last place. The order is kept, and a new card still comes first.

A click selects a card. **⇧**-click selects the cards from the one last clicked to the one clicked, in the cards' order; **⌘**-click adds a card to the selection or takes it out; **⌘A** selects every card; the arrow keys move the selection. A click with **⇧** or **⌘** only selects: on a link, the pencil or the ✕ it does nothing else. A double-click on a card, or **Return**, brings its file forward — or opens it in a new tab — and selects the place, as a step of the navigation history ([[topic:navigation|Moving Around]]). In a firmware image **UEFI Structure** opens beside the dump at the node the place is in, as a click on a Contents search result does. A place in decompressed or decoded bytes opens in a fragment panel of those bytes, with the place selected and **UEFI Structure** in that panel open to the node that holds it. A file opened for the purpose has its structure read first, and the sections on the way to the place decompressed — seconds on a large image — under a sheet with a progress bar; **Cancel** leaves the file open and goes nowhere. If the file has been moved or deleted since, the program says so.

The ✕ on a card removes that annotation; **Delete** removes the selected cards. The cards after a removed one move up to close the gap. Relations to a removed annotation go with it. **⌘Z** puts the cards last removed back where they stood, with their relations, and **⇧⌘Z** removes them again; this lasts while ByteRipper runs, not past a restart.
