@term dump
@name Dump
@short The contents of a chip, read out into a file.

A dump is what a programmer gives you when it reads a flash chip: every byte, in order, starting at address zero. Its size is the chip's size.

Because the file is the chip, an address in the file is an address on the chip — which is why ByteRipper compares by address and never shifts one file against another.

@see topic:overview
@see term:offset

@term offset
@name Offset (address)
@short A byte's position in the file, counted from zero.

Offsets in ByteRipper are zero-based and shown in hex. Offset `0` is the first byte; offset `0x1000` is the 4097th.

Everywhere the app takes an offset from you, hex needs the `0x` prefix and decimal needs no prefix.

Ranges inside the app are half-open: `[start, end)`, where the end is the first byte *not* included. A dialog may let you type an inclusive end, and converts it for you.

@see topic:navigation

@term checksum
@name Checksum
@short A small number stored inside a structure so that damage to it can be noticed.

A checksum is computed from a structure's own bytes and stored in it. Whatever reads the structure later recomputes it: if the two do not match, something changed.

Checksums are arithmetic, not cryptography. Anyone can recompute one, which is why ByteRipper can offer to fix them — and also why a correct checksum proves nothing about who wrote the bytes.

@see topic:recipe-checksums
@see term:crc

@term crc
@name CRC (cyclic redundancy check)
@short A stronger kind of checksum, and the one most firmware structures use.

A CRC — usually CRC-32 here — catches the kinds of damage a simple sum misses: a reordering, a shifted block, a run of flipped bits. Firmware tables use it widely.

Like any checksum it is a check against accident, not against tampering: it can be recomputed by anyone who changed the bytes.

@see term:checksum

@term signature
@name Signature
@short Two different things wear this name: a magic string, and a cryptographic signature.

**A magic signature** is a short fixed string at the start of a structure that says what the structure is: `_FVH` for a firmware volume, `$FPT` for the ME partition table, `_FIT_` for the interface table. That is how a parser finds things in a raw dump, and it is what a search for a few bytes ([[topic:search|⌘F]]) is usually looking for.

**A cryptographic signature** is a number computed over a region with a private key. It proves who produced those bytes, and it cannot be recomputed by anyone who does not hold the key. This is what makes some parts of a firmware image impossible to patch.

@see term:manifest
@see term:boot-guard

@term guid
@name GUID
@short A 16-byte identifier. UEFI uses them as names for almost everything.

A GUID looks like `8C8CE578-8A3D-4F1C-9935-896185C32DD3`. In a firmware image, files, sections, volumes and NVRAM variables are identified by GUID rather than by a text name.

GUIDs mean nothing on their own, which is why the app fetches a [[topic:databases|community catalogue]] of names for the well-known ones. A row that shows a bare GUID is a structure the catalogue has no name for — not an error.

@see term:ffs-file
@see topic:databases

@term zone
@name Zone
@short The coloured outline a firmware panel draws over a byte range in the dump.

When you select a row in a firmware panel, the panel publishes that row's byte range as a zone: an outline and a tint over those bytes in the hex view and a band in the [[topic:minimap|minimap]].

A zone is an outline rather than a background fill, so it never hides a difference or an unsaved edit underneath it.

@see topic:tools-overview
@see topic:tool-zones

@term flash-chip
@name SPI flash chip
@short The chip the firmware lives on: fixed size, erased to `FF`.

A serial flash chip holds the board's firmware. Two properties matter here:

- **Its size is fixed.** An image for an 8 MB chip must be exactly 8 MB. This is why nothing on a bench should ever change a dump's length.
- **Erased means `FF`.** Flash erases to all ones. A long run of `FF` in a dump is empty space, not damage; a long run of `00` usually is written data.

@see topic:bench-safety

@term programmer
@name Programmer
@short The hardware that reads and writes the chip. ByteRipper never talks to it.

ByteRipper works on files. Getting the bytes off the chip and back onto it is the programmer's job — a clip, a socket or an in-circuit connection, driven by its own software.

That separation is deliberate: the app can be used on a dump from any programmer, and it can never write to a board by accident.
