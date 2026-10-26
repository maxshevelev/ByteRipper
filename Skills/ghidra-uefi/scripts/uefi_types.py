#!/usr/bin/env python3
"""The UEFI types and GUID names the Ghidra pass names a module with.

`ApplyUefi.java` needs two things Ghidra does not ship:

- a data type archive of MdePkg — the PI and UEFI specifications' tables, every
  PPI and protocol — for the module's processor (`uefi_X64.gdt`,
  `uefi_Ia32.gdt`), which `BuildUefiTypes.java` parses from EDK2's headers;
- a GUID → name table: the GUIDs MdePkg and MdeModulePkg declare in their
  `.dec` files, with their canonical g…Guid names, and the catalogue the
  ByteRipper app names its tree with (LongSoft's `common/guids.csv`) for the
  vendor GUIDs EDK2 does not have.

Both are built once into a cache and reused:

    python3 uefi_types.py ensure            # build what is missing
    python3 uefi_types.py ensure --rebuild  # build everything again
    python3 uefi_types.py where             # print the cache's paths

The cache is `~/Library/Application Support/ByteRipper/Ghidra`. The EDK2 tag is
pinned (`EDK2_TAG`) so a module analyzed twice is typed by the same headers;
the tag is part of the analysis recipe.

Stdlib only; the external programs are git and Ghidra's analyzeHeadless.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ghidra_import

EDK2_URL = "https://github.com/tianocore/edk2"
EDK2_TAG = "edk2-stable202608"
GUIDS_URL = "https://raw.githubusercontent.com/LongSoft/UEFITool/new_engine/common/guids.csv"
DEC_FILES = ("MdePkg/MdePkg.dec", "MdeModulePkg/MdeModulePkg.dec")


def cache_root() -> Path:
    return Path.home() / "Library" / "Application Support" / "ByteRipper" / "Ghidra"


def paths(root: Path | None = None) -> dict[str, Path]:
    root = root or cache_root()
    return {
        "root": root,
        "edk2": root / EDK2_TAG,
        "gdt_x64": root / f"uefi_X64-{EDK2_TAG}.gdt",
        "gdt_ia32": root / f"uefi_Ia32-{EDK2_TAG}.gdt",
        "guids_csv": root / "guids.csv",
        "guids_tsv": root / f"guids-{EDK2_TAG}.tsv",
    }


def guid_bytes(data1: int, data2: int, data3: int, rest: list[int]) -> str:
    """The 16 bytes of an EFI_GUID as they lie in memory, as hex."""
    raw = (data1.to_bytes(4, "little") + data2.to_bytes(2, "little")
           + data3.to_bytes(2, "little") + bytes(rest))
    return raw.hex().upper()


def parse_registry_guid(text: str) -> str | None:
    """`4CF5B200-68B8-4CA5-9EEC-B23E3F50029A` → its memory bytes."""
    match = re.fullmatch(r"([0-9A-Fa-f]{8})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{4})-"
                         r"([0-9A-Fa-f]{4})-([0-9A-Fa-f]{12})", text.strip())
    if not match:
        return None
    tail = bytes.fromhex(match.group(4) + match.group(5))
    return guid_bytes(int(match.group(1), 16), int(match.group(2), 16),
                      int(match.group(3), 16), list(tail))


def canonical_name(name: str) -> str | None:
    """A catalogue name as EDK2 would spell the GUID's variable: g…Guid."""
    name = re.sub(r"[^A-Za-z0-9_]", "", name)
    if not name or not (name[0].isalpha() or name[0] == "_"):
        return None
    if not (name.startswith("g") and len(name) > 1 and name[1].isupper()):
        name = "g" + name[0].upper() + name[1:]
    if not name.endswith("Guid"):
        name += "Guid"
    return name


DEC_ENTRY = re.compile(
    r"^\s*(g\w+)\s*=\s*\{\s*0x([0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)\s*,"
    r"\s*\{([^}]*)\}\s*\}", re.MULTILINE)


def dec_guids(text: str) -> dict[str, str]:
    """The `[Guids]`, `[Protocols]` and `[Ppis]` entries of a `.dec` file."""
    found = {}
    for match in DEC_ENTRY.finditer(text):
        rest = [int(part, 16) for part in re.findall(r"0x([0-9A-Fa-f]+)", match.group(5))]
        if len(rest) != 8:
            continue
        key = guid_bytes(int(match.group(2), 16), int(match.group(3), 16),
                         int(match.group(4), 16), rest)
        found.setdefault(key, match.group(1))
    return found


def csv_guids(text: str) -> dict[str, str]:
    found = {}
    for line in text.splitlines():
        guid, _, name = line.partition(",")
        key = parse_registry_guid(guid)
        canonical = canonical_name(name)
        if key and canonical:
            found.setdefault(key, canonical)
    return found


