#!/usr/bin/env python3
"""Locate, describe and extract the PEI/DXE images inside a UEFI dump.

This is the offline fallback for `byteripper_extract.py`: with ByteRipper open,
ask the app's UEFI Structure tree instead, because it opens Tiano as well as
LZMA and it is the panel the person is looking at. This script exists for a
machine with no app running. It walks firmware volumes, FFS files and sections,
opens the LZMA sections the standard library can, and reports every PE32/TE
image with the address its own headers declare. Its header parsers are also
what `byteripper_extract.py` uses to describe an extracted module.

Stdlib only, read-only: it writes only the file named by --out and the manifest
named by --manifest. The structures it reads are the ones in
`Design/UEFI/UEFI_IMAGE_FORMAT.md` §3, §5 and §6.

Use `--list` (the default) to see what is there, `--guid` to extract one module
by the GUID of the FFS file that holds it, or `--at` to extract the module
starting at a file offset the user read off the tree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import lzma
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------- constants

FV_SIGNATURE = b"_FVH"
FV_SIGNATURE_OFFSET = 0x28
FFS_HEADER_SIZE = 0x18
FFS_LARGE_HEADER_SIZE = 0x20
FFS_LENOVO_HEADER_SIZE = 0x1C

FFS_V1 = "7A9354D9-0468-444A-81CE-0BF617D890DF"
FFS_V3 = "5473C07A-3DCB-4DCA-BD6F-1E9689E7349A"
FFS_V2_FAMILY = {
    "8C8CE578-8A3D-4F1C-9935-896185C32DD3",
    "04ADEEAD-61FF-4D31-B6BA-64F8BF901F5A",  # Apple immutable
    "BD001B8C-6A71-487B-A14F-0C2A2DCF7A5D",  # Apple authentication
    "AD3FFFFF-D28B-44C4-9F13-9EA98A97F9F0",  # Intel
    "D6A1CD70-4B33-4994-A6EA-375F2CCC5437",  # Intel 2
    "4F494156-AED6-4D64-A537-B8A5557BCEEC",  # Sony
    "372B56DF-CC9F-4817-AB97-0A10A92CEAA5",  # HP
}

FILE_TYPES = {
    0x01: "RAW", 0x02: "FREEFORM", 0x03: "SECURITY_CORE",
    0x04: "PEI_CORE", 0x05: "DXE_CORE", 0x06: "PEIM", 0x07: "DRIVER",
    0x08: "COMBINED_PEIM_DRIVER", 0x09: "APPLICATION", 0x0A: "MM",
    0x0B: "FIRMWARE_VOLUME_IMAGE", 0x0C: "COMBINED_MM_DXE",
    0x0D: "MM_CORE", 0x0E: "MM_STANDALONE", 0x0F: "MM_CORE_STANDALONE",
    0xF0: "PAD",
}

SECTION_TYPES = {
    0x01: "COMPRESSION", 0x02: "GUID_DEFINED", 0x03: "DISPOSABLE",
    0x10: "PE32", 0x11: "PIC", 0x12: "TE", 0x13: "DXE_DEPEX",
    0x14: "VERSION", 0x15: "USER_INTERFACE", 0x16: "COMPATIBILITY16",
    0x17: "FIRMWARE_VOLUME_IMAGE", 0x18: "FREEFORM_SUBTYPE_GUID",
    0x19: "RAW", 0x1B: "PEI_DEPEX", 0x1C: "MM_DEPEX",
}

# Section-definition GUIDs, `UEFI_IMAGE_FORMAT.md` §6.3. Only the entries with
# a decompressor here are used; the rest are reported by name and left closed.
GUID_DEFINED = {
    "FC1BCDB0-7D31-49AA-936A-A4600D9DD083": ("crc32", "CRC32, not compressed"),
    "A31280AD-481E-41B6-95E8-127F4C984779": ("tiano", "Tiano"),
    "EE4E5898-3914-4259-9D6E-DC7BD79403CF": ("lzma", "LZMA"),
    "0ED85E23-F253-413F-A03C-901987B04397": ("lzma", "LZMA (HP)"),
    "BD9921EA-ED91-404A-8B2F-B4D724747C8C": ("lzma", "LZMA (Microsoft)"),
    "D42AE6BD-1352-4BFB-909A-CA72A6EAE889": ("lzma-x86", "LZMA with x86 filter"),
    "1D301FE9-BE79-4353-91C2-D23BC959AE0C": ("gzip", "GZip"),
    "CE3233F5-2CD6-4D87-9152-4A238BB6D1C4": ("zlib", "Zlib (AMD)"),
    "991EFAC0-E260-416B-A4B8-3B153072B804": ("zlib", "Zlib (AMD, second)"),
    "3D532050-5CDA-4FD0-879E-0F7F630D5AFB": ("brotli", "Brotli"),
    "0F9D89E8-9259-4F76-A5AF-0C89E34023DF": ("signed", "firmware contents signed"),
}

MACHINES = {
    0x014C: "x86", 0x8664: "x86_64", 0x01C0: "arm", 0x01C4: "arm_thumb",
    0xAA64: "aarch64", 0x0200: "itanium", 0x5064: "riscv64", 0x5128: "riscv128",
}

SUBSYSTEMS = {
    0x0A: "EFI application", 0x0B: "EFI boot service driver",
    0x0C: "EFI runtime driver", 0x0D: "EFI ROM",
}

MAX_DEPTH = 24


# ---------------------------------------------------------------- helpers

def u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def u24(data: bytes, offset: int) -> int:
    return data[offset] | data[offset + 1] << 8 | data[offset + 2] << 16


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def u64(data: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", data, offset)[0]


def align(value: int, to: int) -> int:
    return (value + to - 1) & ~(to - 1)


def guid_text(raw: bytes) -> str:
    a, b, c = struct.unpack_from("<IHH", raw, 0)
    return (f"{a:08X}-{b:04X}-{c:04X}-"
            f"{raw[8]:02X}{raw[9]:02X}-{raw[10]:02X}{raw[11]:02X}"
            f"{raw[12]:02X}{raw[13]:02X}{raw[14]:02X}{raw[15]:02X}")


def guid_key(text: str) -> str:
    return text.replace("-", "").replace("{", "").replace("}", "").upper()


def hexs(value: int) -> str:
    return f"0x{value:X}"


def ffs_version(file_system: str) -> int | None:
    if file_system == FFS_V1:
        return 1
    if file_system == FFS_V3:
        return 3
    if file_system in FFS_V2_FAMILY:
        return 2
    return None


# ---------------------------------------------------------------- records

@dataclass
class Space:
    """A byte buffer the tree reads from: the file, or an LZMA section's output."""
    id: int
    data: bytes
    origin: str

    @property
    def label(self) -> str:
        return "file" if self.id == 0 else self.origin


