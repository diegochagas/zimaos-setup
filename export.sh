#!/usr/bin/env bash

set -Eeuo pipefail

########################################
# ZimaOS app export
#
# Snapshots every installed CasaOS/ZimaOS app into
# apps/<name>.yml, replacing machine-specific paths and
# secrets with the ${VARIABLES} defined in config.sh so
# the result is safe to commit.
#
# Runs on the ZimaOS server itself. Re-run it after
# installing or reconfiguring apps in the web UI, then
# review and commit the changes.
########################################

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

readonly APPS_DIR="$SCRIPT_DIR/apps"

# Must match the same computation in setup.sh.
readonly IMMICH_CONFIG_PATH="$SCRIPT_DIR/config/immich.yml"
readonly API_URL_FILE="/var/run/casaos/app-management.url"

# One folder per installed CasaOS app. This is the source of the app
# names: the list endpoints of the API omit apps in some states (e.g.
# vaultwarden while listed as unknown), and this folder never includes
# the self-managed compose projects from /DATA/Projects.
readonly APPS_STATE_DIR="/var/lib/casaos/apps"

########################################
# Configuration validation
#
# The reverse-templating rules only need the paths and
# container environment values — the secret variables are
# matched by key, not by value.
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

########################################
# Functions
########################################

########################################
# Fetches the installed compose file of an app from the
# local app-management API.
#
# Arguments:
#   $1 - App name
########################################
fetch_app() {
    curl -fs -H "Accept: application/yaml" \
        "$API_BASE_URL/v2/app_management/compose/$1"
}

########################################
# Replaces machine-specific values with the config
# variables. App-specific secrets are handled per app.
#
# Arguments:
#   $1 - App name
########################################
template_app() {
    local app_name="$1"

    sed \
        -e "s|source: $IMMICH_GALLERY_DIR\$|source: \${IMMICH_GALLERY_DIR}|" \
        -e "s|source: $NEXTCLOUD_DATA_DIR\$|source: \${NEXTCLOUD_DATA_DIR}|" \
        -e "s|source: $JELLYFIN_MEDIA_DIR\$|source: \${JELLYFIN_MEDIA_DIR}|" \
        -e "s|source: $QBITTORRENT_DOWNLOADS_DIR\$|source: \${QBITTORRENT_DOWNLOADS_DIR}|" \
        -e "s|source: $DATA4TB_MOUNT/|source: \${DATA4TB_MOUNT}/|" \
        -e "s|source: $APPDATA_ROOT/|source: \${APPDATA_ROOT}/|" \
        -e "s|hostname: $SERVER_IP\$|hostname: \${SERVER_IP}|" \
        -e "s|TZ: $TZ\$|TZ: \${TZ}|" \
        -e "s|PUID: \"$PUID\"\$|PUID: \"\${PUID}\"|" \
        -e "s|PGID: \"$PGID\"\$|PGID: \"\${PGID}\"|" \
    | case "$app_name" in
        pihole)
            sed "s|FTLCONF_webserver_api_password: .*|FTLCONF_webserver_api_password: \${PIHOLE_WEB_PASSWORD}|"
            ;;

        postgresql)
            sed \
                -e "s|POSTGRES_DB: .*|POSTGRES_DB: \${POSTGRESQL_DB}|" \
                -e "s|POSTGRES_USER: .*|POSTGRES_USER: \${POSTGRESQL_USER}|" \
                -e "s|POSTGRES_PASSWORD: .*|POSTGRES_PASSWORD: \${POSTGRESQL_PASSWORD}|"
            ;;

        immich)
            sed \
                -e "s|POSTGRES_PASSWORD: .*|POSTGRES_PASSWORD: \${IMMICH_DB_PASSWORD}|" \
                -e "s|DB_PASSWORD: .*|DB_PASSWORD: \${IMMICH_DB_PASSWORD}|" \
                -e "s|source: $IMMICH_CONFIG_PATH\$|source: \${IMMICH_CONFIG_PATH}|"
            ;;

        romm)
            sed \
                -e "s|DB_PASSWD: .*|DB_PASSWD: \${ROMM_DB_PASSWORD}|" \
                -e "s|MARIADB_PASSWORD: .*|MARIADB_PASSWORD: \${ROMM_DB_PASSWORD}|" \
                -e "s|MARIADB_ROOT_PASSWORD: .*|MARIADB_ROOT_PASSWORD: \${ROMM_DB_ROOT_PASSWORD}|" \
                -e "s|IGDB_CLIENT_ID: .*|IGDB_CLIENT_ID: \${ROMM_IGDB_CLIENT_ID}|" \
                -e "s|IGDB_CLIENT_SECRET: .*|IGDB_CLIENT_SECRET: \${ROMM_IGDB_CLIENT_SECRET}|"
            ;;

        *)
            cat
            ;;
    esac
}

########################################
# Main
########################################
main() {
    if [[ ! -f "$API_URL_FILE" ]]; then
        echo "❌ $API_URL_FILE not found."
        echo "   Run this script on the ZimaOS server."
        exit 1
    fi

    API_BASE_URL="$(cat "$API_URL_FILE")"
    readonly API_BASE_URL

    mkdir -p "$APPS_DIR"

    local app_names
    app_names="$(ls "$APPS_STATE_DIR")"

    local exported=0
    local skipped=0

    for app_name in $app_names; do
        local compose_yaml
        if ! compose_yaml="$(fetch_app "$app_name")" \
            || [[ "$compose_yaml" != name:* ]]; then
            echo "⏭️ $app_name (could not fetch its compose file)"
            skipped=$((skipped + 1))
            continue
        fi

        template_app "$app_name" <<< "$compose_yaml" > "$APPS_DIR/$app_name.yml"

        echo "✅ $app_name"
        exported=$((exported + 1))
    done

    echo
    echo "Exported $exported apps to apps/ ($skipped skipped)."

    if command -v git > /dev/null && git -C "$SCRIPT_DIR" rev-parse 2>/dev/null; then
        echo
        echo "Changes:"
        git -C "$SCRIPT_DIR" status --short "$APPS_DIR" || true
        echo
        echo "⚠️ Review the diff before committing — a new app or a changed"
        echo "   value may contain a secret that still needs a variable in"
        echo "   config.sh and a rule in template_app()."
    fi
}

main "$@"
