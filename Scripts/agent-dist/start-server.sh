#!/bin/bash
# Starts this copy's analysis server in the background. By default everything
# it keeps — store, projects, documents, uploads, socket — stays inside var/;
# a configuration file may point the server at other folders, and then this
# copy respects what it says instead of overriding it. Running it twice is
# safe.
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)"
server="$dir/bin/byteripper-server"
pidfile="$dir/var/server.pid"
log="$dir/var/log/server.log"
port="${BYTERIPPER_PORT:-}"

source "$dir/scripts/common.sh"
support="$(support_for "$dir/var/support")"
support_named="$(config_value support)"
socket="$support/mcp.sock"
tokens_file="$(tokens_file_for "$support")"

# A server is running when one of this copy's processes is, whatever the pid
# file still says — it may be gone, or from a start that never wrote one. A
# process started without --support takes the folder from the configuration.
matches_this_copy() {
    local line="$1"
    case " $line " in
        *" --support $support "*) return 0 ;;
    esac
    [ -n "$support_named" ] || return 1    # this copy passes the flag itself
    case " $line " in
        *" --support "*) return 1 ;;       # another folder
    esac
    return 0                               # no flag: the configuration's folder
}

server_pid() {
    local candidate line
    for candidate in $(pgrep -f -- "$server" 2>/dev/null); do
        line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
        if matches_this_copy "$line"; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}

if pid="$(server_pid)"; then
    printf '%s\n' "$pid" > "$pidfile"
    echo "server already running (pid $pid)"
    exit 0
fi
# A server of this copy that keeps another folder is still one server: two of
# them would write the same store and fight over the projects.
if other="$(pgrep -f -- "$server" | head -1)" && [ -n "$other" ]; then
    echo "another server of this copy is running (pid $other) with other folders;" >&2
    echo "stop it first: $dir/scripts/stop-server.sh" >&2
    exit 1
fi
mkdir -p "$dir/var/store" "$dir/var/projects" "$dir/var/dumps" "$dir/var/log" "$support"

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
    ( umask 077; printf '%s\n' "$secret" | head -1 > "$dir/var/admin-token.txt" )
    echo "  the console's token is in $dir/var/admin-token.txt"
fi

args=(--dump-roots "$dir/var/dumps" --listen "127.0.0.1:$port")
# What the configuration names is left to it; a flag here would override it.
if [ -z "$support_named" ]; then args+=(--support "$support"); fi
if [ -z "$(config_value store)" ]; then args+=(--store "$dir/var/store"); fi
if [ -z "$(config_value projects)" ]; then args+=(--projects "$dir/var/projects"); fi
if [ -n "${GHIDRA_HOME:-}" ]; then args+=(--ghidra-home "$GHIDRA_HOME"); fi

"$server" "${args[@]}" >>"$log" 2>&1 &
echo $! > "$pidfile"

for _ in $(seq 1 150); do
    if [ -S "$socket" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
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
