#!/bin/bash
# What this copy has and what it lacks. Changes nothing.
set -uo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)"
bad=0
ok() { echo "ok    $1"; }
no() { echo "FAIL  $1"; bad=$((bad + 1)); }
note() { echo "note  $1"; }

[ -x "$dir/bin/byteripper-server" ] && ok "server binary" || no "bin/byteripper-server is missing"
[ -x "$dir/bin/byteripper-cas" ] && ok "store tool" || no "bin/byteripper-cas is missing"
[ -f "$dir/ghidra/owner/Owner.java" ] && ok "Ghidra scripts: owner/" || no "ghidra/owner/Owner.java is missing"
[ -f "$dir/ghidra/scripts/ApplyUefi.java" ] && ok "Ghidra scripts: scripts/" || no "ghidra/scripts/ApplyUefi.java is missing"
[ -f "$dir/skills/ghidra-uefi/SKILL.md" ] && ok "skill" || no "skills/ghidra-uefi/SKILL.md is missing"
[ -f "$dir/CLAUDE.md" ] && ok "agent instructions" || note "CLAUDE.md is missing"

ghidra="${GHIDRA_HOME:-}"
if [ -z "$ghidra" ]; then
    ghidra="$(ls -d "$HOME"/Projects/ghidra/ghidra_* 2>/dev/null | sort -V | tail -1 || true)"
fi
if [ -n "$ghidra" ] && [ -x "$ghidra/support/analyzeHeadless" ]; then
    ok "Ghidra: $ghidra"
else
    no "no Ghidra install found (set GHIDRA_HOME)"
fi
command -v javac >/dev/null && ok "javac: $(command -v javac)" || no "javac is missing (a JDK is needed)"

source "$dir/scripts/common.sh"
support="$(support_for "$dir/var/support")"
tokens_file="$(tokens_file_for "$support")"
note "configuration: $(config_file)"
note "support: $support"

if [ -S "$support/mcp.sock" ]; then
    ok "server socket: $support/mcp.sock"
else
    note "the server is not running (scripts/start-server.sh)"
fi
if [ -f "$dir/var/port" ]; then
    note "console: http://127.0.0.1:$(cat "$dir/var/port")/admin"
fi
if [ -f "$dir/var/log/server.log" ]; then
    resolved="$(grep -o 'scripts [^;]*' "$dir/var/log/server.log" | tail -1 | cut -d' ' -f2- || true)"
    # The server resolves the symlink it was started through; compare the
    # folders themselves, not the two spellings of one path.
    physical="$(cd "$dir" && pwd -P)/ghidra/scripts"
    if [ "$resolved" = "$physical" ]; then
        ok "server reads the Ghidra scripts from this copy"
    elif [ -n "$resolved" ]; then
        no "the server reads the Ghidra scripts from $resolved, not $physical"
    fi
    grep -o 'Ghidra [0-9.]* at [^;]*' "$dir/var/log/server.log" | tail -1 | while read -r line; do
        note "server: $line"
    done
fi
source "$dir/scripts/common.sh"
note "tokens: $tokens_file"
if [ -f "$tokens_file" ]; then
    "$dir/bin/byteripper-server" token list --tokens "$tokens_file" 2>&1 | sed 's/^/      /'
else
    note "no tokens yet ($tokens_file); the first start makes one"
fi

[ "$bad" -eq 0 ] && echo "ready" || echo "$bad problem(s)"
exit "$([ "$bad" -eq 0 ] && echo 0 || echo 1)"
