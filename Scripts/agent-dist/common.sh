# What start-server.sh, stop-server.sh and doctor.sh share. Sourced, not run.

# The configuration file the server reads unless told otherwise.
config_file() {
    printf '%s\n' "${BYTERIPPER_CONFIG:-$HOME/.byteripper-server.json}"
}

# A string setting of the configuration file, or nothing: `config_value store`.
# Keys are tried in order, so `config_value serverName serverNames` answers
# with whichever the file uses.
config_value() {
    local config
    config="$(config_file)"
    [ -f "$config" ] || return 0
    python3 -c 'import json, sys
try:
    settings = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for key in sys.argv[2:]:
    value = settings.get(key)
    if isinstance(value, str) and value:
        print(value)
        break' "$config" "$@" 2>/dev/null || true
}

# The tokens file the server will use: the `tokens` the configuration names —
# a flag on the line wins over the file, but the launchers pass none — else
# tokens.json in the support folder they pass with --support.
tokens_file_for() {
    local support="$1" named
    named="$(config_value tokens)"
    case "$named" in
        "~/"*) named="$HOME/${named#\~/}" ;;
    esac
    if [ -n "$named" ]; then printf '%s\n' "$named"; else printf '%s\n' "$support/tokens.json"; fi
}

# The support folder the server will use: the `support` the configuration
# names — resolved the way the server resolves it, `~` expanded and a relative
# one from the file's folder — else the copy's own var/support.
support_for() {
    local fallback="$1" named
    named="$(config_value support)"
    if [ -z "$named" ]; then
        printf '%s\n' "$fallback"
        return
    fi
    case "$named" in
        "~/"*) named="$HOME/${named#\~/}" ;;
        /*) ;;
        *) named="$(cd "$(dirname "$(config_file)")" && pwd)/$named" ;;
    esac
    printf '%s\n' "$named"
}