def write_table(edk2: Path, csv: Path | None, out: Path) -> int:
    """EDK2's names first — they are the source's own — then the catalogue's."""
    table: dict[str, str] = {}
    for dec in DEC_FILES:
        path = edk2 / dec
        if path.exists():
            for key, name in dec_guids(path.read_text(encoding="utf-8", errors="replace")).items():
                table.setdefault(key, name)
    if csv and csv.exists():
        for key, name in csv_guids(csv.read_text(encoding="utf-8", errors="replace")).items():
            table.setdefault(key, name)
    out.write_text("".join(f"{key}\t{name}\n" for key, name in sorted(table.items())),
                   encoding="utf-8")
    return len(table)


def fetch_edk2(target: Path) -> None:
    """A sparse, shallow clone of the pinned tag: MdePkg's headers and the two
    `.dec` files, about 10 MB."""
    if target.exists():
        shutil.rmtree(target)
    subprocess.run(["git", "clone", "--quiet", "--depth", "1", "--branch", EDK2_TAG,
                    "--filter=blob:none", "--sparse", EDK2_URL, str(target)], check=True)
    subprocess.run(["git", "-C", str(target), "sparse-checkout", "set", "--no-cone",
                    "/MdePkg/Include/", *[f"/{dec}" for dec in DEC_FILES]], check=True)


def build_archives(ghidra: Path, edk2: Path, out_x64: Path, out_ia32: Path) -> None:
    """Runs BuildUefiTypes.java. A headless run needs a program to run a
    script against; a few raw bytes imported with the binary loader serve."""
    work = Path(tempfile.mkdtemp(prefix="ghidra-types-"))
    try:
        dummy = work / "dummy.bin"
        dummy.write_bytes(bytes(16))
        log = work / "types.log"
        command = [str(ghidra / "support" / "analyzeHeadless"), str(work), "types",
                   "-import", str(dummy), "-loader", "BinaryLoader",
                   "-processor", "x86:LE:64:default", "-noanalysis", "-deleteProject",
                   "-scriptPath", str(Path(__file__).resolve().parent),
                   "-preScript", "BuildUefiTypes.java", str(edk2), str(work)]
        with open(log, "w", encoding="utf-8") as handle:
            result = subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT)
        built = {"X64": work / "uefi_X64.gdt", "Ia32": work / "uefi_Ia32.gdt"}
        if result.returncode != 0 or not all(path.exists() for path in built.values()):
            tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-30:]
            print("\n".join(tail), file=sys.stderr)
            raise SystemExit(f"BuildUefiTypes failed (exit {result.returncode})")
        shutil.move(str(built["X64"]), out_x64)
        shutil.move(str(built["Ia32"]), out_ia32)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def ensure(ghidra_home: str | None = None, rebuild: bool = False,
           root: Path | None = None) -> dict[str, Path]:
    """Builds whatever of the cache is missing, and returns its paths."""
    where = paths(root)
    where["root"].mkdir(parents=True, exist_ok=True)
    if rebuild or not (where["edk2"] / "MdePkg" / "Include").exists():
        print(f"fetching {EDK2_TAG} headers …", file=sys.stderr)
        fetch_edk2(where["edk2"])
    if rebuild or not (where["gdt_x64"].exists() and where["gdt_ia32"].exists()):
        print("building the UEFI type archives (about a minute) …", file=sys.stderr)
        build_archives(ghidra_import.find_ghidra(ghidra_home), where["edk2"],
                       where["gdt_x64"], where["gdt_ia32"])
    if rebuild or not where["guids_csv"].exists():
        try:
            with urllib.request.urlopen(GUIDS_URL, timeout=30) as response:
                where["guids_csv"].write_bytes(response.read())
        except OSError as error:
            # EDK2's own names still name the standard GUIDs.
            print(f"guids.csv not fetched ({error}); EDK2's names only", file=sys.stderr)
    if rebuild or not where["guids_tsv"].exists():
        count = write_table(where["edk2"], where["guids_csv"], where["guids_tsv"])
        print(f"{count} GUID names", file=sys.stderr)
    return where


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Build the UEFI types and GUID names.")
    parser.add_argument("command", choices=["ensure", "where"])
    parser.add_argument("--rebuild", action="store_true")
    parser.add_argument("--ghidra-home")
    parser.add_argument("--cache", type=Path, help="the cache folder (default: Application Support)")
    args = parser.parse_args(argv)
    where = ensure(args.ghidra_home, args.rebuild, args.cache) if args.command == "ensure" \
        else paths(args.cache)
    for key, path in where.items():
        print(f"{key}\t{path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
