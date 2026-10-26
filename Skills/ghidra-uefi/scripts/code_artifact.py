#!/usr/bin/env python3
"""Analyze one module once and keep the result as a content-addressed artifact.

This is the one-time half of the code plan: Ghidra loads the image, finds the
functions, reads every instruction, decompiles each function, and writes what
it found to a JSON artifact. The artifact is stored under the SHA-256 of the
module's own bytes, so the same module from another dump reuses it, and a
module whose bytes changed does not.

The other half is `code_query.py`, which reads the artifact without Ghidra.

    python3 code_artifact.py CpuPei.te --name CpuPei --document "CSME 15.bin" \
        --node 0.5.5.2.0.1.0.8.1

The store defaults to `~/Library/Application Support/ByteRipper/Analysis`,
beside the app's own data; `--store` puts it elsewhere. A TE image is converted
to PE for Ghidra and the original bytes are what the hash names.

Between Ghidra's analysis and the export, `ApplyUefi.java` types the module
from EDK2's headers and names its GUIDs, service tables, interfaces and the
functions its DEBUG messages name (`uefi_types.py` builds what it needs, once).
`--no-uefi` skips it; that analysis is a recipe of its own (`-plain-`).

Stdlib only; the external program is Ghidra's analyzeHeadless.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cas
import ghidra_import
import progress
import te_to_pe
import uefi_types

SCRIPT_VERSION = 4


def machine(blob: bytes) -> int | None:
    """The image's COFF machine: at offset 2 of a TE header, after the PE
    signature of a PE image."""
    if blob[:2] == b"VZ" and len(blob) >= 4:
        return int.from_bytes(blob[2:4], "little")
    if blob[:2] == b"MZ" and len(blob) >= 0x40:
        pe = int.from_bytes(blob[0x3C:0x40], "little")
        if blob[pe:pe + 4] == b"PE\0\0" and len(blob) >= pe + 6:
            return int.from_bytes(blob[pe + 4:pe + 6], "little")
    return None


def guess_phase(blob: bytes) -> str:
    """PEI or DXE, when the caller does not say. A TE image is a PEIM — the
    format exists for execute-in-place PEI code — and so, on a PC, is a 32-bit
    PE; a 64-bit one is a DXE driver. An x64 PEIM exists, and is why `--phase`
    is there."""
    if blob[:2] == b"VZ":
        return "pei"
    return "pei" if machine(blob) == 0x14C else "dxe"


def default_store() -> Path:
    return Path.home() / "Library" / "Application Support" / "ByteRipper" / "Analysis"


def prepare_image(module: Path, blob: bytes, work: Path) -> tuple[Path, str]:
    """The image Ghidra imports and the kind the manifest names: a TE image is
    converted to PE first, and the original bytes are still what the hash
    names."""
    if blob[:2] == b"VZ":
        image = work / (module.stem + ".pe")
        image.write_bytes(te_to_pe.convert(blob))
        return image, "TE"
    if blob[:2] != b"MZ":
        raise SystemExit(f"{module}: starts with {blob[:2]!r}, neither MZ nor VZ")
    return module, "PE32"


def uefi_pass(blob: bytes, phase: str, ghidra_home: str | None, types_cache: Path | None) -> dict:
    """What `ApplyUefi.java` needs for this module: its type archive, the GUID
    table and the phase, building the cache once."""
    phase = guess_phase(blob) if phase == "auto" else phase
    cache = uefi_types.ensure(ghidra_home, root=types_cache)
    gdt = cache["gdt_ia32"] if machine(blob) == 0x14C else cache["gdt_x64"]
    return {"gdt": gdt, "guids": cache["guids_tsv"], "phase": phase}


def run_headless(image: Path, label: str, ghidra_home: str | None, uefi: dict | None,
                 project_dir: Path, project_name: str, log: Path,
                 export_to: Path | None = None, keep_project: bool = False) -> None:
    """One analyzeHeadless run: the import and its analysis, the UEFI pass when
    `uefi` names its types, GUID table and phase, and the export when
    `export_to` names a file. With `keep_project` the analyzed program stays
    in the project — step 1 of the shared workbench, which an owner then
    opens (Design/GHIDRA_SHARED_PLAN.md §5.2)."""
    ghidra = ghidra_import.find_ghidra(ghidra_home)
    command = [
        str(ghidra / "support" / "analyzeHeadless"), str(project_dir), project_name,
        "-import", str(image), "-overwrite",
        "-scriptPath", str(Path(__file__).resolve().parent),
    ]
    if not keep_project:
        command.append("-deleteProject")
    if uefi is not None:
        command += ["-postScript", "ApplyUefi.java",
                    str(uefi["gdt"]), str(uefi["guids"]), uefi["phase"]]
    if export_to is not None:
        command += ["-postScript", "ExportCode.java", str(export_to)]
    steps = ", ".join(["analysis"] + (["UEFI names"] if uefi is not None else [])
                      + (["export"] if export_to is not None else []))
    returncode = progress.run(command, f"Ghidra: {label} ({steps})", log=log, timeout=1800)
    # A script that does not compile is skipped with an error in the log,
    # and the run still exits 0: an artifact without the UEFI pass would
    # be stored under the recipe that says it had one.
    text = log.read_text(encoding="utf-8", errors="replace")
    script_error = any("SCRIPT ERROR" in line for line in text.splitlines())
    if returncode != 0 or script_error or (export_to is not None and not export_to.exists()):
        print("\n".join(text.splitlines()[-30:]), file=sys.stderr)
        raise SystemExit(f"Ghidra failed (exit {returncode}); log: {log}")
    for line in text.splitlines():
        if "ApplyUefi:" in line:
            print(line[line.index("ApplyUefi:"):].rstrip().removesuffix("(GhidraScript)").rstrip(), file=sys.stderr)


def analyze(module: Path, ghidra_home: str | None,
            uefi: dict | None) -> tuple[dict, bytes, str]:
    """Runs Ghidra once in a project thrown away afterwards: import, analysis,
    the UEFI pass, the export."""
    work = Path(tempfile.mkdtemp(prefix="ghidra-code-"))
    project_dir = work / "project"
    project_dir.mkdir()
    try:
        image, kind = prepare_image(module, module.read_bytes(), work)
        artifact = work / "code.json"
        run_headless(image, module.name, ghidra_home, uefi, project_dir, "code-artifact",
                     work / "analyze.log", export_to=artifact)
        raw = artifact.read_bytes()
        return json.loads(raw.decode("utf-8")), raw, kind
    finally:
        shutil.rmtree(work, ignore_errors=True)


def recipe_for(artifact: dict, types: str | None, passes: list[str] | None) -> dict:
    """The recipe of an artifact: the exporter and the Ghidra that wrote it,
    and — when the UEFI pass ran — what the program was typed with. A types
    revision past the first (`…-r2`) is in the id too, so a module typed
    again is a recipe beside the old one, not a conflict with it."""
    exporter = artifact.get("script_version", SCRIPT_VERSION)
    ghidra = artifact.get("ghidra")
    name = cas.recipe_id(exporter, ghidra)
    if types is None:
        name = name.replace("-ghidra-", "-plain-ghidra-", 1)
    elif revision := re.search(r"-r(\d+)$", types):
        name = name.replace("-ghidra-", f"-types{revision.group(1)}-ghidra-", 1)
    recipe = {"id": name, "exporter": exporter, "ghidra": ghidra, "script": "ExportCode.java"}
    if types is not None:
        recipe["types"] = types
        recipe["passes"] = passes or ["ApplyUefi.java"]
    return recipe


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Analyze a module once and store the code artifact by its bytes.")
    parser.add_argument("module", type=Path, help="the PE32 or TE image")
    parser.add_argument("--name", help="what to call the module (default: the file name)")
    parser.add_argument("--store", type=cas.store_location, default=default_store())
    parser.add_argument("--ghidra-home", help="the Ghidra installation")
    parser.add_argument("--force", action="store_true",
                        help="analyze even if the artifact exists, and replace it")
    parser.add_argument("--discard-reading", action="store_true",
                        help="with --force, replace even a reviewed reading of the module "
                             "with Ghidra's own names")
    parser.add_argument(
        "--document",
        help="the ByteRipper document the module came from, by the file name the UEFI "
             "panel shows; with --node it binds the code badge to that row")
    parser.add_argument("--node", help="the UEFI node the module came from")
    parser.add_argument("--phase", choices=["auto", "pei", "dxe"], default="auto",
                        help="the module's boot phase, for its entry point's signature "
                             "(default: TE or 32-bit is PEI, 64-bit is DXE)")
    parser.add_argument("--no-uefi", action="store_true",
                        help="Ghidra's names only: no UEFI types, GUIDs or recovered names")
    parser.add_argument("--types-cache", type=Path,
                        help="where uefi_types.py keeps the type archives (default: Application Support)")
    args = parser.parse_args(argv)

    module = args.module.expanduser().resolve()
    if not module.is_file():
        print(f"{module}: no such file", file=sys.stderr)
        return 2
    blob = module.read_bytes()
    digest = hashlib.sha256(blob).hexdigest()
    name = args.name or module.stem
    store = cas.Store(args.store)
    try:
        return run(args, module, blob, digest, name, store)
    except cas.CASError as error:
        print(f"the store refused: {error}", file=sys.stderr)
        return 1


def run(args, module: Path, blob: bytes, digest: str, name: str, store: cas.Store) -> int:
    # A stored analysis from the current exporter and the same UEFI pass
    # answers the question without starting Ghidra. One from an older
    # exporter is left alone and a new recipe is added beside it.
    types = None if args.no_uefi else uefi_types.TYPES
    if not args.force:
        existing = next((manifest for manifest in
                         (store.analysis(digest, recipe) for recipe in store.recipes(digest))
                         if manifest is not None
                         and manifest.get("recipe", {}).get("exporter") == SCRIPT_VERSION
                         and manifest.get("recipe", {}).get("types") == types), None)
        if existing is not None:
            try:
                store.get_object(existing["artifact"]["sha256"])
            except (cas.CASError, KeyError):
                pass  # the object is gone or corrupt: analyze again
            else:
                # The analysis is already there. Naming the document or node
                # is provenance, not a reason to run Ghidra again: merge it
                # into the manifest and answer with that.
                if args.document is not None or args.node is not None:
                    try:
                        raw = store.get_object(existing["artifact"]["sha256"])
                        existing = store.put_analysis(
                            module=existing["module"], recipe=existing["recipe"],
                            artifact=raw,
                            source={"path": str(module), "document": args.document,
                                    "node": args.node})
                    except (cas.CASError, KeyError):
                        pass
                print(json.dumps(existing, indent=2))
                return 0

    uefi = None if args.no_uefi else uefi_pass(blob, args.phase, args.ghidra_home, args.types_cache)
    phase = uefi["phase"] if uefi else None
    artifact, raw, kind = analyze(module, args.ghidra_home, uefi)
    if artifact.get("script_version") != SCRIPT_VERSION:
        print(f"the artifact's script version is {artifact.get('script_version')}, "
              f"expected {SCRIPT_VERSION}", file=sys.stderr)
        return 1

    recipe = recipe_for(artifact, types, ["ApplyUefi.java"] if types else None)
    program = artifact.get("program", {})
    manifest = store.put_analysis(
        module={
            "sha256": digest,
            "size": len(blob),
            "name": name,
            "kind": kind,
            "language": program.get("language"),
            "image_base": program.get("image_base"),
            **({"phase": phase} if phase else {}),
        },
        recipe=recipe,
        artifact=raw,
        source={"path": str(module), "document": args.document, "node": args.node},
        replace=args.force,
        discard_reading=args.force and args.discard_reading,
    )
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
