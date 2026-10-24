#!/usr/bin/env python3
"""Rebuild a PE32/PE32+ file from an EFI TE image, for loaders that want one.

Ghidra's PE loader starts at the DOS header and refuses a TE image, whose
signature is "VZ". A TE image is what an EDK2 build leaves behind when it
strips a PE down to what the firmware loader reads: a 40-byte header, the
section table, and the section data, with the DOS stub, the optional header
and the gaps removed. This script puts that scaffolding back.

The reconstruction is exact when the original header size — the `StrippedSize`
field — still has room for a full PE header with sixteen data directories.
That is the usual case; when it does not, the payload moves and the section
pointers are adjusted by the same delta, which is still a correct image but no
longer byte-for-byte the offsets the original PE had.

The full directory table is not optional: Ghidra's PE loader reads entry 14
(the COM descriptor) whatever `NumberOfRvaAndSizes` says, and a short table
makes that entry point into the section table.

Stdlib only. The conversion is deterministic, so its output can be diffed.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

TE_HEADER_SIZE = 40
SECTION_HEADER_SIZE = 40

MACHINES_64 = {0x8664, 0xAA64, 0x0200, 0x5064, 0x5128}
MACHINES = {
    0x014C: "x86", 0x8664: "x86_64", 0x01C0: "arm", 0x01C4: "arm_thumb",
    0xAA64: "aarch64", 0x0200: "itanium", 0x5064: "riscv64", 0x5128: "riscv128",
}


class ConversionError(Exception):
    pass


def align(value: int, to: int) -> int:
    return (value + to - 1) & ~(to - 1)


def convert(te: bytes, image_base: int | None = None) -> bytes:
    if len(te) < TE_HEADER_SIZE or te[:2] != b"VZ":
        raise ConversionError("not a TE image: the signature is not VZ")
    (signature, machine, count, subsystem, stripped,
     entry, base_of_code, base) = struct.unpack_from("<HHBBHIIQ", te, 0)
    if signature != 0x5A56:
        raise ConversionError("not a TE image: the signature is not VZ")
    if count == 0 or count > 96:
        raise ConversionError(f"the TE header declares {count} sections")
    section_table = TE_HEADER_SIZE
    if section_table + count * SECTION_HEADER_SIZE > len(te):
        raise ConversionError("the section table runs past the end of the image")
    if stripped < TE_HEADER_SIZE:
        raise ConversionError(f"StrippedSize {stripped:#x} is smaller than the TE header")

    sections = []
    for index in range(count):
        base_at = section_table + index * SECTION_HEADER_SIZE
        name = te[base_at:base_at + 8]
        (virtual_size, virtual_address, raw_size, raw_pointer,
         _, _, _, _, characteristics) = struct.unpack_from("<IIIIIIHHI", te, base_at + 8)
        sections.append({
            "name": name.rstrip(b"\0").decode("ascii", "replace"),
            "virtual_size": virtual_size,
            "virtual_address": virtual_address,
            "raw_size": raw_size,
            "raw_pointer": raw_pointer,
            "characteristics": characteristics,
        })
        # The PE loader reads the bytes at raw_pointer - stripped + 40 in a TE
        # file; that must be inside the image.
        file_offset = raw_pointer - stripped + TE_HEADER_SIZE
        if raw_size and not (TE_HEADER_SIZE <= file_offset and file_offset + raw_size <= len(te)):
            raise ConversionError(
                f"section {index} ({sections[-1]['name']!r}) points at "
                f"{file_offset:#x}, outside the image")

    is_64 = machine in MACHINES_64
    magic = 0x20B if is_64 else 0x10B
    # A TE header has two data directories (base reloc, debug), but the PE
    # loader reads a full sixteen-entry table whatever NumberOfRvaAndSizes
    # says: Ghidra looks at entry 14, the COM descriptor, to decide whether
    # the image is managed. A short table leaves that entry pointing into the
    # section table, and a value there can abort the import. Write all sixteen.
    directories = struct.unpack_from("<IIII", te, TE_HEADER_SIZE - 16)
    optional_size = 240 if is_64 else 224
    fixed_size = 0x40 + 4 + 20 + optional_size + count * SECTION_HEADER_SIZE
    # The section pointers stay as the TE header gave them when the original
    # header size has room; otherwise shift them by whole file-alignment units,
    # which keeps their alignment.
    if fixed_size <= stripped:
        header_size = stripped
    else:
        header_size = stripped + align(fixed_size - stripped, 0x20)
    delta = header_size - stripped
    if header_size > 0x10000:
        raise ConversionError(f"the rebuilt header would be {header_size:#x} bytes")

    image_size = 0
    size_of_code = 0
    size_of_data = 0
    for section in sections:
        extent = section["virtual_address"] + max(section["virtual_size"], section["raw_size"])
        image_size = max(image_size, extent)
        if section["characteristics"] & 0x20:       # IMAGE_SCN_CNT_CODE
            size_of_code += section["raw_size"]
        elif section["characteristics"] & 0x40:     # IMAGE_SCN_CNT_INITIALIZED_DATA
            size_of_data += section["raw_size"]
    image_size = align(image_size, 0x20)

    base_value = base if image_base is None else image_base
    characteristics = 0x0002 | 0x0004                 # EXECUTABLE_IMAGE | LINE_NUMS_STRIPPED
    if not is_64:
        characteristics |= 0x0100                     # 32BIT_MACHINE
    if subsystem in (0x0B, 0x0C):
        characteristics |= 0x2000                     # DLL

    out = bytearray(header_size)
    # DOS header: MZ, e_lfanew at 0x3C.
    out[0:2] = b"MZ"
    struct.pack_into("<I", out, 0x3C, 0x40)
    # PE signature and COFF header.
    out[0x40:0x44] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", out, 0x44, machine, count, 0, 0, 0,
                     optional_size, characteristics)
    optional = 0x58

    def put(fmt: str, offset: int, *values: int) -> None:
        struct.pack_into(fmt, out, offset, *values)

    put("<HBB", optional, magic, 0, 0)                # magic, linker versions
    put("<III", optional + 4, size_of_code, size_of_data, 0)
    put("<II", optional + 16, entry, base_of_code)
    cursor = optional + 24
    if is_64:
        put("<Q", cursor, base_value)
        cursor += 8
    else:
        # PE32 has BaseOfData before ImageBase; PE32+ has no BaseOfData at all.
        put("<I", cursor, 0)                            # BaseOfData, unused
        put("<I", cursor + 4, base_value & 0xFFFFFFFF)
        cursor += 8
    put("<II", cursor, 0x20, 0x20)                    # Section/FileAlignment
    put("<HHHHHH", cursor + 8, 0, 0, 0, 0, 0, 0)      # OS/image/subsystem versions
    put("<I", cursor + 20, 0)                         # Win32VersionValue
    put("<III", cursor + 24, image_size, header_size, 0)  # SizeOfImage/Headers/Checksum
    put("<HH", cursor + 36, subsystem, 0)             # Subsystem, DllCharacteristics
    if is_64:
        put("<QQQQ", cursor + 40, 0x100000, 0x1000, 0x100000, 0x1000)
        cursor += 72
    else:
        put("<IIII", cursor + 40, 0x100000, 0x1000, 0x100000, 0x1000)
        cursor += 56
    put("<II", cursor, 0, 16)                         # LoaderFlags, NumberOfRvaAndSizes
    put("<IIII", cursor + 8, *directories)            # base reloc, debug; the rest stay zero

    for index, section in enumerate(sections):
        at = optional + optional_size + index * SECTION_HEADER_SIZE
        out[at:at + 8] = section["name"].encode("ascii")[:8].ljust(8, b"\0")
        struct.pack_into("<IIII", out, at + 8,
                         section["virtual_size"], section["virtual_address"],
                         section["raw_size"], section["raw_pointer"] + delta)
        struct.pack_into("<I", out, at + 36, section["characteristics"])

    # Everything after the TE header holds the section data, at the offsets the
    # TE section table names once the header has been re-expanded.
    out.extend(te[TE_HEADER_SIZE:])
    return bytes(out)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Rebuild a PE image from an EFI TE image.")
    parser.add_argument("input", type=Path)
    parser.add_argument("-o", "--output", type=Path)
    parser.add_argument("--image-base", type=lambda s: int(s, 0),
                        help="override the TE header's ImageBase")
    args = parser.parse_args(argv)

    try:
        result = convert(args.input.read_bytes(), args.image_base)
    except ConversionError as error:
        print(f"{args.input}: {error}", file=sys.stderr)
        return 1
    output = args.output or args.input.with_suffix(".pe")
    output.write_bytes(result)
    machine = MACHINES.get(struct.unpack_from("<H", result, 0x44)[0],
                           hex(struct.unpack_from("<H", result, 0x44)[0]))
    base = struct.unpack_from("<Q", result, 0x58 + 24)[0] \
        if struct.unpack_from("<H", result, 0x58)[0] == 0x20B \
        else struct.unpack_from("<I", result, 0x58 + 28)[0]
    print(f"{args.input} -> {output}: {machine}, image base {base:#x}, "
          f"{len(result)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
