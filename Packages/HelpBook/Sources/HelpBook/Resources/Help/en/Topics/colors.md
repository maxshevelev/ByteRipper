# What the Colours Mean

> Background says "different from the other file". Red text says "changed and not yet saved".

@covers settings.comparison

The two states are separate on purpose, and a byte can wear both at once.

## Difference — a background colour

In comparison mode, every byte that differs from the byte at the **same address** in the other file is given the difference background. Nothing else uses that background.

If one file is shorter, the bytes that only the longer file has are differences too, and the shorter file shows empty EOF cells in their place — a muted, distinct style, so a short read never looks like a file full of zeros.

## Unsaved change — red text

A byte that has been edited but not yet written to disk is drawn in **red**. Once the file is saved the red is removed: the byte is then what the file holds.

Red bytes are changes that exist only inside ByteRipper and not in the file on disk.

## Both states at once

A byte that both differs from the other file and has been edited carries **both**: the difference background, with red digits over it. The two states are independent, and neither suppresses the other.

## The other marks

- **The selection** is the standard highlight, and never conceals the difference background or the red.
- **Search matches** are filled in the system's unfocused-selection grey; the current match is drawn as a raised yellow bubble. A match over a differing byte is displayed as a difference, the comparison taking precedence.
- **A bookmarked row** draws its offset column as a coloured arrow with the address over it. It marks the row rather than the bytes, and does not affect the states above.
- **Zones** — the coloured outlines a [[topic:tools-overview|tool panel]] draws over the dump — mark a structure's byte range. A zone is an outline and a tint, not a background, so it can sit over differences without hiding them.

ByteRipper follows the system appearance, so all of this has a dark-mode form too. The palette is in [[topic:settings|Settings ▸ Appearance]].