@dataclass
class Volume:
    space: int
    start: int
    length: int
    revision: int
    header_size: int
    file_system: str
    ffs: int
    erase_polarity: bool


@dataclass
class File:
    space: int
    start: int
    size: int
    header_size: int
    guid: str
    type: int
    attributes: int
    state: int
    ffs: int
    volume_revision: int

    @property
    def body_start(self) -> int:
        return self.start + self.header_size


@dataclass
class Module:
    space: int
    offset: int
    size: int
    kind: str                     # "PE32" or "TE"
    file_guid: str | None
    file_type: int | None
    file_start: int | None
    section_type: int | None
    info: dict
    path: list[str] = field(default_factory=list)


# ---------------------------------------------------------------- scanner

class Scanner:
    def __init__(self, image: Path, data: bytes):
        self.image = image
        self.spaces: list[Space] = [Space(0, data, "file")]
        self.volumes: list[Volume] = []
        self.modules: list[Module] = []
        self.closed: list[dict] = []       # sections we could not open
        self._walked: set[tuple[int, int]] = set()
        self._space_for_section: dict[int, int] = {}

    # -- spaces ---------------------------------------------------------

    def new_space(self, data: bytes, origin: str) -> Space:
        space = Space(len(self.spaces), data, origin)
        self.spaces.append(space)
        self.scan_space(space.id)
        return space

    # -- volumes --------------------------------------------------------

    def scan_space(self, space_id: int, start: int = 0, end: int | None = None) -> None:
        data = self.spaces[space_id].data
        end = len(data) if end is None else end
        position = start
        while True:
            signature = data.find(FV_SIGNATURE, position, end)
            if signature < 0:
                break
            position = signature + 1
            volume = self.volume_at(space_id, signature - FV_SIGNATURE_OFFSET)
            if volume is None or (space_id, volume.start) in self._walked:
                continue
            self._walked.add((space_id, volume.start))
            self.volumes.append(volume)
            self.walk_volume(volume, depth=0)

    def volume_at(self, space_id: int, start: int) -> Volume | None:
        data = self.spaces[space_id].data
        if start < 0 or start + 0x38 > len(data):
            return None
        if data[start + FV_SIGNATURE_OFFSET:start + FV_SIGNATURE_OFFSET + 4] != FV_SIGNATURE:
            return None
        length = u64(data, start + 0x20)
        revision = data[start + 0x37]
        header_length = u16(data, start + 0x30)
        if revision not in (1, 2):
            return None
        if length < 0x48 or start + length > len(data):
            return None
        if header_length < 0x38 or start + header_length > len(data):
            return None
        file_system = guid_text(data[start + 0x10:start + 0x20])
        ffs = ffs_version(file_system)
        if ffs is None:
            return None
        header_size = header_length
        if revision > 1:
            ext = u16(data, start + 0x34)
            if ext:
                if start + ext + 8 > len(data):
                    return None
                ext_size = u32(data, start + ext + 16)
                if start + ext + ext_size <= len(data):
                    header_size = align(ext + ext_size, 8)
        attributes = u32(data, start + 0x2C)
        return Volume(
            space=space_id, start=start, length=length, revision=revision,
            header_size=align(header_size, 8), file_system=file_system, ffs=ffs,
            # EFI_FVB2_ERASE_POLARITY
            erase_polarity=bool(attributes & 0x800),
        )

    def walk_volume(self, volume: Volume, depth: int) -> None:
        data = self.spaces[volume.space].data
        offset = align(volume.start + volume.header_size, 8)
        end = min(volume.start + volume.length, len(data))
        empty = b"\xff" if volume.erase_polarity else b"\x00"
        while offset + FFS_HEADER_SIZE <= end:
            header = data[offset:offset + FFS_HEADER_SIZE]
            if header == empty * FFS_HEADER_SIZE:
                break
            guid = guid_text(header[:16])
            attributes = header[0x13]
            short_size = u24(header, 0x14)
            if volume.ffs == 3 and attributes & 0x01:
                if offset + FFS_LARGE_HEADER_SIZE > end:
                    break
                size = u64(data, offset + 0x18)
                header_size = FFS_LARGE_HEADER_SIZE
            elif volume.ffs == 2 and volume.revision == 2 and attributes & 0x01:
                if offset + FFS_LENOVO_HEADER_SIZE > end:
                    break
                size = u32(data, offset + 0x18)
                header_size = FFS_LENOVO_HEADER_SIZE
            else:
                size = short_size
                header_size = FFS_HEADER_SIZE
            if size == 0 or offset + size > end:
                break
            ffs_file = File(
                space=volume.space, start=offset, size=size, header_size=header_size,
                guid=guid, type=header[0x12], attributes=attributes,
                state=header[0x17], ffs=volume.ffs, volume_revision=volume.revision,
            )
            self.walk_file(ffs_file, depth)
            offset = align(offset + size, 8)

    # -- files and sections --------------------------------------------

    def walk_file(self, ffs_file: File, depth: int) -> None:
        data = self.spaces[ffs_file.space].data
        start = ffs_file.body_start
        end = min(ffs_file.start + ffs_file.size, len(data))
        if start >= end:
            return

        # A raw file can hold a module directly; a typed file's body is sections.
        if ffs_file.type in (0x01, 0xF0):
            self.module_at(ffs_file.space, start, end - start, ffs_file)
            return
        before = len(self.modules)
        self.walk_sections(ffs_file.space, start, end, ffs_file.ffs,
                           ffs_file, depth, [])
        # A body that did not read as sections can still open with an image.
        if len(self.modules) == before and ffs_file.type not in (0x01, 0xF0):
            self.module_at(ffs_file.space, start, end - start, ffs_file)

    def walk_sections(self, space_id: int, start: int, end: int, ffs: int,
                      ffs_file: File | None, depth: int,
                      path: list[str]) -> None:
        data = self.spaces[space_id].data
        if depth > MAX_DEPTH:
            return
        offset = start
        while offset + 4 <= end:
            size = u24(data, offset)
            section_type = data[offset + 3]
            header = 4
            if size == 0xFFFFFF:
                if offset + 8 > end:
                    break
                size = u32(data, offset + 4)
                header = 8
            if size < header or offset + size > end:
                break
            name = SECTION_TYPES.get(section_type, f"0x{section_type:02X}")
            here = path + [f"{name}@{hexs(offset)}"]
            body = offset + header
            body_end = offset + size

            if section_type in (0x10, 0x12):
                self.module_at(space_id, body, body_end - body, ffs_file,
                               section_type=section_type, path=here)
            elif section_type == 0x01:
                self.compression_section(space_id, offset, body, body_end, ffs,
                                         ffs_file, depth, here)
            elif section_type == 0x02:
                self.guid_defined_section(space_id, offset, body, body_end, ffs,
                                          ffs_file, depth, here)
            elif section_type == 0x17:
                # A nested volume. The file-space scan finds it by its signature;
                # in a decompressed space the same scan runs over that space.
                self.scan_space(space_id, body, body_end)

            offset = align(offset + size, 4)

    def compression_section(self, space_id: int, section_start: int, start: int,
                            end: int, ffs: int, ffs_file: File | None, depth: int,
                            path: list[str]) -> None:
        data = self.spaces[space_id].data
        if start + 5 > end:
            return
        uncompressed = u32(data, start)
        algorithm = data[start + 4]
        payload = start + 5
        if algorithm == 0:
            self.walk_sections(space_id, payload, end, ffs, ffs_file, depth + 1, path)
            return
        self.closed.append({
            "space": self.spaces[space_id].label,
            "offset": hexs(section_start),
            "size": hexs(end - section_start),
            "kind": f"EFI compression type {algorithm}",
            "uncompressed": hexs(uncompressed),
            "path": " > ".join(path),
            "file_guid": ffs_file.guid if ffs_file else None,
        })

    def guid_defined_section(self, space_id: int, section_start: int, start: int,
                             end: int, ffs: int, ffs_file: File | None, depth: int,
                             path: list[str]) -> None:
        data = self.spaces[space_id].data
        if start + 20 > end:
            return
        definition = guid_text(data[start:start + 16])
        data_offset = u16(data, start + 16)
        payload = start + data_offset
        if payload >= end or data_offset < 20:
            return
        kind, label = GUID_DEFINED.get(definition, ("unknown", definition))
        here = path + [label]

        if kind == "crc32":
            self.walk_sections(space_id, payload, end, ffs, ffs_file, depth + 1, here)
            return
        if kind == "lzma" or kind == "lzma-x86":
            if kind == "lzma-x86":
                self.note_closed(space_id, section_start, end, "LZMA with x86 filter", here, ffs_file)
                return
            try:
                raw = data[payload:end]
                decompressed = lzma.decompress(raw, format=lzma.FORMAT_ALONE)
            except lzma.LZMAError as error:
                self.note_closed(space_id, section_start, end, f"LZMA ({error})", here, ffs_file)
                return
            origin = f"lzma@{hexs(section_start)}"
            inner = self.new_space(decompressed, origin)
            # The tree reads a decompressed body as sections; a volume at its
            # start was already found by scan_space in new_space.
            self.walk_sections(inner.id, 0, len(decompressed), 3, ffs_file,
                               depth + 1, here)
            return
        self.note_closed(space_id, section_start, end, label, here, ffs_file)

    def note_closed(self, space_id: int, start: int, end: int, kind: str,
                    path: list[str], ffs_file: File | None) -> None:
        self.closed.append({
            "space": self.spaces[space_id].label,
            "offset": hexs(start),
            "size": hexs(end - start),
            "kind": kind,
            "path": " > ".join(path),
            "file_guid": ffs_file.guid if ffs_file else None,
        })

    # -- images ---------------------------------------------------------

    def module_at(self, space_id: int, offset: int, size: int,
                  ffs_file: File | None, section_type: int | None = None,
                  path: list[str] | None = None) -> None:
        data = self.spaces[space_id].data
        if size < 0x40 or offset + 0x40 > len(data):
            return
        magic = data[offset:offset + 2]
        if magic == b"VZ":
            info = parse_te(data, offset, size)
            kind = "TE"
        elif magic == b"MZ":
            info = parse_pe(data, offset, size)
            kind = "PE32" if info else None
        else:
            return
        if not info:
            return
        self.modules.append(Module(
            space=space_id, offset=offset, size=size, kind=kind,
            file_guid=ffs_file.guid if ffs_file else None,
            file_type=ffs_file.type if ffs_file else None,
            file_start=ffs_file.start if ffs_file else None,
            section_type=section_type, info=info, path=path or [],
        ))

    # -- reports --------------------------------------------------------

    def manifest(self) -> dict:
        return {
            "image": str(self.image),
            "size": len(self.spaces[0].data),
            "volumes": [
                {
                    "space": self.spaces[v.space].label,
                    "start": hexs(v.start),
                    "length": hexs(v.length),
                    "revision": v.revision,
                    "file_system": v.file_system,
                    "ffs": v.ffs,
                }
                for v in self.volumes
            ],
            "modules": [module_report(module, self.spaces[module.space]) for module in self.modules],
            "closed": self.closed,
        }


