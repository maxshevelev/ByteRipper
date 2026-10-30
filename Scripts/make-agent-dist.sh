#!/bin/bash
# Builds the analysis distribution: a release server, the Ghidra scripts it
# compiles, the review skill an agent reads, and the launchers that keep all of
# it inside one folder. The result is generated, never committed.
#
#   Scripts/make-agent-dist.sh [<out-dir>]      (dist/ by default)
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$repo/dist}"
version="$(git -C "$repo" describe --tags --always --dirty 2>/dev/null || echo dev)"
name="byteripper-analysis-$version"
stage="$out/$name"

if [ -z "$out" ] || [ "$out" = "/" ] || [ "$out" = "$HOME" ]; then
    echo "refusing to use $out as the output folder" >&2
    exit 1
fi
mkdir -p "$out"

echo "building byteripper-server and byteripper-cas (release)"
swift build -c release --package-path "$repo/Packages/ByteRipperServer" --product byteripper-server
swift build -c release --package-path "$repo/Packages/CodeAnalysis" --product byteripper-cas

rm -rf "$stage"
mkdir -p "$stage"/{bin,ghidra/owner,ghidra/scripts,skills/ghidra-uefi/scripts,scripts,var/store,var/projects,var/support,var/dumps,var/log,.claude/skills}

cp "$repo/Packages/ByteRipperServer/.build/release/byteripper-server" "$stage/bin/"
cp "$repo/Packages/CodeAnalysis/.build/release/byteripper-cas" "$stage/bin/"
chmod 755 "$stage"/bin/*

# The Ghidra scripts the server compiles and runs — the layout OwnerSources
# reads: owner/ with the owner's sources, scripts/ with the passes.
cp "$repo/Skills/ghidra-uefi/owner/"*.java "$stage/ghidra/owner/"
cp "$repo/Skills/ghidra-uefi/scripts/"*.java "$stage/ghidra/scripts/"

# What the agent reads: the skill, its reference, and the store's client.
cp "$repo/Skills/ghidra-uefi/SKILL.md" "$stage/skills/ghidra-uefi/"
cp -R "$repo/Skills/ghidra-uefi/reference" "$stage/skills/ghidra-uefi/"
cp "$repo/Skills/ghidra-uefi/scripts/cas.py" "$repo/Skills/ghidra-uefi/scripts/cas_cli.py" \
    "$stage/skills/ghidra-uefi/scripts/"
cp -R "$repo/Skills/ghidra-uefi/tests" "$stage/skills/ghidra-uefi/"

cp "$repo/Scripts/agent-dist/"*.sh "$stage/scripts/"
cp "$repo/Scripts/agent-dist/README.md" "$repo/Scripts/agent-dist/CLAUDE.md" "$stage/"
cp "$repo/INSTALL.md" "$stage/"
chmod 755 "$stage"/scripts/*.sh

ln -s ../../skills/ghidra-uefi "$stage/.claude/skills/ghidra-uefi"

cat > "$stage/VERSION" <<EOF
version: $version
commit: $(git -C "$repo" rev-parse --short HEAD)
branch: $(git -C "$repo" rev-parse --abbrev-ref HEAD)
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
ghidra: 12.1.2 — the analyses' recipe; another version is a second recipe
EOF

tar -C "$out" -czf "$out/$name.tar.gz" "$name"

# One build is kept: an earlier folder and tarball in the output folder go
# once this one is written, so a failed build never costs the last good copy.
for path in "$out"/byteripper-analysis-*; do
    [ -e "$path" ] || continue
    base="$(basename "$path")"
    [ "$base" = "$name" ] && continue
    [ "$base" = "$name.tar.gz" ] && continue
    rm -rf "$path"
done

# One name to hand out: it follows the newest tarball, whatever its version.
ln -sfn "$name.tar.gz" "$out/byteripper-analysis.tgz"

echo "made $out/$name.tar.gz (aliased as $out/byteripper-analysis.tgz)"
