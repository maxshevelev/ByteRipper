---
name: update-jedec-ids
description: Regenerate Packages/UEFIImage/Sources/UEFIImage/JedecIDs.swift from the UEFITool repository's common/descriptor.cpp and flashrom's chip files. Use when the SPI flash chip names the descriptor's detail panel shows next to a VSCC table's JEDEC ids need refreshing from upstream, when the user asks to "update the JEDEC ids" / "sync the flash chip names", or after LongSoft/UEFITool changes that file.
---

# Update JEDEC ids

Regenerate the table that turns a JEDEC id into the name of a flash chip.

A flash descriptor's VSCC table lists the chips a board's firmware was built to
drive, by id alone — `EF4019`, `1C7018` — and an id is not something a bench
reads. UEFITool's `jedecIdToUString` is the table that names them, a `switch`
of one case per chip grouped by vendor, and this skill turns it into the one
generated Swift file the app compiles against:

```
Packages/UEFIImage/Sources/UEFIImage/JedecIDs.swift
```

## Run it

```sh
python3 Skills/update-jedec-ids/scripts/gen_jedec.py
```

Stdlib only, no arguments needed: it fetches
`common/descriptor.cpp` from `github.com/LongSoft/UEFITool` (branch
`new_engine`), reads the switch, and rewrites the Swift file — but only when
something changed. It prints how many chips it read and which vendors they came
from, so a run that silently read half the table is visible rather than
committed.

```sh
# a local checkout instead of the network
python3 Skills/update-jedec-ids/scripts/gen_jedec.py --source ../UEFITool/common/descriptor.cpp

# a ByteRipper tree somewhere else
python3 Skills/update-jedec-ids/scripts/gen_jedec.py --repo /path/to/ByteRipper
```

## Sources and precedence

1. **UEFITool** — the `jedecIdToUString` switch. Its name wins when both know an id.
2. **flashrom** — `flashchips/*.c` on `main`, ids resolved through
   `include/flashchips.h`. Only SPI chips probed by plain RDID; the first entry
   for an id wins. It adds the ids UEFITool lacks, and the size of every chip
   it lists, also those UEFITool names.

Each entry keeps the source its *name* came from. flashrom is GPL-2.0-or-later;
the decision, written in the generated file's header, is that only facts are
taken — id, vendor and part name, capacity — and none of its code or comments.
Take nothing else from it. Not yet read: the Linux kernel's `spi-nor` tables
(`drivers/mtd/spi-nor/<vendor>.c`, also GPL-2.0), planned between the two.

```sh
python3 Skills/update-jedec-ids/scripts/gen_jedec.py --flashrom ../flashrom   # a local checkout
```

## After a run

1. **Read the diff.** It is data, and the whole point of generating it is that
   the diff is reviewable: new chips appear as lines, a rename as a changed
   one. A diff that removes most of the file is a parse that went wrong, not an
   upstream deletion.
2. **Run the package's tests.**

   ```sh
   cd Packages/UEFIImage && swift test --filter DescriptorInfoTests
   ```

   `testTheChipCatalogueIsComplete` pins UEFITool's count and three names, and
   a floor for flashrom's. A regeneration that adds UEFITool chips *should*
   change the count — update that number in the same commit, so the next person can tell a real addition from a
   truncated read.
3. **Do not edit the generated file by hand.** The header says so, and the next
   run overwrites it.

## What it does not do

It reads only the name table. The descriptor's own structures — the master
section's layout, the region table, the upper map — are ported by hand into
`DescriptorInfo.swift`, because they are code rather than data: when UEFITool
changes those, this skill will not notice and the port has to be read again.