def parse_te(data: bytes, offset: int, size: int) -> dict | None:
    """EFI_TE_IMAGE_HEADER, 40 bytes, then the PE section headers."""
    if size < 40:
        return None
    signature, machine, count, subsystem, stripped = struct.unpack_from(
        "<HHBBH", data, offset)
    if signature != 0x5A56 or count == 0 or count > 96:
        return None
    entry, base_of_code, image_base = struct.unpack_from("<IIQ", data, offset + 8)
    if 40 + count * 40 > size:
        return None
    if stripped < 40 or stripped > 0x10000:
        return None
    sections = parse_sections(data, offset + 40, count)
    if sections is None:
        return None
    for section in sections:
        # The PE loader reads a TE section at PointerToRawData - StrippedSize
        # + sizeof(TE header); the file bytes are there.
        section["file_offset"] = section["raw_pointer"] - stripped + 40
    return {
        "kind": "TE",
        "machine": MACHINES.get(machine, f"0x{machine:04X}"),
        "machine_id": f"0x{machine:04X}",
        "subsystem": subsystem,
        "subsystem_name": SUBSYSTEMS.get(subsystem, f"0x{subsystem:02X}"),
        "stripped_size": hexs(stripped),
        "image_base": hexs(image_base),
        "entry_point": hexs(entry),
        "base_of_code": hexs(base_of_code),
        "sections": sections,
    }


