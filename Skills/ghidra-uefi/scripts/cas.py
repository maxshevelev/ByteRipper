#!/usr/bin/env python3
"""A local content-addressed store for code artifacts.

The store has two kinds of record:

- **objects** — immutable bytes, named by their SHA-256;
- **analyses** — a manifest that says "these module bytes, with this analysis
  recipe, produced that object".

Everything else is derived. A module's bytes are the key: `put_analysis`
stores the artifact once and writes a manifest under
`analyses/<module-sha>/<recipe>/manifest.json`. The same module analyzed with
another exporter or Ghidra version is a second recipe and does not overwrite
the first.

References (`refs/<name>.json`) name the analyses a project or a person wants
to keep; garbage collection deletes objects and analyses that no reference
reaches. Nothing here is a database: the directory is the index, and
`analyses()` walks it.

The layout is deliberately plain, so that a future Swift reader — the Code
panel — can read it without this module, and a person can inspect it with
`find`. Writes are atomic (a temporary file and a rename), artifacts are
verified when read, and the store directory is `0700`.

Stdlib only.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import tempfile
import zipfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = 1
DIGEST_LENGTH = 64


class CASError(Exception):
    """The store cannot do what was asked, or what it holds is not sound."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_digest(text: str) -> bool:
    return len(text) == DIGEST_LENGTH and all(c in "0123456789abcdefABCDEF" for c in text)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


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


def _atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    except BaseException:
        try:
            os.unlink(name)
        except OSError:
            pass
        raise


