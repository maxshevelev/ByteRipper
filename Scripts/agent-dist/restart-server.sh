#!/bin/bash
# Stops this copy's server and starts it again — after a configuration change,
# a rebuild, or a port that was taken. `var/` and its analyses are untouched.
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)"
"$dir/scripts/stop-server.sh"
"$dir/scripts/start-server.sh"