def parse_pe(data: bytes, offset: int, size: int) -> dict | None:
    if size < 0x40:
        return None
    lfanew = u32(data, offset + 0x3C)
    nt = offset + lfanew
    if lfanew < 0x40 or nt + 24 > offset + size:
        return None
    if data[nt:nt + 4] != b"PE\0\0":
        return None
    machine, count = struct.unpack_from("<HH", data, nt + 4)
    optional_size = u16(data, nt + 20)
    optional = nt + 24
    if optional + optional_size > offset + size:
        return None
    magic = u16(data, optional)
    if magic == 0x10B:
        entry = u32(data, optional + 16)
        image_base = u32(data, optional + 28)
        subsystem = u16(data, optional + 68)
    elif magic == 0x20B:
        entry = u32(data, optional + 16)
        image_base = u64(data, optional + 24)
        subsystem = u16(data, optional + 68)
    else:
        return None
    section_table = optional + optional_size
    sections = parse_sections(data, section_table, count)
    if sections is None:
        return None
    for section in sections:
        section["file_offset"] = section["raw_pointer"]
    return {
        "kind": "PE32+" if magic == 0x20B else "PE32",
        "machine": MACHINES.get(machine, f"0x{machine:04X}"),
        "machine_id": f"0x{machine:04X}",
        "subsystem": subsystem,
        "subsystem_name": SUBSYSTEMS.get(subsystem, f"0x{subsystem:02X}"),
        "image_base": hexs(image_base),
        "entry_point": hexs(entry),
        "sections": sections,
    }