class Store:
    """A local store rooted at a directory."""

    def __init__(self, root: Path, create: bool = True):
        self.root = Path(root).expanduser()
        self.objects = self.root / "objects"
        self.analyses_dir = self.root / "analyses"
        self.refs_dir = self.root / "refs"
        self.tmp = self.root / "tmp"
        if create:
            for folder in (self.objects, self.analyses_dir, self.refs_dir, self.tmp):
                folder.mkdir(parents=True, exist_ok=True)
            os.chmod(self.root, 0o700)
            os.chmod(self.objects, 0o700)
            os.chmod(self.analyses_dir, 0o700)
            os.chmod(self.refs_dir, 0o700)

    # -- locking --------------------------------------------------------

    @contextmanager
    def _locked(self):
        """Serialize the writes that can race: a manifest and a GC."""
        self.root.mkdir(parents=True, exist_ok=True)
        with open(self.root / ".lock", "a+") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    # -- objects --------------------------------------------------------

    def object_path(self, digest: str) -> Path:
        if not is_digest(digest):
            raise CASError(f"{digest!r} is not a SHA-256")
        return self.objects / digest.lower()

    def has_object(self, digest: str) -> bool:
        return self.object_path(digest).is_file()

    def put_object(self, data: bytes, media_type: str = "application/octet-stream") -> str:
        digest = sha256_bytes(data)
        path = self.object_path(digest)
        if path.is_file():
            # The name is the content; an existing object is the object.
            return digest
        _atomic_write(path, data)
        return digest

    def get_object(self, digest: str) -> bytes:
        path = self.object_path(digest)
        try:
            data = path.read_bytes()
        except OSError as error:
            raise CASError(f"object {digest} is missing: {error}") from error
        actual = sha256_bytes(data)
        if actual != digest.lower():
            raise CASError(f"object {digest} is corrupt: its bytes hash to {actual}")
        return data

    # -- analyses -------------------------------------------------------

    def _module_dir(self, module_sha: str) -> Path:
        if not is_digest(module_sha):
            raise CASError(f"{module_sha!r} is not a module SHA-256")
        return self.analyses_dir / module_sha.lower()

    def manifest_path(self, module_sha: str, recipe: str) -> Path:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", recipe) or recipe in (".", ".."):
            raise CASError(f"{recipe!r} is not a recipe name")
        return self._module_dir(module_sha) / recipe / "manifest.json"

    def put_analysis(
        self,
        module: dict,
        recipe: dict,
        artifact: bytes,
        source: dict | None = None,
        replace: bool = False,
    ) -> dict:
        """Store an artifact and the manifest that names it.

        `module` is `{sha256, size, name, kind, language, image_base}`;
        `recipe` is `{id, exporter, ghidra, script}`. The artifact's own hash is
        the object key. An analysis that already exists with the same artifact
        is returned as it is; one with a different artifact is refused unless
        `replace`, because two runs of the same recipe should agree.
        """
        module_sha = module.get("sha256", "")
        recipe_name = recipe.get("id", "")
        if not is_digest(module_sha):
            raise CASError("module.sha256 is not a SHA-256")
        if not recipe_name:
            raise CASError("recipe.id is empty")
        artifact_digest = self.put_object(artifact, "application/json")
        manifest = {
            "schema": SCHEMA,
            "module": module,
            "recipe": recipe,
            "artifact": {
                "sha256": artifact_digest,
                "size": len(artifact),
                "media_type": "application/json",
            },
            "source": source or {},
            "analyzed_at": _now(),
            "stats": _artifact_stats(artifact),
        }
        path = self.manifest_path(module_sha, recipe_name)
        with self._locked():
            if path.is_file():
                existing = json.loads(path.read_text(encoding="utf-8"))
                same = existing.get("artifact", {}).get("sha256") == artifact_digest
                if same:
                    # The artifact is the same analysis; a re-run may still
                    # know where it came from. Merge only what the caller
                    # names, so a later run without a node does not erase the
                    # binding an earlier one wrote.
                    merged = dict(existing.get("source") or {})
                    rebound = False
                    for key, value in (source or {}).items():
                        if value is not None and merged.get(key) != value:
                            merged[key] = value
                            rebound = True
                    if rebound:
                        existing["source"] = merged
                        _atomic_write(
                            path,
                            (json.dumps(existing, indent=2, ensure_ascii=False) + "\n").encode("utf-8"),
                        )
                    return existing
                if not replace:
                    raise CASError(
                        f"{module_sha}/{recipe_name} already exists with another artifact "
                        f"({existing.get('artifact', {}).get('sha256')}); pass replace=True")
            _atomic_write(path, (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
        return manifest

    def analysis(self, module_sha: str, recipe: str | None = None) -> dict | None:
        """The manifest for a module, the newest one when no recipe is named."""
        folder = self._module_dir(module_sha)
        if not folder.is_dir():
            return None
        if recipe:
            path = folder / recipe / "manifest.json"
            return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None
        manifests = []
        for path in folder.glob("*/manifest.json"):
            try:
                manifests.append(json.loads(path.read_text(encoding="utf-8")))
            except (OSError, json.JSONDecodeError):
                continue
        if not manifests:
            return None
        manifests.sort(key=lambda m: m.get("analyzed_at", ""), reverse=True)
        return manifests[0]

    def recipes(self, module_sha: str) -> list[str]:
        folder = self._module_dir(module_sha)
        if not folder.is_dir():
            return []
        return sorted(path.name for path in folder.iterdir() if (path / "manifest.json").is_file())

    def analyses(self):
        """Every manifest, module by module, recipe by recipe."""
        if not self.analyses_dir.is_dir():
            return
        for module_folder in sorted(self.analyses_dir.iterdir()):
            if not module_folder.is_dir():
                continue
            for recipe_folder in sorted(module_folder.iterdir()):
                path = recipe_folder / "manifest.json"
                if not path.is_file():
                    continue
                try:
                    yield json.loads(path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    continue

    def key(self, manifest: dict) -> str:
        return f"{manifest['module']['sha256']}/{manifest['recipe']['id']}"

    def find_analysis(self, key: str) -> dict | None:
        module, _, recipe = key.partition("/")
        if not recipe:
            raise CASError(f"{key!r} is not <module-sha>/<recipe>")
        return self.analysis(module, recipe)

    # -- references -----------------------------------------------------

    def _ref_path(self, name: str) -> Path:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
            raise CASError(f"{name!r} is not a reference name")
        return self.refs_dir / f"{name}.json"

    def set_ref(self, name: str, keys: list[str]) -> dict:
        for key in keys:
            if self.find_analysis(key) is None:
                raise CASError(f"no analysis for {key}")
        record = {"name": name, "analyses": sorted(set(keys)), "updated_at": _now()}
        with self._locked():
            _atomic_write(self._ref_path(name),
                          (json.dumps(record, indent=2) + "\n").encode("utf-8"))
        return record

    def refs(self) -> list[dict]:
        if not self.refs_dir.is_dir():
            return []
        records = []
        for path in sorted(self.refs_dir.glob("*.json")):
            try:
                records.append(json.loads(path.read_text(encoding="utf-8")))
            except (OSError, json.JSONDecodeError):
                continue
        return records

    def referenced_keys(self) -> set[str]:
        keys: set[str] = set()
        for record in self.refs():
            keys.update(record.get("analyses", []))
        return keys

    def remove_ref(self, name: str) -> bool:
        path = self._ref_path(name)
        with self._locked():
            if not path.is_file():
                return False
            path.unlink()
            return True

    # -- integrity and collection --------------------------------------

    def verify(self) -> list[str]:
        problems: list[str] = []
        for path in sorted(self.objects.glob("*")):
            if not path.is_file():
                continue
            digest = path.name
            if not is_digest(digest):
                problems.append(f"objects/{digest}: not a SHA-256 name")
                continue
            actual = sha256_bytes(path.read_bytes())
            if actual != digest.lower():
                problems.append(f"objects/{digest}: bytes hash to {actual}")
        for manifest in self.analyses():
            key = self.key(manifest)
            path = self.manifest_path(manifest["module"]["sha256"], manifest["recipe"]["id"])
            if not path.is_file():
                problems.append(f"{key}: manifest path does not exist")
            artifact = manifest.get("artifact", {}).get("sha256", "")
            if not self.has_object(artifact):
                problems.append(f"{key}: artifact {artifact} is missing")
            if not is_digest(manifest.get("module", {}).get("sha256", "")):
                problems.append(f"{key}: module hash is not a SHA-256")
        for record in self.refs():
            for key in record.get("analyses", []):
                if self.find_analysis(key) is None:
                    problems.append(f"refs/{record.get('name')}: no analysis for {key}")
        return problems

    def gc(self, dry_run: bool = True, delete_unreferenced_analyses: bool = False) -> dict:
        """Remove what nothing reaches.

        Without `delete_unreferenced_analyses`, every analysis is kept and only
        objects no manifest names are removed. With it, analyses not named by a
        reference are removed too. A dry run reports without deleting.
        """
        referenced = self.referenced_keys()
        all_manifests = list(self.analyses())
        keep_manifests: list[dict] = []
        drop_manifests: list[dict] = []
        for manifest in all_manifests:
            keep = not delete_unreferenced_analyses or self.key(manifest) in referenced
            (keep_manifests if keep else drop_manifests).append(manifest)
        keep_objects = {m.get("artifact", {}).get("sha256")
                        for m in keep_manifests
                        if m.get("artifact", {}).get("sha256")}
        orphan_objects = [p.name for p in self.objects.glob("*")
                          if p.is_file() and p.name not in keep_objects]
        report = {
            "objects": len(orphan_objects),
            "analyses": len(drop_manifests),
            "kept_analyses": len(keep_manifests),
            "kept_objects": len(keep_objects),
            "dry_run": dry_run,
        }
        if dry_run:
            return report
        with self._locked():
            for manifest in drop_manifests:
                folder = self.manifest_path(manifest["module"]["sha256"],
                                            manifest["recipe"]["id"]).parent
                shutil.rmtree(folder, ignore_errors=True)
            for digest in orphan_objects:
                try:
                    self.object_path(digest).unlink()
                except OSError:
                    pass
            for folder in self.analyses_dir.glob("*"):
                if folder.is_dir() and not any(folder.iterdir()):
                    folder.rmdir()
            for path in self.tmp.glob("*"):
                if path.is_dir():
                    shutil.rmtree(path, ignore_errors=True)
                else:
                    try:
                        path.unlink()
                    except OSError:
                        pass
        return report

    # -- moving analyses between stores ---------------------------------

    def export_bundle(self, keys: list[str], out: Path) -> dict:
        """Write chosen analyses and their objects as a zip a store can import."""
        manifests = []
        for key in keys:
            manifest = self.find_analysis(key)
            if manifest is None:
                raise CASError(f"no analysis for {key}")
            manifests.append(manifest)
        out = Path(out).expanduser()
        out.parent.mkdir(parents=True, exist_ok=True)
        bundle = {"schema": SCHEMA, "created_at": _now(),
                  "analyses": [self.key(m) for m in manifests]}
        # Stored, not deflated: a bundle is a carrier, not a format to
        # compress. The Swift store in Packages/CodeAnalysis reads stored
        # entries only, without linking a decompressor.
        with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as archive:
            archive.writestr("bundle.json", json.dumps(bundle, indent=2) + "\n")
            for manifest in manifests:
                key = self.key(manifest)
                archive.writestr(f"analyses/{key}/manifest.json",
                                 json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
                digest = manifest["artifact"]["sha256"]
                archive.writestr(f"objects/{digest}", self.get_object(digest))
        return bundle

    def import_bundle(self, path: Path) -> list[dict]:
        imported: list[dict] = []
        with zipfile.ZipFile(Path(path).expanduser()) as archive:
            bundle = json.loads(archive.read("bundle.json"))
            if bundle.get("schema") != SCHEMA:
                raise CASError(f"bundle schema {bundle.get('schema')} is not {SCHEMA}")
            for key in bundle.get("analyses", []):
                module, _, recipe = key.partition("/")
                manifest = json.loads(archive.read(f"analyses/{key}/manifest.json"))
                if manifest.get("schema") != SCHEMA:
                    raise CASError(f"{key}: manifest schema is not {SCHEMA}")
                digest = manifest["artifact"]["sha256"]
                artifact = archive.read(f"objects/{digest}")
                if sha256_bytes(artifact) != digest:
                    raise CASError(f"{key}: artifact does not match its hash")
                self.put_object(artifact, "application/json")
                target = self.manifest_path(module, recipe)
                if target.is_file():
                    existing = json.loads(target.read_text(encoding="utf-8"))
                    if existing.get("artifact", {}).get("sha256") != digest:
                        raise CASError(f"{key}: already present with another artifact")
                    imported.append(existing)
                    continue
                _atomic_write(target, (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
                imported.append(manifest)
        return imported


def _artifact_stats(artifact: bytes) -> dict:
    try:
        document = json.loads(artifact)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return {}
    functions = document.get("functions", [])
    return {
        "functions": len(functions),
        "instructions": sum(len(f.get("instructions", [])) for f in functions),
        "strings": len(document.get("strings", [])),
        "post_code_writes": len(document.get("post_codes", [])),
        "status_code_candidates": len(document.get("status_code_calls", [])),
    }
