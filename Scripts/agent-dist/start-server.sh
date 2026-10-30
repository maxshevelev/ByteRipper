#!/bin/bash
# Starts this copy's analysis server in the background. Everything it keeps —
# the store, the kept Ghidra projects, the documents, uploads, the MCP socket —
# stays inside var/. Running it twice is safe.
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)"
server="$dir/bin/byteripper-server"
support="$dir/var/support"
pidfile="$dir/var/server.pid"
log="$dir/var/log/server.log"
socket="$support/mcp.sock"
port="${BYTERIPPER_PORT:-}"

# A server is running when one of this copy's processes is, whatever the pid
# file still says — it may be gone, or from a start that never wrote one.
server_pid() {
    local candidate line
    for candidate in $(pgrep -f -- "$server" 2>/dev/null); do
        line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
        case " $line " in
            *" --support $support "*) printf '%s\n' "$candidate"; return 0 ;;
        esac
    done
    return 1
}

if pid="$(server_pid)"; then
    printf '%s\n' "$pid" > "$pidfile"
    echo "server already running (pid $pid)"
    exit 0
fi
mkdir -p "$dir/var/store" "$dir/var/projects" "$dir/var/dumps" "$dir/var/log" "$support"

# The tokens file the configuration names, when it names one: the server reads
# that file, so a token made here and left in the folder would never be used.
source "$dir/scripts/common.sh"
tokens_file="$(tokens_file_for "$support")"

# A port of its own: the ByteRipper app's server usually has 8765 on a Mac
# that analyses dumps, so the first free one from 8765 on is taken.
if [ -z "$port" ]; then
    for candidate in $(seq 8765 8775); do
        if ! nc -z 127.0.0.1 "$candidate" >/dev/null 2>&1; then
            port="$candidate"
            break
        fi
    done
fi
if [ -z "$port" ]; then
    echo "no free port between 8765 and 8775; set BYTERIPPER_PORT" >&2
    exit 1
fi
echo "$port" > "$dir/var/port"

if [ ! -f "$tokens_file" ]; then
    echo "first start: making this install's admin token in $tokens_file"
    secret="$("$server" token add --name admin --rights admin --tokens "$tokens_file")"
    ( umask 077; printf '%s\n' "$secret" | head -1 > "$support/admin-token.txt" )
    echo "  the console's token is in $support/admin-token.txt"
fi

args=(--support "$support" --store "$dir/var/store" --projects "$dir/var/projects"
      --dump-roots "$dir/var/dumps" --listen "127.0.0.1:$port")
if [ -n "${GHIDRA_HOME:-}" ]; then args+=(--ghidra-home "$GHIDRA_HOME"); fi

"$server" "${args[@]}" >>"$log" 2>&1 &
echo $! > "$pidfile"

for _ in $(seq 1 150); do
    if [ -S "$socket" ]; then
        echo "server running (pid "$(cat "$pidfile")"), MCP on $socket, console on http://127.0.0.1:$port/admin"
        exit 0
    fi
    if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then break; fi
    sleep 0.2
done
echo "the server did not come up; last lines of $log:" >&2
tail -20 "$log" >&2 || true
rm -f "$pidfile"
exit 1
