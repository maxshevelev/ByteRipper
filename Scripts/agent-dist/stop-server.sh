#!/bin/bash
# Stops this copy's analysis server. The owners it started save and exit with
# it; nothing in var/ is removed.
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)"
pidfile="$dir/var/server.pid"

if [ ! -f "$pidfile" ] || ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "server not running"
    rm -f "$pidfile"
    exit 0
fi
pid="$(cat "$pidfile")"
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
