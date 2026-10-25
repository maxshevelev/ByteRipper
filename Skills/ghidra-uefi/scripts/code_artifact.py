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

Stdlib only; the external program is Ghidra's analyzeHeadless.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cas
import ghidra_import
import te_to_pe

SCRIPT_VERSION = 2


def default_store() -> Path:
    return Path.home() / "Library" / "Application Support" / "ByteRipper" / "Analysis"


def analyze(module: Path, ghidra_home: str | None) -> tuple[dict, bytes, str]:
    ghidra = ghidra_import.find_ghidra(ghidra_home)
    analyze_headless = ghidra / "support" / "analyzeHeadless"
    work = Path(tempfile.mkdtemp(prefix="ghidra-code-"))
    project_dir = work / "project"
    project_dir.mkdir()
    try:
        blob = module.read_bytes()
        image = module
        kind = "PE32"
        if blob[:2] == b"VZ":
            image = work / (module.stem + ".pe")
            image.write_bytes(te_to_pe.convert(blob))
            kind = "TE"
        elif blob[:2] != b"MZ":
            raise SystemExit(f"{module}: starts with {blob[:2]!r}, neither MZ nor VZ")

        artifact = work / "code.json"
        log = work / "analyze.log"
        command = [
            str(analyze_headless), str(project_dir), "code-artifact",
            "-import", str(image), "-overwrite", "-deleteProject",
            "-scriptPath", str(Path(__file__).resolve().parent),
            "-postScript", "ExportCode.java", str(artifact),
        ]
        with open(log, "w", encoding="utf-8") as handle:
            result = subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT)
        if result.returncode != 0 or not artifact.exists():
            tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-30:]
            print("\n".join(tail), file=sys.stderr)
            raise SystemExit(f"Ghidra failed (exit {result.returncode}); log: {log}")
        raw = artifact.read_bytes()
        return json.loads(raw.decode("utf-8")), raw, kind
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Analyze a module once and store the code artifact by its bytes.")
    parser.add_argument("module", type=Path, help="the PE32 or TE image")
    parser.add_argument("--name", help="what to call the module (default: the file name)")
    parser.add_argument("--store", type=Path, default=default_store())
    parser.add_argument("--ghidra-home", help="the Ghidra installation")
    parser.add_argument("--force", action="store_true", help="analyze even if the artifact exists")
    parser.add_argument("--document", help="the ByteRipper document the module came from")
    parser.add_argument("--node", help="the UEFI node the module came from")
    args = parser.parse_args(argv)

    module = args.module.expanduser().resolve()
    if not module.is_file():
        print(f"{module}: no such file", file=sys.stderr)
        return 2
    blob = module.read_bytes()
    digest = hashlib.sha256(blob).hexdigest()
    name = args.name or module.stem
    store = cas.Store(args.store)
    # A stored analysis from the current exporter answers the question without
    # starting Ghidra. One from an older exporter is left alone and a new
    # recipe is added beside it.
    if not args.force:
        existing = store.analysis(digest)
        if existing is not None and existing.get("recipe", {}).get("exporter") == SCRIPT_VERSION:
            try:
                store.get_object(existing["artifact"]["sha256"])
            except (cas.CASError, KeyError):
                pass  # the object is gone or corrupt: analyze again
            else:
                print(json.dumps(existing, indent=2))
                return 0

    artifact, raw, kind = analyze(module, args.ghidra_home)
    if artifact.get("script_version") != SCRIPT_VERSION:
        print(f"the artifact's script version is {artifact.get('script_version')}, "
              f"expected {SCRIPT_VERSION}", file=sys.stderr)
        return 1

    exporter = artifact.get("script_version", SCRIPT_VERSION)
    ghidra = artifact.get("ghidra")
    recipe = {
        "id": cas.recipe_id(exporter, ghidra),
        "exporter": exporter,
        "ghidra": ghidra,
        "script": "ExportCode.java",
    }
    program = artifact.get("program", {})
    manifest = store.put_analysis(
        module={
            "sha256": digest,
            "size": len(blob),
            "name": name,
            "kind": kind,
            "language": program.get("language"),
            "image_base": program.get("image_base"),
        },
        recipe=recipe,
        artifact=raw,
        source={"path": str(module), "document": args.document, "node": args.node},
        replace=args.force,
    )
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
