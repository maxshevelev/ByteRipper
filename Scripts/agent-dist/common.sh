# What start-server.sh, stop-server.sh and doctor.sh share. Sourced, not run.

# The configuration file the server reads unless told otherwise.
config_file() {
    printf '%s\n' "${BYTERIPPER_CONFIG:-$HOME/.byteripper-server.json}"
}

# The tokens file the server will use: the `tokens` the configuration names —
# a flag on the line wins over the file, but the launchers pass none — else
# tokens.json in the support folder they pass with --support.
tokens_file_for() {
    local support="$1" config named
    config="$(config_file)"
    named=""
    if [ -f "$config" ]; then
        named="$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("tokens", ""))
except Exception:
    pass' "$config" 2>/dev/null || true)"
        case "$named" in
            "~/"*) named="$HOME/${named#\~/}" ;;
        esac
    fi
    if [ -n "$named" ]; then printf '%s\n' "$named"; else printf '%s\n' "$support/tokens.json"; fi
}
