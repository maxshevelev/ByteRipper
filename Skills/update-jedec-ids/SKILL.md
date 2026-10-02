---
name: update-jedec-ids
description: Regenerate Packages/UEFIImage/Sources/UEFIImage/JedecIDs.swift from the UEFITool repository's common/descriptor.cpp and the Linux kernel's and flashrom's chip tables. Use when the SPI flash chip names the descriptor's detail panel shows next to a VSCC table's JEDEC ids need refreshing from upstream, when the user asks to "update the JEDEC ids" / "sync the flash chip names", or after LongSoft/UEFITool changes that file.
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

1. **UEFITool** — the `jedecIdToUString` switch. Its name wins when several know an id.
2. **Linux kernel** — `drivers/mtd/spi-nor/<vendor>.c` on `master`, for the
   vendors its `Makefile` builds. Entries with a three-byte `SNOR_ID` and a
   `.name`; the name is shown as vendor plus the part in capitals (`XMC
   XM25QH64A`). Entries without a name or id, or with a longer id, are skipped.
3. **flashrom** — `flashchips/*.c` on `main`, ids resolved through
   `include/flashchips.h`. Only SPI chips probed by plain RDID; the first entry
   for an id wins.

The name is the first source's that knows the id; the size is the first any
lists, in the same order, also for an entry UEFITool named. Each entry keeps
the source its *name* came from.

The kernel's tables and flashrom are GPL-2.0. The decision, written in the
generated file's header, is that only facts are taken — id, vendor and part
name, capacity — and none of their code or comments. Take nothing else.

```sh
python3 Skills/update-jedec-ids/scripts/gen_jedec.py \
    --linux ../linux/drivers/mtd/spi-nor --flashrom ../flashrom   # local checkouts
```

## Scheduled run

`.github/workflows/refresh-jedec-ids.yml` runs the generator every Monday (and
on demand) and, only when the table changed and the `UEFIImage` tests pass,
opens or updates one PR from `automation/refresh-jedec-ids`. It never commits
to `main`. It needs *Allow GitHub Actions to create and approve pull requests*
enabled in the repository's Actions settings. The PR is still read by a person,
as in the steps below.

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
