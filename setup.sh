#!/usr/bin/env bash

set -Eeuo pipefail
trap 'handle_error $? ${LINENO} "$BASH_COMMAND"' ERR

########################################
# ZimaOS Setup
#
# Installs the CasaOS/ZimaOS apps exported to apps/
# with their customizations (ports, volume paths,
# environment) applied from config.sh.
#
# Runs on the ZimaOS server itself.
########################################

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Load configuration. All paths, addresses and secrets live in the
# gitignored config.sh — nothing machine-specific is kept in the code.
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ config.sh not found."
    echo "   Copy config.sh.example to config.sh and fill in the values,"
    echo "   or restore the filled-in copy from the Credentials folder."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

readonly VERSION="1.0.0"
START_TIME=$(date +%s)
readonly START_TIME

readonly LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H-%M-%S).log"
readonly LOG_FILE

readonly APPS_DIR="$SCRIPT_DIR/apps"

# One folder per installed CasaOS app. Used to detect already-installed
# apps: the CLI's list omits apps in some states (e.g. vaultwarden while
# listed as unknown), but the folder is always present.
readonly APPS_STATE_DIR="/var/lib/casaos/apps"

########################################
# Configuration validation
########################################

readonly REQUIRED_VARIABLES=(
    APPDATA_ROOT
    DATA4TB_MOUNT
    IMMICH_GALLERY_DIR
    NEXTCLOUD_DATA_DIR
    JELLYFIN_MEDIA_DIR
    QBITTORRENT_DOWNLOADS_DIR
    SERVER_IP
    TZ
    PUID
    PGID
    PIHOLE_WEB_PASSWORD
    POSTGRESQL_DB
    POSTGRESQL_USER
    POSTGRESQL_PASSWORD
    IMMICH_DB_PASSWORD
)

MISSING_VARIABLES=()

for variable in "${REQUIRED_VARIABLES[@]}"; do
    if [[ -z "${!variable:-}" ]]; then
        MISSING_VARIABLES+=("$variable")
    fi
done

