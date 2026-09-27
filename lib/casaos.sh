#!/usr/bin/env bash
#
# CasaOS/ZimaOS app management: installed-app queries and
# the app files kept in steps/apps/compose.
#

readonly APPS_COMPOSE_DIR="$SCRIPT_DIR/steps/apps/compose"

# One folder per installed CasaOS app. Used to detect
# installed apps: the CLI's list omits apps in some states
# (e.g. vaultwarden while listed as unknown), but the
# folder is always present. It also never includes the
# self-managed compose projects from /DATA/Projects.
readonly APPS_STATE_DIR="/var/lib/casaos/apps"

is_app_installed() {
    [[ -d "$APPS_STATE_DIR/$1" ]]
}

# Checks whether an app file exists in steps/apps/compose.
app_file_exists() {
    [[ -f "$APPS_COMPOSE_DIR/$1.yml" ]]
}

# Prints the names of the app files in steps/apps/compose.
list_app_files() {
    local app_file

    for app_file in "$APPS_COMPOSE_DIR"/*.yml; do
        basename "$app_file" .yml
    done
}
