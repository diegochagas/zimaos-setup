#!/usr/bin/env bash
#
# Loading and validating config.sh.
#
# All paths, addresses and secrets live in the gitignored
# config.sh — nothing machine-specific is kept in the code.
# Shared by setup.sh and export.sh; runs before the log
# file exists, so errors go straight to the terminal.
#

readonly CONFIG_FILE="$SCRIPT_DIR/config.sh"

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat >&2 << EOF
❌ config.sh not found.
   Copy config.sh.example to config.sh and fill in the values,
   or restore the filled-in copy from the Credentials folder.
EOF
        exit 1
    fi

    # shellcheck source=config.sh.example
    source "$CONFIG_FILE"
}

# Exits listing every given variable that is empty or
# unset in config.sh.
#
# Arguments:
#   $@ - Variable names
require_config_values() {
    local variable
    local missing=()

    for variable in "$@"; do
        if [[ -z "${!variable:-}" ]]; then
            missing+=("$variable")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        return 0
    fi

    echo "❌ Missing values in config.sh:" >&2
    for variable in "${missing[@]}"; do
        echo "   $variable" >&2
    done
    echo >&2
    echo "   See config.sh.example for the full list." >&2
    exit 1
}
