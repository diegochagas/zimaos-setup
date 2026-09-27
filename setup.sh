#!/usr/bin/env bash
#
# ZimaOS Setup
#
# Post-install setup for the ZimaOS home server. Runs on
# the server itself. The shared helpers live in lib/, each
# setup step lives in its own file under steps/, and
# run_setup_steps below lists the steps in execution order.
#

set -Eeuo pipefail

readonly VERSION="1.1.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

########################################
# Configuration
########################################

# shellcheck source-path=SCRIPTDIR

source "$SCRIPT_DIR/lib/config.sh"

load_config

require_config_values \
    APPDATA_ROOT \
    DATA4TB_MOUNT \
    IMMICH_GALLERY_DIR \
    NEXTCLOUD_DATA_DIR \
    JELLYFIN_MEDIA_DIR \
    QBITTORRENT_DOWNLOADS_DIR \
    SERVER_IP \
    TZ \
    PUID \
    PGID \
    PIHOLE_WEB_PASSWORD \
    POSTGRESQL_DB \
    POSTGRESQL_USER \
    POSTGRESQL_PASSWORD \
    IMMICH_DB_PASSWORD \
    ROMM_DB_PASSWORD \
    ROMM_DB_ROOT_PASSWORD \
    ROMM_IGDB_CLIENT_ID \
    ROMM_IGDB_CLIENT_SECRET

########################################
# Libraries and steps
########################################

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/exec.sh"
source "$SCRIPT_DIR/lib/step.sh"
source "$SCRIPT_DIR/lib/casaos.sh"
source "$SCRIPT_DIR/lib/preflight.sh"

source "$SCRIPT_DIR/steps/app-stores.sh"
source "$SCRIPT_DIR/steps/apps/apps.sh"
source "$SCRIPT_DIR/steps/withoutbg/withoutbg.sh"
source "$SCRIPT_DIR/steps/docker-dns.sh"
source "$SCRIPT_DIR/steps/projects/projects.sh"
source "$SCRIPT_DIR/steps/sudoers.sh"
source "$SCRIPT_DIR/steps/jellyfin-tuners/jellyfin-tuners.sh"

trap 'handle_error $? "${BASH_SOURCE[0]}" $LINENO "$BASH_COMMAND"' ERR
trap 'cleanup_workspace' EXIT

########################################
# Command line
########################################

# Apps passed on the command line; empty means all of them.
SELECTED_APPS=()

print_help() {
    cat << EOF
ZimaOS Setup v$VERSION

Usage:
    ./setup.sh [options] [app ...]

Options:
    --dry-run           Validate every app without installing.
    --help              Show help.
    --version           Show version.

Arguments:
    app                 Only install the given apps (file names
                        in steps/apps/compose, without .yml),
                        skipping the server-wide steps.

Examples:
    ./setup.sh

    ./setup.sh --dry-run

    ./setup.sh jellyfin immich
EOF
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
                echo "$VERSION"
                exit 0
                ;;

            -*)
                echo "❌ Unknown argument: $1" >&2
                echo >&2
                echo "Run './setup.sh --help' for usage information." >&2
                exit 1
                ;;

            *)
                if ! app_file_exists "$1"; then
                    echo "❌ Unknown app: $1" >&2
                    echo >&2
                    echo "Available apps:" >&2
                    list_app_files | sed 's/^/  /' >&2
                    exit 1
                fi

                SELECTED_APPS+=("$1")
                shift
                ;;
        esac
    done
}

# Checks whether an app is part of this run.
app_selected() {
    local app_name

    (( ${#SELECTED_APPS[@]} == 0 )) && return 0

    for app_name in "${SELECTED_APPS[@]}"; do
        [[ "$app_name" == "$1" ]] && return 0
    done

    return 1
}

########################################
# Steps, in execution order
########################################

run_setup_steps() {
    local app_name

    run_step configure "App Stores"          configure_app_stores

    for app_name in $(list_app_files); do
        app_selected "$app_name" || continue
        run_step install "$app_name"         install_app "$app_name"
    done

    # Server-wide steps only run on a full setup, not when
    # installing selected apps.
    if (( ${#SELECTED_APPS[@]} == 0 )); then
        run_step install   "withoutBG"            install_withoutbg
        run_step configure "Docker DNS"           configure_docker_dns
        run_step configure "Projects"             configure_projects
        run_step configure "Project Stacks"       configure_project_stacks
        run_step configure "Sudoers Rules"        configure_sudoers
        run_step configure "Homelab Backup Timer" configure_homelab_backup_timer
    fi

    if app_selected jellyfin; then
        run_step configure "Jellyfin Live TV"     configure_jellyfin_tuners
    fi
}

########################################
# Main
########################################

main() {
    parse_arguments "$@"

    initialize_log
    initialize_workspace

    write_log_header
    print_banner

    run_preflight_checks
    run_setup_steps

    print_section "Setup complete!"
    print_summary

    write_log_footer

    print_info
    print_info "🎉 Installs continue in the background while images are"
    print_info "   pulled — watch the progress in the ZimaOS web UI. Then"
    print_info "   restore app data with homelab-backup's restore.sh."
}

main "$@"
