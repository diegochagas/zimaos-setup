#!/usr/bin/env bash
#
# withoutBG: the self-hosted background removal API and web
# editor used by the GIMP plug-in (see docker-compose.yml).
# Not an App Store app, so it runs as a plain compose
# project rather than through casaos-cli.
#

readonly WITHOUTBG_COMPOSE_FILE="${BASH_SOURCE[0]%/*}/docker-compose.yml"

# Checks whether a container with this exact name exists,
# running or not.
container_exists() {
    [[ -n "$(sudo docker ps -aq --filter "name=^$1\$")" ]]
}

install_withoutbg() {
    skip_in_dry_run_without_sudo || return 0

    if container_exists withoutbg-service && container_exists withoutbg; then
        skip_step "Already installed"
        return 0
    fi

    # Compose can't adopt a container it didn't create.
    if container_exists withoutbg-service || container_exists withoutbg; then
        warn_step "Only one container exists — remove it and run again"
        return 0
    fi

    run sudo docker compose -f "$WITHOUTBG_COMPOSE_FILE" up -d
}
