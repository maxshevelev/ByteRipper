#!/usr/bin/env python3
"""A kept Ghidra project per module, and the long-lived owner that serves it.

Phases 1 and 2 of `Design/GHIDRA_SHARED_PLAN.md`: one owner, the reads, the
review's writes, and publish.

    python3 ghidra_owner.py open CpuPei.te --name CpuPei --document "CSME 15.bin" --node 0.5.5.2
    python3 ghidra_owner.py status
    python3 ghidra_owner.py get <module-sha> /v1/function/0x355
    python3 ghidra_owner.py rename <module-sha> 0x68A FindMicrocodePatch --reason "walks the FIT"
    python3 ghidra_owner.py rename-var <module-sha> 0x68A Patch --storage EAX:4 --first-use 0x6E5
    python3 ghidra_owner.py comment <module-sha> 0x6E5 "the patch's header"
    python3 ghidra_owner.py signature <module-sha> 0x68A "UINT32 *FindMicrocodePatch(UINT32 Signature)"
    python3 ghidra_owner.py data <module-sha> 0x1F2C0 --name gPatchTable --type "UINT32[4]"
    python3 ghidra_owner.py type <module-sha> "typedef struct { UINT32 Id; UINT32 Size; } PATCH;"
    python3 ghidra_owner.py publish <module-sha>
    python3 ghidra_owner.py release <module-sha>
    python3 ghidra_owner.py stop <module-sha>

A write takes the module's write lease the first time and keeps its token in
`lease.json` beside the project, so a run of commands shares one lease;
`release` publishes and gives it back.

`open` makes the module's project the first time — Ghidra's analysis and the
UEFI pass in one `analyzeHeadless` run that keeps the project (step 1, §5.2) —
then starts an owner on a free loopback port and waits until it serves. An
owner already running is reused. `publish` asks the owner for the artifact of
the program as it stands and stores it in the CAS the app reads; the owner
itself writes nothing there (§5.4).

The project lives in `~/Library/Application Support/ByteRipper/GhidraProjects/
<module-sha>/` (`--projects` moves it): the Ghidra project `module.gpr` and
`module.rep`, `state.json` — what made the project and what was last
published — and, while an owner runs, `owner.json` with its port and process.

The owner is `owner/Owner.java`, compiled with `javac` against the Ghidra
install's jars together with `ExportCode.java`, into
`~/Library/Caches/ByteRipper/ghidra-owner/<ghidra>/`, again whenever a source
is newer than the build.

Stdlib only; the external programs are Ghidra's analyzeHeadless, javac and java.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cas
import code_artifact
import ghidra_import
import progress
import uefi_types

SCHEMA = 1
PROJECT_NAME = "module"
OWNER_SOURCES = [Path(__file__).resolve().parents[1] / "owner" / "Owner.java",
                 Path(__file__).resolve().parents[1] / "owner" / "Harvest.java",
                 Path(__file__).resolve().parent / "ExportCode.java"]


class OwnerError(Exception):
    """The owner cannot be started or reached, or refused a call."""


def projects_root() -> Path:
    return Path.home() / "Library" / "Application Support" / "ByteRipper" / "GhidraProjects"


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# -- Ghidra, Java and the build ---------------------------------------------

def ghidra_version(ghidra: Path) -> str:
    for line in (ghidra / "Ghidra" / "application.properties").read_text().splitlines():
        if line.startswith("application.version="):
            return line.split("=", 1)[1].strip()
    return "unknown"


def java_home() -> Path:
    """A JDK 21 or newer, which Ghidra 12 needs."""
    if os.environ.get("JAVA_HOME"):
        return Path(os.environ["JAVA_HOME"])
    try:
        found = subprocess.run(["/usr/libexec/java_home", "-v", "21+"],
                               capture_output=True, text=True, check=True).stdout.strip()
        return Path(found)
    except (OSError, subprocess.CalledProcessError) as error:
        raise OwnerError("no JDK 21 or newer: install one, or set JAVA_HOME") from error


def classpath(ghidra: Path) -> list[str]:
    return sorted(str(path) for path in (ghidra / "Ghidra").rglob("lib/*.jar"))


def build_owner(ghidra: Path) -> Path:
    """The compiled owner for this Ghidra, built again when a source is newer."""
    out = Path.home() / "Library" / "Caches" / "ByteRipper" / "ghidra-owner" / ghidra.name
    jar = out / "owner.jar"
    newest = max(path.stat().st_mtime for path in OWNER_SOURCES)
    if jar.is_file() and jar.stat().st_mtime >= newest:
        return jar
    classes = out / "classes"
    shutil.rmtree(classes, ignore_errors=True)
    classes.mkdir(parents=True)
    jdk = java_home()
    log = out / "build.log"
    compile_ = [str(jdk / "bin" / "javac"), "-proc:none", "-nowarn", "-encoding", "UTF-8",
                "-d", str(classes), "-cp", os.pathsep.join(classpath(ghidra)),
                *map(str, OWNER_SOURCES)]
    if progress.run(compile_, f"Compiling the Ghidra owner for {ghidra.name}", log=log, timeout=600) != 0:
        raise OwnerError("javac failed:\n" + log.read_text(errors="replace")[-3000:])
    archive = [str(jdk / "bin" / "jar"), "cf", str(jar), "-C", str(classes), "."]
    if subprocess.run(archive).returncode != 0:
        raise OwnerError("jar failed")
    return jar


# -- the project -----------------------------------------------------------

class Project:
    """One module's kept Ghidra project and its bookkeeping."""

    def __init__(self, root: Path, module_sha: str):
        if not cas.is_digest(module_sha):
            raise OwnerError(f"{module_sha!r} is not a module SHA-256")
        self.sha = module_sha.lower()
        self.dir = root / self.sha
        self.state_path = self.dir / "state.json"
        self.owner_path = self.dir / "owner.json"
        self.lease_path = self.dir / "lease.json"

    @property
    def exists(self) -> bool:
        return self.state_path.is_file() and (self.dir / f"{PROJECT_NAME}.gpr").is_file()

    def state(self) -> dict:
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def write_state(self, state: dict) -> None:
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        temporary.replace(self.state_path)

    def create(self, module: Path, blob: bytes, name: str, source: dict, phase: str,
               uefi: bool, ghidra_home: str | None, types_cache: Path | None) -> dict:
        """Step 1: import, analysis and the UEFI pass, kept in the project."""
        if "." in [part[:1] for part in self.dir.parts]:
            raise OwnerError(f"{self.dir}: Ghidra refuses a project path with an element starting with '.'")
        ghidra = ghidra_import.find_ghidra(ghidra_home)
        pass_ = code_artifact.uefi_pass(blob, phase, ghidra_home, types_cache) if uefi else None
        self.dir.mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix="ghidra-owner-"))
        try:
            image, kind = code_artifact.prepare_image(module, blob, work)
            code_artifact.run_headless(image, name, ghidra_home, pass_, self.dir, PROJECT_NAME,
                                       self.dir / "analyze.log", keep_project=True)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        state = {
            "schema": SCHEMA,
            "project": str(uuid.uuid4()),
            "module": {"sha256": self.sha, "size": len(blob), "name": name, "kind": kind,
                       **({"phase": pass_["phase"]} if pass_ else {})},
            "program": image.name,
            "made_with": {"ghidra": ghidra_version(ghidra),
                          "types": uefi_types.TYPES if pass_ else None,
                          "passes": ["ApplyUefi.java"] if pass_ else []},
            "source": source,
            "archive": str(pass_["gdt"]) if pass_ else None,
            "created_at": now(),
            "reviewed": False,
            "published": None,
        }
        self.write_state(state)
        return state

    # -- the owner ----------------------------------------------------------

    def owner(self) -> dict | None:
        """The running owner, or None: a recorded one whose process is gone,
        or that does not answer, is not running."""
        if not self.owner_path.is_file():
            return None
        record = json.loads(self.owner_path.read_text(encoding="utf-8"))
        try:
            os.kill(record["pid"], 0)
        except (OSError, KeyError):
            self.owner_path.unlink(missing_ok=True)
            return None
        try:
            call(record["port"], "GET", "/v1/hello", timeout=5)
        except OwnerError:
            return None
        return record

    def start(self, ghidra_home: str | None, idle: int, wait: float = 300) -> dict:
        running = self.owner()
        if running:
            return running
        ghidra = ghidra_import.find_ghidra(ghidra_home)
        jar = build_owner(ghidra)
        state = self.state()
        log = self.dir / "owner.log"
        command = [str(java_home() / "bin" / "java"), "-Xmx4G", "-Djava.awt.headless=true",
                   "-cp", os.pathsep.join([*classpath(ghidra), str(jar)]), "Owner",
                   "--project-dir", str(self.dir), "--project-name", PROJECT_NAME,
                   "--program", state["program"], "--module", self.sha,
                   "--project-id", state["project"],
                   *(["--types", state["archive"]] if state.get("archive") else []),
                   "--review-types", str(self.dir.parent),
                   "--port", "0", "--idle", str(idle)]
        handle = open(log, "w", encoding="utf-8")
        process = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        with progress.Step(f"Starting the Ghidra owner of {state['module']['name']}") as step:
            started = time.time()
            while True:
                text = log.read_text(encoding="utf-8", errors="replace")
                ready = [line for line in text.splitlines() if line.startswith("OWNER READY ")]
                if ready:
                    port = int(ready[-1].split()[-1])
                    break
                if process.poll() is not None:
                    raise OwnerError("the owner exited before serving:\n" + "\n".join(text.splitlines()[-20:]))
                if time.time() - started > wait:
                    process.kill()
                    raise OwnerError(f"the owner did not serve within {int(wait)} s; log: {log}")
                step.tick()
                time.sleep(0.2)
        record = {"pid": process.pid, "port": port, "started_at": now()}
        self.owner_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        return record

    def stop(self) -> bool:
        record = self.owner()
        if not record:
            return False
        try:
            call(record["port"], "POST", "/v1/stop", timeout=30)
        except OwnerError:
            os.kill(record["pid"], signal.SIGTERM)
        for _ in range(100):
            try:
                os.kill(record["pid"], 0)
            except OSError:
                break
            time.sleep(0.1)
        self.owner_path.unlink(missing_ok=True)
        return True


