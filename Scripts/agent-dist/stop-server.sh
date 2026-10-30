#!/bin/bash
# Stops this copy's analysis server, found by its process rather than by the
# pid file it may not have written. The owners it started save and exit with
# it; nothing in var/ is removed.
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)"
server="$dir/bin/byteripper-server"
pidfile="$dir/var/server.pid"

source "$dir/scripts/common.sh"
support="$(support_for "$dir/var/support")"
support_named="$(config_value support)"

matches_this_copy() {
    local line="$1"
    case " $line " in
        *" --support $support "*) return 0 ;;
    esac
    [ -n "$support_named" ] || return 1
    case " $line " in
        *" --support "*) return 1 ;;
    esac
    return 0
}

server_pid() {
    local candidate line
    for candidate in $(pgrep -f -- "$server" 2>/dev/null); do
        line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
        if matches_this_copy "$line"; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}

if ! pid="$(server_pid)"; then
    # A start from before a configuration change keeps another folder; its
    # process is still this copy's, and the pid file names it.
    candidate="$(cat "$pidfile" 2>/dev/null || true)"
    line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
    case "$line" in
        *"$server"*) pid="$candidate" ;;
        *)
            echo "server not running"
            rm -f "$pidfile"
            exit 0
            ;;
    esac
fi
kill "$pid"
for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$pid" 2>/dev/null; then
    echo "still running after 10 s; sending KILL" >&2
    kill -9 "$pid" 2>/dev/null || true
fi
rm -f "$pidfile"
echo "server stopped"
