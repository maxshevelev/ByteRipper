#!/bin/bash
# Makes the Ghidra the analyses run on: a copy of a stock install with the x86
# language patched and compiled, and the decompiler's 32-bit x86 stack
# parameters corrected and rebuilt; the stock install left as it was.
#
#   Scripts/make-patched-ghidra.sh <stock ghidra home> <new folder>
#
# Why the patches exist is in Skills/ghidra-uefi/language-patch/README.md. The
# copy carries two markers, `byteripper-language-patch` and
# `byteripper-decompiler-patch`: the first line of each names its patch, the
# rest are the built files' hashes, which the exporter, the owner's `hello` and
# the doctor read. Name the copy's folder in `ghidraHome`.
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
decompiler_id=stack-params-1
languages=Ghidra/Processors/x86/data/languages
cpp=Ghidra/Features/Decompiler/src/decompile/cpp
java=Ghidra/Framework/SoftwareModeling/src/main/java
modeling=Ghidra/Framework/SoftwareModeling/lib/SoftwareModeling.jar
# The ia.sinc this patch was made against; another Ghidra's is looked at first.
source_sha=32a723931726561212b1f51c05d0d4324e880c4a49958e16bdc80e5066e98115

[ -x "$stock/support/sleigh" ] || { echo "$stock: no support/sleigh there" >&2; exit 1; }
[ ! -e "$copy" ] || { echo "$copy exists; name a new folder" >&2; exit 1; }
have="$(shasum -a 256 "$stock/$languages/ia.sinc" | cut -d' ' -f1)"
if [ "$have" != "$source_sha" ]; then
    echo "$stock/$languages/ia.sinc is not the file $id was made against: read the patch against it first" >&2
    exit 1
fi
# The decompiler's fspec.cc the second patch was made against.
fspec_sha=7c3a974621f5abcc663e6290b8dbea5d7a98b711b945057d2aee152942990359
have="$(shasum -a 256 "$stock/$cpp/fspec.cc" | cut -d' ' -f1)"
if [ "$have" != "$fspec_sha" ]; then
    echo "$stock/$cpp/fspec.cc is not the file $decompiler_id was made against: read the patch against it first" >&2
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
# The decompiler: ParamEntry in its C++ and in the Java that hands the
# decompiler its storage, both from the sources the install ships.
mkdir -p "$copy/$java"
unzip -q -o "$stock/Ghidra/Framework/SoftwareModeling/lib/SoftwareModeling-src.zip" \
    ghidra/program/model/lang/ParamEntry.java -d "$copy/$java"
patch -s -p1 -d "$copy" < "$patches/$decompiler_id.patch"
build="$(mktemp -d)"
cp -R "$copy/$cpp/" "$build/"
make -s -C "$build" -j8 ghidra_opt CXX="clang++ -std=c++11" >/dev/null
case "$(uname -m)" in arm64) os=mac_arm_64 ;; *) os=mac_x86_64 ;; esac
[ -d "$copy/Ghidra/Features/Decompiler/os/$os" ] || { echo "$copy: no decompiler for $os to replace" >&2; exit 1; }
cp "$build/ghidra_opt" "$copy/Ghidra/Features/Decompiler/os/$os/decompile"
rm -rf "$build"
classes="$(mktemp -d)"
"$JAVA_HOME/bin/javac" -nowarn -d "$classes" -cp "$(find "$copy/Ghidra" -name '*.jar' | tr '\n' ':')" \
    "$copy/$java/ghidra/program/model/lang/ParamEntry.java"
(cd "$classes" && "$JAVA_HOME/bin/jar" uf "$copy/$modeling" ghidra/program/model/lang/ParamEntry*.class)
rm -rf "$classes"
{
    echo "$decompiler_id"
    (cd "$copy" && shasum -a 256 "Ghidra/Features/Decompiler/os/$os/decompile" "$modeling")
} > "$copy/byteripper-decompiler-patch"
for spec in x86.slaspec x86-64.slaspec; do
    (cd "$copy/$languages" && "$copy/support/sleigh" "$spec" >/dev/null)
done
{
    echo "$id"
    (cd "$copy" && shasum -a 256 "$languages/x86.sla" "$languages/x86-64.sla")
} > "$copy/byteripper-language-patch"
echo "made $copy: $id, $decompiler_id"
sed -n '2,$p' "$copy/byteripper-language-patch"
sed -n '2,$p' "$copy/byteripper-decompiler-patch"