def call(port: int, method: str, path: str, timeout: float = 600,
         body: dict | None = None, lease: str | None = None, headers: dict | None = None) -> bytes:
    """One call of the bridge. `headers`, when given, receives the answer's."""
    data = json.dumps(body).encode("utf-8") if body is not None else (b"" if method == "POST" else None)
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method, data=data)
    if lease:
        request.add_header("X-Lease", lease)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if headers is not None:
                headers.update({key.lower(): value for key, value in response.headers.items()})
            return response.read()
    except urllib.error.HTTPError as error:
        try:
            message = json.loads(error.read())["error"]
        except (ValueError, KeyError):
            message = str(error)
        raise OwnerError(message) from error
    except (urllib.error.URLError, OSError) as error:
        raise OwnerError(f"the owner on port {port} does not answer: {error}") from error


# -- the lease and the writes -----------------------------------------------

def lease(project: Project, record: dict) -> str:
    """The write lease's token: the one this machine's commands already hold,
    or a new one. A lease someone else holds is refused with its holder."""
    if project.lease_path.is_file():
        token = json.loads(project.lease_path.read_text(encoding="utf-8")).get("token")
        hello = json.loads(call(record["port"], "GET", "/v1/hello"))
        if token and hello.get("lease_holder") == lease_holder():
            return token
    answer = json.loads(call(record["port"], "POST", "/v1/lease",
                             body={"holder": lease_holder(), "ttl": 3600}))
    project.lease_path.write_text(json.dumps({"token": answer["token"]}) + "\n", encoding="utf-8")
    return answer["token"]


