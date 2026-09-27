#!/usr/bin/env bash
#
# Docker DNS: sets the "dns" servers in /etc/docker/daemon.json
# (DOCKER_DNS_SERVERS in config.sh), keeping any other key.
#
# Why: the host resolves through Pi-hole, a container on this
# server, which doesn't answer queries from BuildKit's build
# network, so `docker compose build` steps that need the network
# (apk add, npm ci, ...) fail with DNS errors. Plain containers
# are unaffected. /etc persists across ZimaOS updates.
#

readonly DOCKER_DAEMON_JSON="/etc/docker/daemon.json"

if [[ -z "${DOCKER_DNS_SERVERS+x}" ]]; then
    DOCKER_DNS_SERVERS=()
fi

# Prints daemon.json with "dns" set to DOCKER_DNS_SERVERS.
docker_daemon_json() {
    local current="{}"

    if [[ -s "$DOCKER_DAEMON_JSON" ]]; then
        current="$(cat "$DOCKER_DAEMON_JSON")"
    fi

    jq --args '.dns = $ARGS.positional' "${DOCKER_DNS_SERVERS[@]}" <<< "$current"
}

docker_dns_configured() {
    [[ -s "$DOCKER_DAEMON_JSON" ]] &&
        jq -e --args '.dns == $ARGS.positional' "${DOCKER_DNS_SERVERS[@]}" \
            < "$DOCKER_DAEMON_JSON" > /dev/null 2>&1
}

configure_docker_dns() {
    if (( ${#DOCKER_DNS_SERVERS[@]} == 0 )); then
        skip_step "DOCKER_DNS_SERVERS not set"
        return 0
    fi

    if docker_dns_configured; then
        skip_step "Already configured"
        return 0
    fi

    docker_daemon_json | write_root_file "$DOCKER_DAEMON_JSON"

    # Restarting the daemon restarts every container; the apps
    # come back on their own (restart: unless-stopped).
    run sudo systemctl restart docker
}
