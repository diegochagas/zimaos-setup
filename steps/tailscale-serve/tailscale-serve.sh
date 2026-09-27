#!/usr/bin/env bash
#
# Tailscale HTTPS: publishes the apps listed in serve.txt at
# https://<server>.<tailnet>.ts.net[:port], reachable only from
# devices in the tailnet, with `tailscale serve`. Tailscale
# issues and renews the certificates.
#
# Why: some apps only work on a secure page and the LAN address
# is plain HTTP — Vaultwarden's web vault and clients, and RomM's
# web player for the cores that need threads (PSP, MS-DOS).
#
# The rules are kept in Tailscale's state (AppData), so they
# also come back with the backup restore; this step adds the
# ones that are missing and leaves every other rule alone.
# Tailscale runs in a container and docker needs root, so the
# checks and the changes run with sudo.
#

readonly TAILSCALE_SERVE_FILE="${BASH_SOURCE[0]%/*}/serve.txt"
readonly TAILSCALE_CONTAINER="tailscale"

# Runs the tailscale CLI inside the Tailscale container.
tailscale_cli() {
    sudo docker exec "$TAILSCALE_CONTAINER" tailscale "$@"
}

tailscale_container_running() {
    [[ "$(sudo docker inspect -f '{{.State.Running}}' "$TAILSCALE_CONTAINER" 2> /dev/null)" == "true" ]]
}

# Prints the server's name in the tailnet, or nothing while
# Tailscale is not logged in.
tailscale_dns_name() {
    tailscale_cli status --json 2> /dev/null |
        jq -r 'select(.BackendState == "Running") | .Self.DNSName // empty | rtrimstr(".")'
}

# Prints the Web UI port of an app, read from its app file.
app_web_port() {
    sed -n 's/^[[:space:]]*port_map:[[:space:]]*"\{0,1\}\([0-9]\{1,5\}\)"\{0,1\}[[:space:]]*$/\1/p' \
        "$APPS_COMPOSE_DIR/$1.yml" | head -n 1
}

# Checks whether the serve configuration (JSON on standard
# input) already forwards an HTTPS port to a local port.
#
# Arguments:
#   $1 - HTTPS port
#   $2 - Local port
serve_rule_configured() {
    jq -e --arg port "$1" --arg target "http://127.0.0.1:$2" '
        (.TCP[$port].HTTPS == true) and
        any(
            (.Web // {}) | to_entries[];
            (.key | endswith(":" + $port)) and (.value.Handlers["/"].Proxy == $target)
        )
    ' > /dev/null 2>&1
}

# Prints the address a rule is published at.
#
# Arguments:
#   $1 - Server name in the tailnet
#   $2 - HTTPS port
serve_rule_url() {
    if [[ "$2" == "443" ]]; then
        echo "https://$1"
    else
        echo "https://$1:$2"
    fi
}

configure_tailscale_serve() {
    local dns_name
    local serve_config
    local https_port
    local app_name
    local local_port
    local changes=0
    local skipped=0

    skip_in_dry_run_without_sudo || return 0

    if ! tailscale_container_running; then
        skip_step "Tailscale is not running — install it and run again"
        return 0
    fi

    dns_name="$(tailscale_dns_name || true)"

    if [[ -z "$dns_name" ]]; then
        skip_step "Tailscale is not logged in — log in (port 5252) and run again"
        return 0
    fi

    serve_config="$(tailscale_cli serve status --json)"

    while IFS="|" read -r https_port app_name; do
        [[ -z "$https_port" || "$https_port" == \#* ]] && continue

        if ! app_file_exists "$app_name"; then
            abort "serve.txt: unknown app \"$app_name\""
        fi

        local_port="$(app_web_port "$app_name")"

        if [[ -z "$local_port" ]]; then
            abort "serve.txt: no port_map in $app_name.yml"
        fi

        if ! is_app_installed "$app_name"; then
            print_info "⏭️ Not installed: $app_name"
            skipped=$((skipped + 1))
            continue
        fi

        if serve_rule_configured "$https_port" "$local_port" <<< "$serve_config"; then
            print_info "⏭️ Already published: $app_name at $(serve_rule_url "$dns_name" "$https_port")"
            continue
        fi

        # Fails when HTTPS certificates are not enabled for the
        # tailnet (admin console > DNS > HTTPS Certificates).
        run tailscale_cli serve --bg "--https=$https_port" "http://127.0.0.1:$local_port" < /dev/null
        print_info "✅ $app_name at $(serve_rule_url "$dns_name" "$https_port")"

        changes=$((changes + 1))
    done < "$TAILSCALE_SERVE_FILE"

    if (( changes == 0 && skipped > 0 )); then
        skip_step "Apps not installed yet"
    elif (( changes == 0 )); then
        skip_step "All addresses published"
    fi
}
