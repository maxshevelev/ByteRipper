#!/usr/bin/env python3
"""The local content-addressed store for code artifacts, as the skill sees it.

The store has two kinds of record:

- **objects** — immutable bytes, named by their SHA-256;
- **analyses** — a manifest that says "these module bytes, with this analysis
  recipe, produced that object".

The store itself is implemented once, in Swift (`Packages/CodeAnalysis`,
`ContentStore`), and this module is its client: every call runs the
`byteripper-cas` tool and reads its JSON answer. Which artifact may replace
which — a newer reading of a reviewed module, never a mechanical run over it
(`Design/GHIDRA_SHARED_PLAN.md` §5.6) — is decided there, the same way for the
app and for the skill.

The tool is found as:

1. `$BYTERIPPER_CAS`, a path to a built `byteripper-cas`;
2. otherwise it is built from this repository's `Packages/CodeAnalysis` with
   `swift build -c release`, into `~/Library/Caches/ByteRipper/byteripper-cas`,
   once, and again whenever a source of the package is newer than the build.

Stdlib only; the external program is `byteripper-cas` (and `swift` to build it).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import progress

SCHEMA = 1
PROTOCOL = 1
DIGEST_LENGTH = 64
PACKAGE = Path(__file__).resolve().parents[3] / "Packages" / "CodeAnalysis"


class CASError(Exception):
    """The store cannot do what was asked, or what it holds is not sound."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_digest(text: str) -> bool:
    return len(text) == DIGEST_LENGTH and all(c in "0123456789abcdefABCDEF" for c in text)


def _safe_recipe(text: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-")
    return cleaned or "unknown"


def recipe_id(exporter: int, ghidra: str | None) -> str:
    """The analysis recipe as a path-safe name.

    The exporter version is the one in `ExportCode.java`; the Ghidra version is
    the one that produced the program. A different Ghidra may find different
    functions, so it is part of the key rather than a note under it.
    """
    return f"code-v{exporter}-ghidra-{_safe_recipe(ghidra or 'unknown')}"


# -- the tool -------------------------------------------------------------

def build_root() -> Path:
    return Path.home() / "Library" / "Caches" / "ByteRipper" / "byteripper-cas"


def _newest_source() -> float:
    sources = [PACKAGE / "Package.swift", *(PACKAGE / "Sources").rglob("*.swift")]
    return max(path.stat().st_mtime for path in sources if path.is_file())


_tool: Path | None = None


def tool() -> Path:
    """The `byteripper-cas` to run, built first when it is missing or older
    than the package's sources."""
    global _tool
    if _tool is not None:
        return _tool
    named = os.environ.get("BYTERIPPER_CAS")
    if named:
        _tool = Path(named).expanduser()
        if not _tool.is_file():
            raise CASError(f"BYTERIPPER_CAS names {_tool}, which is not a file")
        return _tool
    if not (PACKAGE / "Package.swift").is_file():
        raise CASError(f"{PACKAGE} is missing: set BYTERIPPER_CAS to a built byteripper-cas")
    scratch = build_root()
    binary = scratch / "release" / "byteripper-cas"
    if not binary.is_file() or binary.stat().st_mtime < _newest_source():
        scratch.mkdir(parents=True, exist_ok=True)
        log = scratch / "build.log"
        command = ["swift", "build", "-c", "release", "--product", "byteripper-cas",
                   "--package-path", str(PACKAGE), "--scratch-path", str(scratch)]
        try:
            status = progress.run(command, "Building byteripper-cas, the store's tool (once)",
                                  log=log, timeout=900)
        except FileNotFoundError as error:
            raise CASError("swift is not installed: install Xcode or its command line "
                           "tools, or set BYTERIPPER_CAS") from error
        if status != 0 or not binary.is_file():
            tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-20:]
            raise CASError("building byteripper-cas failed:\n" + "\n".join(tail))
        # A build that changed nothing leaves the old time; the sources are
        # what it was checked against.
        os.utime(binary)
    _tool = binary
    return _tool


# -- the store ------------------------------------------------------------