def lease_holder() -> str:
    return f"{os.environ.get('USER', 'someone')} via ghidra_owner"


def write(project: Project, path: str, body: dict) -> dict:
    """One change of the review, under the lease."""
    record = project.owner()
    if not record:
        raise OwnerError("no owner is running for this module; open it first")
    token = lease(project, record)
    try:
        answer = json.loads(call(record["port"], "POST", path, body=body, lease=token))
    except OwnerError as error:
        if "lease" not in str(error):
            raise
        # The lease expired between two commands: take it again once.
        project.lease_path.unlink(missing_ok=True)
        token = lease(project, record)
        answer = json.loads(call(record["port"], "POST", path, body=body, lease=token))
    state = project.state()
    if not state.get("reviewed"):
        state["reviewed"] = True
        project.write_state(state)
    return answer


def release(project: Project, store: cas.Store, by: str | None = None) -> dict | None:
    """Publish what the lease changed, then give the lease back (§7.3)."""
    record = project.owner()
    if not record or not project.lease_path.is_file():
        return None
    manifest = publish(project, store, by=by)
    token = json.loads(project.lease_path.read_text(encoding="utf-8")).get("token")
    try:
        call(record["port"], "DELETE", "/v1/lease", lease=token)
    finally:
        project.lease_path.unlink(missing_ok=True)
    return manifest


# -- publish ------------------------------------------------------------------

