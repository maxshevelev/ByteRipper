#!/bin/bash
# What start-server.sh does about the processes it finds, against a stand-in
# binary and in a home of its own, so no real server, store or config is near:
# a session's relay does not stop a start; a server of this copy keeping another
# folder does; one of this folder is reported as running.
#   Scripts/test-start-server.sh
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
root="$(mktemp -d -t test-start-server)"
copy="$root/copy"
mkdir -p "$copy/bin" "$copy/scripts" "$root/home"
cp "$repo/Scripts/agent-dist/start-server.sh" "$repo/Scripts/agent-dist/stop-server.sh" "$repo/Scripts/agent-dist/common.sh" "$copy/scripts/"
server="$copy/bin/byteripper-server"
cat > "$server" <<'STUB'
#!/usr/bin/python3 -I
import os, socket, sys, time
arguments = sys.argv[1:]
if arguments[:2] == ["token", "add"]:
    print("stand-in-secret"); sys.exit(0)
if "--support" in arguments and "relay" not in arguments:
    folder = arguments[arguments.index("--support") + 1]
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "mcp.sock")
    if not os.path.exists(path):
        socket.socket(socket.AF_UNIX).bind(path)
time.sleep(60)
STUB
chmod +x "$server"
export HOME="$root/home" BYTERIPPER_PORT=18999
unset GHIDRA_HOME
started=()
failed=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected $2, got $3"; failed=1; fi; }
stop_all() { for pid in $(pgrep -f -- "$server"); do kill "$pid" 2>/dev/null; done; sleep 1; }
trap stop_all EXIT

"$server" relay --mcp-socket "$root/none" & sleep 1
output="$("$copy/scripts/start-server.sh" 2>&1)"; code=$?
check "a relay up: it starts" 0 "$code"
case "$output" in *"server running (pid"*) check "a relay up: the server runs" yes yes ;; *) check "a relay up: the server runs" yes "$output" ;; esac

output="$("$copy/scripts/start-server.sh" 2>&1)"; code=$?
check "a server of this folder up: exit" 0 "$code"
case "$output" in *"already running"*) check "a server of this folder up: says so" yes yes ;; *) check "a server of this folder up: says so" yes "$output" ;; esac
stop_all

"$server" --support "$root/elsewhere" & sleep 1
output="$("$copy/scripts/start-server.sh" 2>&1)"; code=$?
check "a server of another folder up: refused" 1 "$code"
case "$output" in *"another server of this copy"*) check "a server of another folder up: says so" yes yes ;; *) check "a server of another folder up: says so" yes "$output" ;; esac
exit $failed