def parse_sections(data: bytes, start: int, count: int) -> list[dict] | None:
    if start + count * 40 > len(data):
        return None
    sections = []
    for index in range(count):
        base = start + index * 40
        name = data[base:base + 8].rstrip(b"\0").decode("ascii", "replace")
        virtual_size, virtual_address, raw_size, raw_pointer = struct.unpack_from(
            "<IIII", data, base + 8)
        characteristics = u32(data, base + 36)
        sections.append({
            "name": name,
            "virtual_size": hexs(virtual_size),
            "virtual_address": hexs(virtual_address),
            "raw_size": hexs(raw_size),
            "raw_pointer": raw_pointer,
            "characteristics": f"0x{characteristics:08X}",
        })
    return sections


def module_report(module: Module, space: Space) -> dict:
    report = {
        "space": space.label,
        "offset": hexs(module.offset),
        "size": hexs(module.size),
        "kind": module.kind,
        "file_guid": module.file_guid,
        "file_type": module.file_type,
        "file_type_name": FILE_TYPES.get(module.file_type, None) if module.file_type is not None else None,
        "file_start": hexs(module.file_start) if module.file_start is not None else None,
        "section_type": module.section_type,
        "section_name": SECTION_TYPES.get(module.section_type) if module.section_type is not None else None,
        "path": module.path,
    }
    report.update(module.info)
    return report


