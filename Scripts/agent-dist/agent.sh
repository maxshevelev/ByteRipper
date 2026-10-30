#!/bin/bash
# Starts this copy's server if it is not up, points an agent's client at it and
# opens a Claude Code session here. Everything the session sees — the MCP
# server, the skill — is this folder's, not a repository's.
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)"
"$dir/scripts/start-server.sh"

source "$dir/scripts/common.sh"
support="$(support_for "$dir/var/support")"
socket="$support/mcp.sock"

# The store's command line and the Ghidra scripts, wherever the skill's Python
# and the server look for them.
export BYTERIPPER_CAS="$dir/bin/byteripper-cas"
export BYTERIPPER_GHIDRA_SCRIPTS="$dir/ghidra"
export BYTERIPPER_SERVER_SOCKET="$socket"

cat > "$dir/.mcp.json" <<JSON
{
  "mcpServers": {
    "byteripper": {
      "command": "$dir/bin/byteripper-server",
      "args": ["relay", "--mcp-socket", "$socket"]
    }
  }
}
JSON

cd "$dir"
exec claude "$@"
