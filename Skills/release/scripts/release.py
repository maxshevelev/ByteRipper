#!/usr/bin/env python3
"""The mechanical half of a ByteRipper release.

    python3 Skills/release/scripts/release.py bump 0.8.5
    python3 Skills/release/scripts/release.py build [--out DIR]

`bump` writes the version into the three places that carry it — the app's
MARKETING_VERSION, its build number (one more than the last), and the README's
download line — and prints what it changed. Nothing else is touched; the diff
is the review.

`build` makes the `.dmg` a release ships, the same shape every time:
a universal (arm64 + x86_64) Release build, ad-hoc signed whatever this
machine's `Signing.local.xcconfig` says, packed into a compressed APFS image
named `ByteRipper <version>` holding the app and a link to /Applications. It
then opens the image it made and checks what it holds, so a release is never
published from a build nobody looked at.

Standard library only, like every script under Skills/.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROJECT_YML = ROOT / "project.yml"
README = ROOT / "README.md"
APP_NAME = "ByteRipper"
ARCHS = {"arm64", "x86_64"}

VERSION_RE = re.compile(r'^(\s*MARKETING_VERSION:\s*)"([^"]+)"', re.M)
BUILD_RE = re.compile(r'^(\s*CURRENT_PROJECT_VERSION:\s*)"(\d+)"', re.M)
README_RE = re.compile(r"\[\*\*ByteRipper [0-9.]+\*\*\]")


def die(message: str) -> None:
    print(f"release: {message}", file=sys.stderr)
    sys.exit(1)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, text=True, **kw)


def current_version() -> tuple[str, int]:
    text = PROJECT_YML.read_text()
    versions = VERSION_RE.findall(text)
    builds = BUILD_RE.findall(text)
    if len(versions) != 1 or len(builds) != 1:
        die("project.yml should carry exactly one MARKETING_VERSION and one "
            f"CURRENT_PROJECT_VERSION; found {len(versions)} and {len(builds)}")
    return versions[0][1], int(builds[0][1])


# MARK: - bump

def bump(version: str) -> None:
    if not re.fullmatch(r"\d+\.\d+(\.\d+)?", version):
        die(f"“{version}” is not a version like 0.8.5")
    old_version, old_build = current_version()
    if old_version == version:
        die(f"project.yml already says {version}")
    build = old_build + 1

    text = PROJECT_YML.read_text()
    text = VERSION_RE.sub(lambda m: f'{m.group(1)}"{version}"', text)
    text = BUILD_RE.sub(lambda m: f'{m.group(1)}"{build}"', text)
    PROJECT_YML.write_text(text)

    readme = README.read_text()
    if len(README_RE.findall(readme)) != 1:
        die("README.md should have exactly one download line "
            "“[**ByteRipper X**](…releases/latest)”")
    README.write_text(README_RE.sub(f"[**ByteRipper {version}**]", readme))

    print(f"version  {old_version} → {version}")
    print(f"build    {old_build} → {build}")
    print(f"README   download line → ByteRipper {version}")


# MARK: - build

def build(out: Path) -> Path:
    version, build_number = current_version()
    out.mkdir(parents=True, exist_ok=True)
    dmg = out / f"{APP_NAME}-{version}.dmg"
    work = Path(tempfile.mkdtemp(prefix="byteripper-release-", dir=out))
    derived = work / "DerivedData"

    run(["xcodegen", "generate"], cwd=ROOT, stdout=subprocess.DEVNULL)
    print(f"building {APP_NAME} {version} ({build_number}), universal, Release …")
    log = work / "xcodebuild.log"
    with log.open("w") as handle:
        result = subprocess.run(
            ["xcodebuild",
             "-project", f"{APP_NAME}.xcodeproj",
             "-scheme", APP_NAME,
             "-configuration", "Release",
             "-destination", "generic/platform=macOS",
             "-derivedDataPath", str(derived),
             f"ARCHS={' '.join(sorted(ARCHS))}",
             "ONLY_ACTIVE_ARCH=NO",
             # A release is ad-hoc signed, whatever a developer's local
             # xcconfig says: a personal team never ships in a download.
             "CODE_SIGN_STYLE=Manual",
             "CODE_SIGN_IDENTITY=-",
             "DEVELOPMENT_TEAM=",
             "build"],
            cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        die(f"xcodebuild failed; the log is {log}")
    app = derived / "Build/Products/Release" / f"{APP_NAME}.app"
    if not app.is_dir():
        die(f"no app at {app}; the log is {log}")
    check_app(app, version, build_number)

    stage = work / "stage"
    stage.mkdir()
    run(["ditto", str(app), str(stage / app.name)])
    os.symlink("/Applications", stage / "Applications")
    if dmg.exists():
        dmg.unlink()
    run(["hdiutil", "create",
         "-volname", f"{APP_NAME} {version}",
         "-srcfolder", str(stage),
         "-fs", "APFS",
         "-format", "UDZO",
         str(dmg)], stdout=subprocess.DEVNULL)
    check_dmg(dmg, version, build_number)
    shutil.rmtree(work)
    print(f"dmg      {dmg} ({dmg.stat().st_size / 1_000_000:.1f} MB)")
    return dmg


def check_app(app: Path, version: str, build_number: int) -> None:
    """What a release promises about the app, read off the app itself."""
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleShortVersionString") != version:
        die(f"the app says {info.get('CFBundleShortVersionString')}, not {version}")
    if info.get("CFBundleVersion") != str(build_number):
        die(f"the app's build is {info.get('CFBundleVersion')}, not {build_number}")

    binary = app / "Contents/MacOS" / APP_NAME
    archs = set(run(["lipo", "-archs", str(binary)],
                    capture_output=True).stdout.split())
    if archs != ARCHS:
        die(f"the binary is {sorted(archs)}, not universal {sorted(ARCHS)}")

    signature = run(["codesign", "-dv", str(app)], capture_output=True).stderr
    if "Signature=adhoc" not in signature:
        die("the app is not ad-hoc signed:\n" + signature)
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    print(f"app      {version} ({build_number}), {' + '.join(sorted(archs))}, ad-hoc, verified")


def check_dmg(dmg: Path, version: str, build_number: int) -> None:
    """Open the image that was made and read it the way a user would."""
    mount = Path(tempfile.mkdtemp(prefix="byteripper-dmg-"))
    run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(dmg)],
        stdout=subprocess.DEVNULL)
    try:
        entries = sorted(p.name for p in mount.iterdir() if not p.name.startswith("."))
        if entries != ["Applications", f"{APP_NAME}.app"]:
            die(f"the image holds {entries}")
        if os.readlink(mount / "Applications") != "/Applications":
            die("Applications is not a link to /Applications")
        check_app(mount / f"{APP_NAME}.app", version, build_number)
    finally:
        run(["hdiutil", "detach", str(mount)], stdout=subprocess.DEVNULL)
        mount.rmdir()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("bump", help="write the version into project.yml and the README")
    b.add_argument("version")
    d = sub.add_parser("build", help="build and check the release .dmg")
    d.add_argument("--out", type=Path, default=ROOT / "build/release",
                   help="where the .dmg goes (default: build/release)")
    args = parser.parse_args()
    if args.command == "bump":
        bump(args.version)
    else:
        build(args.out.resolve())


if __name__ == "__main__":
    main()
