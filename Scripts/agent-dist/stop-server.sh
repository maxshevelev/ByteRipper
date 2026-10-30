#!/bin/bash
# Stops this copy's analysis server, found by its process rather than by the
# pid file it may not have written. The owners it started save and exit with
# it; nothing in var/ is removed.
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)"
server="$dir/bin/byteripper-server"
support="$dir/var/support"
pidfile="$dir/var/server.pid"

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

if ! pid="$(server_pid)"; then
    echo "server not running"
    rm -f "$pidfile"
    exit 0
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