# ---------------------------------------------------------------- command line

def find_modules(scanner: Scanner, guid: str | None) -> list[Module]:
    if guid is None:
        return scanner.modules
    wanted = guid_key(guid)
    return [m for m in scanner.modules
            if m.file_guid is not None and guid_key(m.file_guid) == wanted]


def describe(scanner: Scanner) -> str:
    lines = [f"{scanner.image}: {len(scanner.spaces[0].data)} bytes, "
             f"{len(scanner.volumes)} volumes, {len(scanner.modules)} images"]
    for module in scanner.modules:
        info = module.info
        file_name = f"{module.file_guid} {FILE_TYPES.get(module.file_type, '?')}" \
            if module.file_guid else "(loose image)"
        section = SECTION_TYPES.get(module.section_type, "?") \
            if module.section_type is not None else "?"
        lines.append(
            f"  {hexs(module.offset):>12}  {file_name:<45}"
            f"  {section:<6} {module.kind:<5} {info['machine']:<8}"
            f" base {info['image_base']:>10}  entry {info['entry_point']:>8}"
            f"  {hexs(module.size):>10}"
            f"  [{scanner.spaces[module.space].label}]"
        )
    if scanner.closed:
        lines.append("  sections not opened by this script:")
        for item in scanner.closed:
            lines.append(f"    {item['offset']:>12}  {item['kind']:<28}"
                         f"  {item['path']}")
        lines.append("  Open those in ByteRipper (UEFI Structure) and read the "
                     "node with the agent's `uefi_node_data`.")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Find, describe and extract UEFI PEI/DXE images.")
    parser.add_argument("image", type=Path, help="the firmware image")
    parser.add_argument("--manifest", type=Path,
                        help="write the full scan as JSON")
    parser.add_argument("--guid", help="extract the image in the file with this GUID")
    parser.add_argument("--at", help="extract the image starting at this file offset (0x…)")
    parser.add_argument("--index", type=int, default=0,
                        help="which match to extract when several do (default 0)")
    parser.add_argument("--out", type=Path, help="where to write the image")
    parser.add_argument("--meta", type=Path, help="write the extracted image's facts as JSON")
    args = parser.parse_args(argv)

    data = args.image.read_bytes()
    scanner = Scanner(args.image, data)
    scanner.scan_space(0)

    if args.manifest:
        args.manifest.write_text(json.dumps(scanner.manifest(), indent=2) + "\n")

    if args.guid is None and args.at is None:
        print(describe(scanner))
        return 0

    if args.guid is not None:
        matches = find_modules(scanner, args.guid)
        what = f"GUID {args.guid}"
    else:
        try:
            wanted = int(args.at, 0)
        except ValueError:
            print(f"--at: {args.at!r} is not an offset", file=sys.stderr)
            return 2
        matches = [m for m in scanner.modules
                   if m.space == 0 and m.offset <= wanted < m.offset + m.size]
        # An image that starts exactly where the caller looked wins over the
        # one that merely holds the address.
        exact = [m for m in matches if m.space == 0 and m.offset == wanted]
        if exact:
            matches = exact
        what = f"offset {hexs(wanted)}"

    if not matches:
        print(f"No image for {what}. Run without --guid to list them.", file=sys.stderr)
        return 1
    if args.index >= len(matches):
        print(f"{what}: {len(matches)} images, no index {args.index}", file=sys.stderr)
        return 1
    module = matches[args.index]
    blob = scanner.spaces[module.space].data[module.offset:module.offset + module.size]
    out = args.out or args.image.with_name(f"module-{module.offset:X}.bin")
    out.write_bytes(blob)

    report = module_report(module, scanner.spaces[module.space])
    report["file"] = str(out)
    report["sha256"] = hashlib.sha256(blob).hexdigest()
    if args.meta:
        args.meta.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