def publish(project: Project, store: cas.Store, by: str | None = None) -> dict:
    """The program's artifact and its review document, from the owner, into
    the store.

    A program nobody has reviewed publishes the mechanical reading: no
    `reading` in the manifest. A reviewed one publishes a revision of this
    project's reading — one more than the last whenever the artifact or the
    document changed — naming the document, which is stored first (§5.4's
    order), then recorded in the module's history with `by`. The recipe takes the exporter and the Ghidra from the artifact,
    the types and passes from what made the project (§5.2).
    """
    record = project.owner()
    if not record:
        raise OwnerError("no owner is running for this module; open it first")
    state = project.state()
    headers: dict = {}
    with progress.Step(f"Publishing {state['module']['name']}"):
        raw = call(record["port"], "POST", "/v1/publish", timeout=3600, headers=headers)
        document = call(record["port"], "GET", "/v1/review")
    artifact = json.loads(raw)
    reviewed = headers.get("x-owner-reviewed") == "true"
    conflicts = [name for name in headers.get("x-owner-type-conflicts", "").split(",") if name]
    if conflicts:
        print("these types are defined differently by another review and were not shared: "
              + ", ".join(conflicts), file=sys.stderr)
    last = state.get("published") or {}
    reading = None
    review = None
    if reviewed:
        review = store.put_object(document)
        changed = (last.get("artifact") != cas.sha256_bytes(raw) or last.get("review") != review)
        rev = max(1, (last.get("rev") or 0) + (1 if changed else 0))
        reading = {"project": state["project"], "rev": rev, "review": review}
        store.record_revision(project.sha, reading, by=by)
    made = state["made_with"]
    recipe = code_artifact.recipe_for(artifact, made.get("types"), made.get("passes"))
    program = artifact.get("program", {})
    module = {**state["module"], "language": program.get("language"),
              "image_base": program.get("image_base")}
    # A mechanical artifact never replaces another — except this project's
    # own last publish, which a new one of the same program supersedes (an
    # exporter fix, a newer Ghidra under the same recipe). An analysis someone
    # else stored is left alone, and the store says so.
    stored = store.analysis(project.sha, recipe["id"])
    ours = bool(stored and state.get("published")
                and stored["artifact"]["sha256"] == state["published"].get("artifact"))
    manifest = store.put_analysis(module=module, recipe=recipe, artifact=raw,
                                  source=state.get("source") or None, replace=ours,
                                  reading=reading)
    state["published"] = {"artifact": manifest["artifact"]["sha256"], "recipe": recipe["id"],
                          "review": review, "rev": reading["rev"] if reading else None,
                          "at": now()}
    state["reviewed"] = reviewed
    project.write_state(state)
    return manifest