class Store:
    """The store rooted at a directory, through `byteripper-cas`."""

    def __init__(self, root: Path, create: bool = True):
        self.root = Path(root).expanduser()
        self.create = create

    def _call(self, *arguments: str, raw: bool = False):
        command = [str(tool()), "--store", str(self.root)]
        if not self.create:
            command.append("--no-create")
        completed = subprocess.run([*command, *arguments], capture_output=True)
        if completed.returncode != 0:
            try:
                message = json.loads(completed.stderr)["error"]
            except (ValueError, KeyError, TypeError):
                message = completed.stderr.decode("utf-8", errors="replace").strip()
            raise CASError(message or f"byteripper-cas exited {completed.returncode}")
        return completed.stdout if raw else json.loads(completed.stdout)

    @staticmethod
    def _file(data: bytes) -> str:
        handle = tempfile.NamedTemporaryFile(prefix="cas-", delete=False)
        with handle:
            handle.write(data)
        return handle.name

    def hello(self) -> dict:
        return self._call("hello")

    # -- objects --------------------------------------------------------

    def has_object(self, digest: str) -> bool:
        return self._call("has-object", digest)["present"]

    def put_object(self, data: bytes, media_type: str = "application/octet-stream") -> str:
        path = self._file(data)
        try:
            return self._call("put-object", path)["sha256"]
        finally:
            os.unlink(path)

    def get_object(self, digest: str) -> bytes:
        return self._call("get-object", digest, raw=True)

    # -- analyses -------------------------------------------------------

    def put_analysis(
        self,
        module: dict,
        recipe: dict,
        artifact: bytes,
        source: dict | None = None,
        replace: bool = False,
        reading: dict | None = None,
        discard_reading: bool = False,
    ) -> dict:
        """Store an artifact and the manifest that names it.

        `module` is `{sha256, size, name, kind, language, image_base, phase}`;
        `recipe` is `{id, exporter, ghidra, script, types, passes}`; `reading`
        is `{project, rev, review}` for an artifact of a reviewed program. An
        analysis that already exists with the same artifact is returned as it
        is, with the source merged in. Another artifact replaces it when its
        reading is newer; `replace` lets a mechanical artifact replace a
        mechanical one, and `discard_reading` lets it replace a reading.
        """
        path = self._file(artifact)
        arguments = ["put-analysis", "--module", json.dumps(module),
                     "--recipe", json.dumps(recipe), "--artifact", path]
        if source:
            arguments += ["--source", json.dumps(source)]
        if reading:
            arguments += ["--reading", json.dumps(reading)]
        if replace:
            arguments.append("--replace")
        if discard_reading:
            arguments.append("--discard-reading")
        try:
            return self._call(*arguments)
        finally:
            os.unlink(path)

    def analysis(self, module_sha: str, recipe: str | None = None) -> dict | None:
        """The manifest for a module, the newest one when no recipe is named."""
        return self._call("analysis", module_sha, *(["--recipe", recipe] if recipe else []))

    def recipes(self, module_sha: str) -> list[str]:
        return self._call("recipes", module_sha)

    def analyses(self) -> list[dict]:
        """Every manifest, module by module, recipe by recipe."""
        return self._call("list")

    def conflicts(self) -> list[dict]:
        """The readings a bundle import kept aside for a person to choose."""
        return self._call("conflicts")

    def record_revision(self, module_sha: str, reading: dict, by: str | None = None) -> dict:
        """A revision of a reading into the module's history; its document
        must be stored already. A publish stores the document, then this, then
        the analysis (`Design/GHIDRA_SHARED_PLAN.md` §5.4)."""
        arguments = ["record-revision", module_sha, "--reading", json.dumps(reading)]
        if by:
            arguments += ["--by", by]
        return self._call(*arguments)

    def review_history(self, module_sha: str) -> dict | None:
        """Every revision of every reading of a module, oldest first."""
        return self._call("review-history", module_sha)

    def key(self, manifest: dict) -> str:
        return f"{manifest['module']['sha256']}/{manifest['recipe']['id']}"

    def find_analysis(self, key: str) -> dict | None:
        module, _, recipe = key.partition("/")
        if not recipe:
            raise CASError(f"{key!r} is not <module-sha>/<recipe>")
        return self.analysis(module, recipe)

    # -- references -----------------------------------------------------

    def set_ref(self, name: str, keys: list[str]) -> dict:
        return self._call("set-ref", name, *keys)

    def refs(self) -> list[dict]:
        return self._call("refs")

    def referenced_keys(self) -> set[str]:
        keys: set[str] = set()
        for record in self.refs():
            keys.update(record.get("analyses", []))
        return keys

    def remove_ref(self, name: str) -> bool:
        return self._call("remove-ref", name)["removed"]

    # -- integrity and collection --------------------------------------

    def verify(self) -> list[str]:
        return self._call("verify")["problems"]

    def gc(self, dry_run: bool = True, delete_unreferenced_analyses: bool = False) -> dict:
        """Remove what nothing reaches.

        Without `delete_unreferenced_analyses`, every analysis is kept and only
        objects no manifest names are removed. With it, analyses not named by a
        reference are removed too. A dry run reports without deleting.
        """
        return self._call("gc", *([] if dry_run else ["--apply"]),
                          *(["--analyses"] if delete_unreferenced_analyses else []))

    # -- moving analyses between stores ---------------------------------

    def export_bundle(self, keys: list[str], out: Path) -> dict:
        """Write chosen analyses and their objects as a zip a store can import."""
        out = Path(out).expanduser()
        out.parent.mkdir(parents=True, exist_ok=True)
        return self._call("export", "--out", str(out), *keys)

    def import_bundle(self, path: Path) -> dict:
        """`{imported, unchanged, skipped, conflicts}`: each analysis the
        bundle carried, by what the store did with it."""
        return self._call("import", str(Path(path).expanduser()))
