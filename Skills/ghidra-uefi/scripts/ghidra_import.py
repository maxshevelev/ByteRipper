#!/usr/bin/env python3
"""Analyze one extracted module in Ghidra headless and export its functions.

The running-Ghidra path is the interactive one: open the module in a CodeBrowser
and use the GhydraMCP tools. This script is the batch path, for an agent that
has no Ghidra window open, or for a run whose result has to be a file on disk:

    analyzeHeadless ... -import module.pe -postScript ExportModule.java out.json

It converts a TE image to PE first (`te_to_pe.py`), because Ghidra's PE loader
starts at a DOS header and a TE image has none. The Ghidra project is kept, so
a later question about the same module can be answered with `-process` and no
re-analysis.

Stdlib only; the only external program run is Ghidra's own analyzeHeadless.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import te_to_pe


def find_ghidra(explicit: str | None) -> Path:
    if explicit:
        home = Path(explicit).expanduser()
        if (home / "support" / "analyzeHeadless").exists():
            return home
        raise SystemExit(f"{home}: no support/analyzeHeadless there")
    if os.environ.get("GHIDRA_HOME"):
        home = Path(os.environ["GHIDRA_HOME"]).expanduser()
        if (home / "support" / "analyzeHeadless").exists():
            return home
    candidates = []
    for root in (Path.home() / "Projects" / "ghidra",
                 Path.home() / "ghidra",
                 Path("/Applications"),
                 Path("/opt")):
        if root.exists():
            for entry in sorted(root.glob("ghidra_*")):
                if (entry / "support" / "analyzeHeadless").exists():
                    candidates.append(entry)
    if not candidates:
        raise SystemExit(
            "No Ghidra found. Pass --ghidra-home or set GHIDRA_HOME to the "
            "directory that holds support/analyzeHeadless.")
    # The newest by the version in the directory name when there is a choice.
    def version(path: Path) -> tuple:
        numbers = re.findall(r"\d+", path.name)
        return tuple(int(number) for number in numbers)
    return max(candidates, key=version)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Analyze one UEFI module in Ghidra headless.")
    parser.add_argument("module", type=Path, help="the PE32 or TE image")
    parser.add_argument("--out", type=Path, help="the JSON to write (default beside the module)")
    parser.add_argument("--ghidra-home", help="the Ghidra installation")
    parser.add_argument("--project-dir", type=Path,
                        help="where the Ghidra project goes (default a temp directory)")
    parser.add_argument("--project-name", default="byteripper-uefi")
    parser.add_argument("--analysis-timeout", type=int, default=300,
                        help="seconds Ghidra may spend analyzing (default 300)")
    parser.add_argument("--no-decompile", action="store_true",
                        help="names, signatures and call edges only")
    parser.add_argument("--delete", action="store_true",
                        help="remove the Ghidra project after the export")
    args = parser.parse_args(argv)

    module = args.module.expanduser().resolve()
    if not module.is_file():
        print(f"{module}: no such file", file=sys.stderr)
        return 2
    blob = module.read_bytes()
    ghidra = find_ghidra(args.ghidra_home)
    analyze = ghidra / "support" / "analyzeHeadless"

    out = (args.out or module.with_suffix(".analysis.json")).resolve()
    work = Path(tempfile.mkdtemp(prefix="ghidra-uefi-"))
    project_dir = (args.project_dir or work).expanduser().resolve()
    project_was_created = not project_dir.exists()
    project_dir.mkdir(parents=True, exist_ok=True)

    try:
        if blob[:2] == b"VZ":
            image = work / (module.stem + ".pe")
            image.write_bytes(te_to_pe.convert(blob))
            converted = "TE converted to PE"
        elif blob[:2] == b"MZ":
            image = module
            converted = "PE32"
        else:
            print(f"{module}: starts with {blob[:2]!r}, neither MZ nor VZ",
                  file=sys.stderr)
            return 2

        command = [
            str(analyze), str(project_dir), args.project_name,
            "-import", str(image), "-overwrite",
            "-analysisTimeoutPerFile", str(args.analysis_timeout),
            "-scriptPath", str(Path(__file__).resolve().parent),
            "-postScript", "ExportModule.java", str(out),
        ]
        if args.no_decompile:
            command.append("--no-decompile")
        log = work / "analyze.log"
        with open(log, "w", encoding="utf-8") as handle:
            result = subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT)
        if result.returncode != 0 or not out.exists():
            print(f"Ghidra failed (exit {result.returncode}); log: {log}", file=sys.stderr)
            tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-25:]
            print("\n".join(tail), file=sys.stderr)
            return 1
        print(f"{module} ({converted}) -> {out}")
        print(f"Ghidra project: {project_dir} (program {image.name})")
        summary = re.search(r'"function_count":\s*(\d+)', out.read_text(encoding="utf-8"))
        if summary:
            print(f"functions: {summary.group(1)}")
        return 0
    finally:
        # The project, the converted image and the log all live in `work`
        # unless the caller named a project directory. Kept by default so a
        # follow-up question can use `-process` and skip the analysis.
        if args.delete:
            shutil.rmtree(work, ignore_errors=True)
            if project_dir != work and project_was_created:
                shutil.rmtree(project_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
