#!/bin/bash
# Starts a built package's server as nothing but its own folder: its binary and
# what is beside it, its own store, no configuration. A dump is opened and its
# UEFI tree built, the call that stops a server missing a resource bundle.
#   Scripts/check-agent-package.sh <package folder> <dump> [port] [--without <bundle>]
# Refuses while the folder the binary was compiled in still has its bundles: they
# would answer for the package. Changes nothing in the package or the dump.
set -uo pipefail
package="$1"; dump="$2"; port="${3:-18790}"; without="${5:-}"
binary="$package/bin/byteripper-server"
[ -x "$binary" ] || { echo "FAIL  $binary is missing"; exit 1; }
for compiled in $(strings "$binary" | grep -E '^/.*/[A-Za-z]+_[A-Za-z]+\.bundle$' | sort -u); do
    if [ -d "$compiled" ]; then
        echo "REFUSED  the build folder is still there, and would answer for the package: $compiled"
        exit 2
    fi
done
exec python3 -I - "$package" "$dump" "$port" "$without" <<'PY'
import hashlib, json, os, shutil, subprocess, sys, tempfile, time, urllib.request
package, dump, port, without = sys.argv[1:5]
root = tempfile.mkdtemp(prefix="check-agent-package-")
shutil.copytree(os.path.join(package, "bin"), root + "/bin")
if without:
    shutil.rmtree(f"{root}/bin/{without}")
for folder in ("support", "store", "projects", "dumps"):
    os.makedirs(f"{root}/{folder}")
copy = root + "/dumps/dump.bin"
shutil.copy(dump, copy)
stat = os.stat(copy)
document = {"id": "d1", "name": "dump.bin", "path": copy, "uploaded": False, "version": 1,
            "sha256": hashlib.sha256(open(copy, "rb").read()).hexdigest(),
            "stamp": {"ctime": int(stat.st_ctime), "ctime_ns": stat.st_ctime_ns % 10**9, "inode": stat.st_ino,
                      "mtime": int(stat.st_mtime), "mtime_ns": stat.st_mtime_ns % 10**9, "size": stat.st_size}}
json.dump({"documents": [document], "next_id": 2}, open(root + "/support/documents.json", "w"))
server = root + "/bin/byteripper-server"
socket = root + "/support/mcp.sock"
log = open(root + "/server.log", "w")
subprocess.run([server, "token", "add", "--name", "admin", "--rights", "admin", "--tokens", root + "/support/tokens.json"],
               stdout=subprocess.DEVNULL, stderr=log, check=True)
process = subprocess.Popen([server, "serve", "--no-config", "--support", root + "/support", "--store", root + "/store",
                            "--projects", root + "/projects", "--listen", "127.0.0.1:" + port,
                            "--dump-roots", root + "/dumps", "--mcp-socket", socket], stdout=log, stderr=log)
failed = 0
def result(good, text):
    global failed
    print(("ok    " if good else "FAIL  ") + text)
    failed += 0 if good else 1
def call(tool, arguments):
    relay = subprocess.Popen([server, "relay", "--mcp-socket", socket], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True)
    def rpc(number, method, params):
        relay.stdin.write(json.dumps({"jsonrpc": "2.0", "id": number, "method": method, "params": params}) + "\n")
        relay.stdin.flush()
        return json.loads(relay.stdout.readline())
    rpc(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                          "clientInfo": {"name": "check-agent-package", "version": "1"}})
    relay.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    relay.stdin.flush()
    answer = rpc(2, "tools/call", {"name": tool, "arguments": arguments})
    relay.stdin.close()
    relay.terminate()
    return answer
time.sleep(4)
result(process.poll() is None, "the server started")
if process.poll() is None:
    for tool, arguments in (("documents", {}), ("code_modules", {}),
                            ("uefi_find", {"name": "PE32 image", "type": "Section", "limit": 1})):
        answer = call(tool, arguments)
        result("result" in answer and not answer["result"].get("isError"), f"{tool} answered")
        time.sleep(1)
        result(process.poll() is None, f"the server is alive after {tool}")
        if process.poll() is not None:
            break
if process.poll() is None:
    try:
        status = urllib.request.urlopen(f"http://127.0.0.1:{port}/admin", timeout=10).status
    except Exception as error:
        status = str(error)
    result(status == 200, f"console: {status}")
    result(process.poll() is None, "the server is alive at the end")
    process.terminate()
    process.wait(10)
log.close()
for line in open(root + "/server.log"):
    if "Fatal error" in line or "not found; speaking" in line:
        print("log   " + line.strip()[:200])
print(f"scratch folder: {root}")
sys.exit(1 if failed else 0)
PY
