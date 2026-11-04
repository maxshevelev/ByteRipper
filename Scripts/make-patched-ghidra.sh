#!/bin/bash
# Makes the Ghidra the analyses run on: a copy of a stock install with the x86
# language patched and compiled, the stock install left as it was.
#
#   Scripts/make-patched-ghidra.sh <stock ghidra home> <new folder>
#
# Why the patch exists is in Skills/ghidra-uefi/language-patch/README.md. The
# copy carries the marker `byteripper-language-patch`: its first line names the
# patch, the rest are the compiled files' hashes, which the exporter, the owner's
# `hello` and the doctor read. Name the copy's folder in `ghidraHome`.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <stock ghidra home> <new folder>" >&2
    exit 2
fi
stock="$1"
copy="$2"
here="$(cd "$(dirname "$0")" && pwd)"
patches="$here/../Skills/ghidra-uefi/language-patch"
[ -d "$patches" ] || patches="$here/../ghidra/language-patch"
id=descriptor-tables-1
languages=Ghidra/Processors/x86/data/languages
# The ia.sinc this patch was made against; another Ghidra's is looked at first.
source_sha=32a723931726561212b1f51c05d0d4324e880c4a49958e16bdc80e5066e98115

[ -x "$stock/support/sleigh" ] || { echo "$stock: no support/sleigh there" >&2; exit 1; }
[ ! -e "$copy" ] || { echo "$copy exists; name a new folder" >&2; exit 1; }
have="$(shasum -a 256 "$stock/$languages/ia.sinc" | cut -d' ' -f1)"
if [ "$have" != "$source_sha" ]; then
    echo "$stock/$languages/ia.sinc is not the file $id was made against: read the patch against it first" >&2
    exit 1
fi
if [ -e "$stock/byteripper-language-patch" ]; then
    echo "$stock already carries a language patch: start from a stock install" >&2
    exit 1
fi

export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 25+)}"
mkdir -p "$(dirname "$copy")"
cp -c -R "$stock" "$copy" 2>/dev/null || cp -R "$stock" "$copy"
patch -s -p1 -d "$copy" < "$patches/$id.patch"
for spec in x86.slaspec x86-64.slaspec; do
    (cd "$copy/$languages" && "$copy/support/sleigh" "$spec" >/dev/null)
done
{
    echo "$id"
    (cd "$copy" && shasum -a 256 "$languages/x86.sla" "$languages/x86-64.sla")
} > "$copy/byteripper-language-patch"
echo "made $copy: $id"
sed -n '2,$p' "$copy/byteripper-language-patch"