# -- the command line ---------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Kept Ghidra projects and their owners.")
    parser.add_argument("--projects", type=Path, default=projects_root())
    parser.add_argument("--store", type=cas.store_location, default=code_artifact.default_store())
    parser.add_argument("--ghidra-home")
    sub = parser.add_subparsers(dest="command", required=True)

    open_ = sub.add_parser("open", help="make the module's project if needed and start its owner")
    open_.add_argument("module", type=Path)
    open_.add_argument("--name")
    open_.add_argument("--document")
    open_.add_argument("--node")
    open_.add_argument("--phase", choices=["auto", "pei", "dxe"], default="auto")
    open_.add_argument("--no-uefi", action="store_true")
    open_.add_argument("--types-cache", type=Path)
    open_.add_argument("--idle", type=int, default=1800,
                       help="seconds without a call before the owner saves and exits (0: never)")

    sub.add_parser("status", help="the kept projects and their owners")
    get = sub.add_parser("get", help="one read call of the bridge, e.g. /v1/functions")
    get.add_argument("module")
    get.add_argument("path")
    pub = sub.add_parser("publish", help="store the artifact of the program as it stands")
    pub.add_argument("module")
    pub.add_argument("--by", choices=["agent", "person"], default="agent",
                     help="who published, as the review history records it")
    rename = sub.add_parser("rename", help="name a function")
    rename.add_argument("module")
    rename.add_argument("address")
    rename.add_argument("name")
    rename.add_argument("--reason")
    rename.add_argument("--by", choices=["agent", "person"], default="agent")
    variable = sub.add_parser("rename-var", help="name a parameter or a local, perhaps type it")
    variable.add_argument("module")
    variable.add_argument("function")
    variable.add_argument("name")
    variable.add_argument("--storage", help="as /v1/function lists it, e.g. EAX:4 or Stack[-0x18]:4")
    variable.add_argument("--first-use", help="for a register local: the address of its first use")
    variable.add_argument("--ordinal", type=int, help="a parameter by its position")
    variable.add_argument("--type")
    comment = sub.add_parser("comment", help="set or clear a listing comment")
    comment.add_argument("module")
    comment.add_argument("address")
    comment.add_argument("text", help="empty clears it")
    comment.add_argument("--kind", choices=["pre", "post", "eol", "plate", "repeatable"], default="pre")
    signature = sub.add_parser("signature", help="a function's C signature")
    signature.add_argument("module")
    signature.add_argument("address")
    signature.add_argument("signature")
    signature.add_argument("--reason")
    signature.add_argument("--by", choices=["agent", "person"], default="agent")
    datum = sub.add_parser("data", help="name or type a datum")
    datum.add_argument("module")
    datum.add_argument("address")
    datum.add_argument("--name")
    datum.add_argument("--type")
    type_ = sub.add_parser("type", help="add a structure, union, enum or typedef from C")
    type_.add_argument("module")
    type_.add_argument("c", help="the C text, or @file to read it from a file")
    rel = sub.add_parser("release", help="publish and give the write lease back")
    rel.add_argument("module")
    rel.add_argument("--by", choices=["agent", "person"], default="agent")
    stop = sub.add_parser("stop", help="save and stop the module's owner")
    stop.add_argument("module")
    args = parser.parse_args(argv)

    try:
        if args.command == "open":
            module = args.module.expanduser().resolve()
            blob = module.read_bytes()
            project = Project(args.projects, hashlib.sha256(blob).hexdigest())
            if not project.exists:
                project.create(module, blob, args.name or module.stem,
                               {"path": str(module), "document": args.document, "node": args.node},
                               args.phase, not args.no_uefi, args.ghidra_home, args.types_cache)
            else:
                # A project made before the archive was recorded learns it now:
                # the archive of the types it was made with, not today's.
                state = project.state()
                types = state.get("made_with", {}).get("types")
                if types and not state.get("archive"):
                    bits = "Ia32" if code_artifact.machine(blob) == 0x14C else "X64"
                    gdt = uefi_types.paths(args.types_cache)["root"] / f"uefi_{bits}-{types}.gdt"
                    if gdt.is_file():
                        state["archive"] = str(gdt)
                        project.write_state(state)
            record = project.start(args.ghidra_home, args.idle)
            print(json.dumps({"module": project.sha, "port": record["port"],
                              "name": project.state()["module"]["name"]}, indent=2))
            return 0
        if args.command == "status":
            rows = []
            root = args.projects
            for folder in sorted(root.iterdir()) if root.is_dir() else []:
                if not cas.is_digest(folder.name):
                    continue
                project = Project(root, folder.name)
                if not project.exists:
                    continue
                state = project.state()
                record = project.owner()
                size = sum(path.stat().st_size for path in folder.rglob("*") if path.is_file())
                rows.append({"module": project.sha, "name": state["module"]["name"],
                             "owner": record["port"] if record else None,
                             "reviewed": state.get("reviewed", False),
                             "published": state.get("published"), "bytes": size})
            print(json.dumps(rows, indent=2))
            return 0
        project = Project(args.projects, args.module)
        if not project.exists:
            print(f"no project for {args.module}", file=sys.stderr)
            return 1
        if args.command == "get":
            record = project.owner()
            if not record:
                print("no owner is running for this module; open it first", file=sys.stderr)
                return 1
            sys.stdout.write(call(record["port"], "GET", args.path).decode("utf-8"))
            return 0
        if args.command == "publish":
            print(json.dumps(publish(project, cas.Store(args.store), by=args.by), indent=2))
            return 0
        writes = {
            "rename": lambda: ("/v1/rename/function",
                               {"address": args.address, "name": args.name,
                                "reason": args.reason, "by": args.by}),
            "rename-var": lambda: ("/v1/rename/variable",
                                   {"function": args.function, "name": args.name,
                                    "storage": args.storage, "first_use": args.first_use,
                                    "ordinal": args.ordinal, "type": args.type}),
            "comment": lambda: ("/v1/set/comment",
                                {"address": args.address, "kind": args.kind, "text": args.text}),
            "signature": lambda: ("/v1/set/signature",
                                  {"address": args.address, "signature": args.signature,
                                   "reason": args.reason, "by": args.by}),
            "data": lambda: ("/v1/set/data",
                             {"address": args.address, "name": args.name, "type": args.type}),
            "type": lambda: ("/v1/type",
                             {"c": Path(args.c[1:]).read_text() if args.c.startswith("@") else args.c}),
        }
        if args.command in writes:
            path, body = writes[args.command]()
            print(json.dumps(write(project, path, body), indent=2))
            return 0
        if args.command == "release":
            manifest = release(project, cas.Store(args.store), by=args.by)
            print(json.dumps(manifest, indent=2) if manifest else "no lease held from here")
            return 0
        if args.command == "stop":
            print("stopped" if project.stop() else "not running")
            return 0
    except (OwnerError, cas.CASError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
