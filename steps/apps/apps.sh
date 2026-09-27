#!/usr/bin/env bash
#
# CasaOS apps exported to compose/ by export.sh, installed
# with their customizations (ports, volume paths,
# environment) rendered from config.sh. Each app is its own
# step in the summary.
#

readonly APPS_STEP_DIR="${BASH_SOURCE[0]%/*}"

# Absolute path of the Immich system config file, mounted
# into immich-server (see immich-config.yml). Computed from
# the repo location rather than kept in config.sh since it
# isn't a per-machine value. export.sh templates it back.
IMMICH_CONFIG_PATH="$(cd "$APPS_STEP_DIR" && pwd)/immich-config.yml"
readonly IMMICH_CONFIG_PATH

# Variables substituted into the app files. Only these
# are rendered (envsubst receives their names as its
# shell format), so any other dollar sign in a compose
# file is left untouched.
readonly APP_RENDER_VARIABLES=(
    APPDATA_ROOT
    DATA4TB_MOUNT
    IMMICH_GALLERY_DIR
    IMMICH_CONFIG_PATH
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
    ROMM_DB_PASSWORD
    ROMM_DB_ROOT_PASSWORD
    ROMM_IGDB_CLIENT_ID
    ROMM_IGDB_CLIENT_SECRET
)

# Renders an app file to standard output, substituting only
# the variables in APP_RENDER_VARIABLES.
render_app_file() {
    local app_name="$1"
    local variable
    local shell_format=""

    for variable in "${APP_RENDER_VARIABLES[@]}"; do
        shell_format+="\${$variable} "
    done

    (
        # shellcheck disable=SC2163
        for variable in "${APP_RENDER_VARIABLES[@]}"; do
            export "$variable"
        done

        envsubst "$shell_format" < "$APPS_COMPOSE_DIR/$app_name.yml"
    )
}

# Installs one app, unless it is already installed.
#
# Arguments:
#   $1 - App name (file name in compose/, without .yml)
install_app() {
    local app_name="$1"
    local rendered_file

    if is_app_installed "$app_name"; then
        skip_step "Already installed"
        return 0
    fi

    # A missing file would make Docker bind-mount an empty directory
    # onto immich-server's expected config *file* path instead, which
    # fails the container rather than just skipping the config.
    if [[ "$app_name" == immich && ! -f "$IMMICH_CONFIG_PATH" ]]; then
        abort "$IMMICH_CONFIG_PATH not found — it is part of this repository."
    fi

    rendered_file="$(make_work_dir "$app_name")/$app_name.yml"
    render_app_file "$app_name" > "$rendered_file"

    if is_dry_run; then
        # Validates the app through the CasaOS API without installing it.
        print_info "➜ casaos-cli app-management install --dry-run -f compose/$app_name.yml"
        casaos-cli app-management install --dry-run -f "$rendered_file" >> "$LOG_FILE" 2>&1
        complete_step "Validated"
        return 0
    fi

    print_info "➜ casaos-cli app-management install -f compose/$app_name.yml"
    casaos-cli app-management install -f "$rendered_file" >> "$LOG_FILE" 2>&1

    # The install continues in the background while the images are pulled.
    complete_step "Install started"
}