if [[ ${#MISSING_VARIABLES[@]} -gt 0 ]]; then
    echo "❌ Missing values in config.sh:"
    for variable in "${MISSING_VARIABLES[@]}"; do
        echo "   $variable"
    done
    echo
    echo "   See config.sh.example for the full list."
    exit 1
fi

# Extra app stores are optional.
if [[ -z "${EXTRA_APP_STORES+x}" ]]; then
    EXTRA_APP_STORES=()
fi

# Variables substituted into the app files. Only these
# are rendered, so any other dollar sign in a compose
# file is left untouched. Kept single-quoted on purpose:
# envsubst receives the variable names, not the values.
# shellcheck disable=SC2016
readonly RENDER_VARIABLES='${APPDATA_ROOT} ${DATA4TB_MOUNT} ${IMMICH_GALLERY_DIR} ${NEXTCLOUD_DATA_DIR} ${JELLYFIN_MEDIA_DIR} ${QBITTORRENT_DOWNLOADS_DIR} ${SERVER_IP} ${TZ} ${PUID} ${PGID} ${PIHOLE_WEB_PASSWORD} ${POSTGRESQL_DB} ${POSTGRESQL_USER} ${POSTGRESQL_PASSWORD} ${IMMICH_DB_PASSWORD}'

export APPDATA_ROOT DATA4TB_MOUNT IMMICH_GALLERY_DIR NEXTCLOUD_DATA_DIR \
    JELLYFIN_MEDIA_DIR QBITTORRENT_DOWNLOADS_DIR SERVER_IP TZ PUID PGID \
    PIHOLE_WEB_PASSWORD POSTGRESQL_DB POSTGRESQL_USER POSTGRESQL_PASSWORD \
    IMMICH_DB_PASSWORD

########################################
# Runtime options
########################################

DRY_RUN=false
SELECTED_APPS=()

SUMMARY=()

########################################
# Functions
########################################

print_info() {
    echo "$@"

    if [[ -f "${LOG_FILE:-}" ]]; then
        echo "$@" >> "$LOG_FILE"
    fi
}

format_time() {
    local seconds="$1"

    printf "%02d:%02d:%02d\n" \
        $((seconds/3600)) \
        $(((seconds%3600)/60)) \
        $((seconds%60))
}

print_header() {
    echo
    echo "=========================================="
    echo "         ZimaOS Setup v$VERSION"
    echo "=========================================="
    echo "Mode: $([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Installation")"
    echo
}

########################################
# Prints a section header.
#
# Arguments:
#   $1 - Section title
########################################
print_section() {
    print_info
    print_info "========================================"
    print_info "$1"
    print_info "========================================"
    print_info
}

print_help() {
    cat << EOF
ZimaOS Setup v$VERSION

Installs the exported CasaOS/ZimaOS apps on this server.

Usage:
    ./setup.sh [options] [app ...]

Options:
    --dry-run           Validate every app without installing.
    --help              Show help.
    --version           Show version.

Arguments:
    app                 Only install the given apps
                        (names of files in apps/, without .yml).

Examples:
    ./setup.sh

    ./setup.sh --dry-run

    ./setup.sh jellyfin immich
EOF
}

print_version() {
    echo "$VERSION"
}

########################################
# Prints execution summary.
########################################
print_summary() {
    local elapsed="$1"

    print_section "Summary"

    for item in "${SUMMARY[@]}"; do
        IFS="|" read -r name status <<< "$item"
        print_field "$name" "$status"
    done

    print_info

    print_field "Elapsed:" "$(format_time "$elapsed")"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;

            --help)
                print_help
                exit 0
                ;;

            --version)
                print_version
                exit 0
                ;;

            -*)
                print_info "❌ Unknown argument: $1"
                echo
                echo "Run './setup.sh --help' for usage information."
                exit 1
                ;;

            *)
                if [[ ! -f "$APPS_DIR/$1.yml" ]]; then
                    print_info "❌ Unknown app: $1"
                    echo
                    echo "Available apps:"
                    for app_file in "$APPS_DIR"/*.yml; do
                        echo "  $(basename "$app_file" .yml)"
                    done
                    exit 1
                fi

                SELECTED_APPS+=("$1")
                shift
                ;;
        esac
    done
}

initialize_logging() {
    mkdir -p "$LOG_DIR"

    touch "$LOG_FILE"
}

write_log_header() {
    {
        echo "========================================"
        echo "ZimaOS Setup v$VERSION"
        echo "========================================"
        echo
        echo "Date:        $(date)"
        echo "Host:        $(hostname)"
        echo "Mode:        $([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Installation")"
        echo
        echo "========================================"
        echo
    } >> "$LOG_FILE"
}

write_log_footer() {
    local elapsed="$1"

    {
        echo
        echo "========================================"
        echo "Finished"
        echo "========================================"
        echo
        echo "Status:      SUCCESS"
        echo "Elapsed:     $(format_time "$elapsed")"
    } >> "$LOG_FILE"
}

print_field() {
    printf "%-18s %s\n" "$1" "$2"

    if [[ -f "${LOG_FILE:-}" ]]; then
        printf "%-18s %s\n" "$1" "$2" >> "$LOG_FILE"
    fi
}

print_step() {
    print_info
    print_info "▶ $1"
    print_info
}

########################################
# Handles unexpected errors.
#
# Arguments:
#   $1 - Exit code
#   $2 - Line number
#   $3 - Command
########################################
handle_error() {
    local exit_code="$1"
    local line="$2"
    local command="$3"

    echo
    print_info "❌ Setup failed!"
    echo

    print_field "Exit code:" "$exit_code"
    print_field "Line:" "$line"
    print_field "Command:" "$command"

    if [[ -f "${LOG_FILE:-}" ]]; then
        echo
        print_info "See log:"
        print_info "  $LOG_FILE"
    fi

    exit "$exit_code"
}

########################################
# Verifies the environment before touching anything:
# the CasaOS CLI must exist (we are on ZimaOS) and the
# external data drive must be mounted, otherwise Docker
# would create the bind paths as plain folders on the
# internal disk.
########################################
check_environment() {
    print_step "Checking environment"

    for binary in casaos-cli envsubst mountpoint; do
        if ! command -v "$binary" > /dev/null; then
            print_info "❌ Required command not found: $binary"
            print_info "   Run this script on the ZimaOS server."
            exit 1
        fi
    done

    print_info "✅ casaos-cli available"

    if mountpoint -q "$DATA4TB_MOUNT"; then
        print_info "✅ External drive mounted at $DATA4TB_MOUNT"
    elif [[ "$DRY_RUN" == true ]]; then
        print_info "⚠️ $DATA4TB_MOUNT is not a mounted drive (ignored in dry-run)"
    else
        print_info "❌ $DATA4TB_MOUNT is not a mounted drive."
        print_info "   Connect and mount the external data drive first, or"
        print_info "   point DATA4TB_MOUNT in config.sh to the right path."
        exit 1
    fi

    SUMMARY+=("Environment|✅ Ready")
}

########################################
# Registers the extra app stores from config.sh,
# skipping the ones already registered.
########################################
register_app_stores() {
    print_step "Registering app stores"

    if [[ ${#EXTRA_APP_STORES[@]} -eq 0 ]]; then
        print_info "⏭️ No extra app stores configured"
        SUMMARY+=("App stores|⏭️ None configured")
        return 0
    fi

    local registered_stores
    registered_stores="$(casaos-cli app-management list app-stores 2>/dev/null || true)"

    local registered_count=0

    for store_url in "${EXTRA_APP_STORES[@]}"; do
        if grep -qF "$store_url" <<< "$registered_stores"; then
            print_info "⏭️ Already registered: $store_url"
            continue
        fi

        if [[ "$DRY_RUN" == true ]]; then
            print_info "➜ casaos-cli app-management register app-store $store_url"
        else
            print_info "Registering $store_url"
            casaos-cli app-management register app-store "$store_url" >> "$LOG_FILE" 2>&1
        fi

        registered_count=$((registered_count + 1))
    done

    if [[ $registered_count -eq 0 ]]; then
        SUMMARY+=("App stores|⏭️ Already registered")
    else
        SUMMARY+=("App stores|✅ $registered_count registered")
    fi
}

########################################
# Checks whether a compose app is already installed.
#
# Arguments:
#   $1 - App name
########################################
is_app_installed() {
    [[ -d "$APPS_STATE_DIR/$1" ]]
}

########################################
# Renders an app file, substituting only the variables
# in RENDER_VARIABLES, and installs it with casaos-cli.
#
# Arguments:
#   $1 - Path to the templated app file
########################################
install_app() {
    local app_file="$1"
    local app_name
    app_name="$(basename "$app_file" .yml)"

    if is_app_installed "$app_name"; then
        print_info "⏭️ $app_name is already installed"
        SUMMARY+=("$app_name|⏭️ Already installed")
        return 0
    fi

    local rendered_file="$RENDER_DIR/$app_name.yml"
    envsubst "$RENDER_VARIABLES" < "$app_file" > "$rendered_file"

    if [[ "$DRY_RUN" == true ]]; then
        print_info "➜ casaos-cli app-management install --dry-run -f apps/$app_name.yml"
        casaos-cli app-management install --dry-run -f "$rendered_file" >> "$LOG_FILE" 2>&1
        print_info "✅ $app_name validated"
        SUMMARY+=("$app_name|✅ Validated")
        return 0
    fi

    print_info "Installing $app_name"
    casaos-cli app-management install -f "$rendered_file" >> "$LOG_FILE" 2>&1

    print_info "✅ $app_name install started"
    SUMMARY+=("$app_name|✅ Install started")
}

########################################
# Installs every exported app, or only the ones passed
# on the command line.
########################################
install_apps() {
    print_step "Installing apps"

    RENDER_DIR="$(mktemp -d)"
    trap 'rm -rf "$RENDER_DIR"' EXIT

    if [[ ${#SELECTED_APPS[@]} -gt 0 ]]; then
        for app_name in "${SELECTED_APPS[@]}"; do
            install_app "$APPS_DIR/$app_name.yml"
        done
        return 0
    fi

    for app_file in "$APPS_DIR"/*.yml; do
        install_app "$app_file"
    done
}

########################################
# Main
########################################
main() {
    parse_arguments "$@"

    initialize_logging
    write_log_header
    print_header

    check_environment
    register_app_stores
    install_apps

    local elapsed=$(( $(date +%s) - START_TIME ))

    print_summary "$elapsed"
    write_log_footer "$elapsed"

    print_info
    print_info "🎉 Done! Installs continue in the background while images"
    print_info "   are pulled — watch the progress in the ZimaOS web UI."
    print_info "   Then restore app data with homelab-backup's restore.sh."
}

main "$@"
