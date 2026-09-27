#!/usr/bin/env bash
#
# Tests of the Tailscale HTTPS step. Nothing here touches
# docker or Tailscale: sudo is replaced by a function that
# answers like the Tailscale container would and records the
# changes the step asks for.
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT_DIR

# shellcheck source-path=SCRIPTDIR/..
source "$SCRIPT_DIR/tests/lib.sh"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/exec.sh"
source "$SCRIPT_DIR/lib/step.sh"
source "$SCRIPT_DIR/lib/casaos.sh"
source "$SCRIPT_DIR/steps/tailscale-serve/tailscale-serve.sh"

########################################
# Fakes
########################################

readonly SERVER_NAME="server.example.ts.net"

CALLS_FILE="$(mktemp)"
readonly CALLS_FILE
trap 'rm -f "$CALLS_FILE"' EXIT

FAKE_RUNNING="true"
FAKE_BACKEND="Running"
FAKE_SERVE="{}"
FAKE_INSTALLED="vaultwarden romm"

# Prints a serve configuration with the given
# <https port>:<local port> rules.
serve_config() {
    local rule
    local config='{"TCP":{},"Web":{}}'

    for rule in "$@"; do
        config="$(jq -c --arg port "${rule%%:*}" --arg host "$SERVER_NAME" \
            --arg target "http://127.0.0.1:${rule##*:}" '
            .TCP[$port] = {HTTPS: true} |
            .Web[$host + ":" + $port] = {Handlers: {"/": {Proxy: $target}}}
        ' <<< "$config")"
    done

    echo "$config"
}

sudo() {
    echo "$*" >> "$CALLS_FILE"

    case "$*" in
        "docker inspect"*)
            echo "$FAKE_RUNNING"
            ;;
        "docker exec tailscale tailscale status --json")
            jq -n --arg state "$FAKE_BACKEND" --arg name "$SERVER_NAME." \
                '{BackendState: $state, Self: {DNSName: $name}}'
            ;;
        "docker exec tailscale tailscale serve status --json")
            echo "$FAKE_SERVE"
            ;;
        "docker exec tailscale tailscale serve --bg "*)
            ;;
        *)
            echo "unexpected sudo call: $*" >&2
            return 1
            ;;
    esac
}

is_app_installed() {
    [[ " $FAKE_INSTALLED " == *" $1 "* ]]
}

# Runs the step and prints the changes it asked for, one
# per line, followed by the status it recorded.
run_the_step() {
    : > "$CALLS_FILE"
    CURRENT_STEP_STATUS=""

    configure_tailscale_serve > /dev/null

    grep -o 'serve --bg .*' "$CALLS_FILE" || true
    echo "status: $CURRENT_STEP_STATUS"
}

########################################
# serve.txt and the app files
########################################

test_every_rule_names_an_app_with_a_web_port() {
    local https_port
    local app_name
    local rules=0

    while IFS="|" read -r https_port app_name; do
        [[ -z "$https_port" || "$https_port" == \#* ]] && continue

        assert_match "^(443|8443|10000)$" "$https_port" "port Tailscale can serve HTTPS on"
        assert_true "app file of $app_name" app_file_exists "$app_name"
        assert_match "^[0-9]+$" "$(app_web_port "$app_name")" "web port of $app_name"

        rules=$((rules + 1))
    done < "$TAILSCALE_SERVE_FILE"

    assert_equal "2" "$rules" "rules in serve.txt"
}

test_no_https_port_is_used_twice() {
    assert_equal "" "$(grep -v '^#' "$TAILSCALE_SERVE_FILE" | cut -d'|' -f1 | sort | uniq -d)" \
        "repeated ports"
}

test_web_port_comes_from_the_app_file() {
    assert_equal "$(grep -o 'port_map: "[0-9]*"' "$APPS_COMPOSE_DIR/romm.yml" | tr -dc 0-9)" \
        "$(app_web_port romm)" "romm"
}

########################################
# Reading the serve configuration
########################################

test_rule_is_found_in_the_configuration() {
    assert_true "matching rule" serve_rule_configured 8443 8285 <<< "$(serve_config 443:10380 8443:8285)"
}

test_rule_to_another_port_is_not_a_match() {
    assert_false "other target" serve_rule_configured 8443 8285 <<< "$(serve_config 8443:9999)"
}

test_rule_on_another_https_port_is_not_a_match() {
    assert_false "other https port" serve_rule_configured 8443 8285 <<< "$(serve_config 443:8285)"
}

test_empty_configuration_has_no_rules() {
    assert_false "empty object" serve_rule_configured 443 10380 <<< "{}"
    assert_false "no output" serve_rule_configured 443 10380 <<< ""
}

########################################
# The step
########################################

test_second_run_changes_nothing() {
    FAKE_SERVE="$(serve_config 443:"$(app_web_port vaultwarden)" 8443:"$(app_web_port romm)")"

    assert_equal "status: ⏭️ All addresses published" "$(run_the_step)" "step result"
}

test_only_the_missing_rule_is_added() {
    FAKE_SERVE="$(serve_config 443:"$(app_web_port vaultwarden)")"

    assert_equal \
        "serve --bg --https=8443 http://127.0.0.1:$(app_web_port romm)"$'\n'"status: " \
        "$(run_the_step)" "step result"
}

test_fresh_tailscale_gets_both_rules() {
    FAKE_SERVE="{}"

    assert_equal \
        "serve --bg --https=443 http://127.0.0.1:$(app_web_port vaultwarden)"$'\n'"serve --bg --https=8443 http://127.0.0.1:$(app_web_port romm)"$'\n'"status: " \
        "$(run_the_step)" "step result"
}

test_rule_pointing_elsewhere_is_repointed() {
    FAKE_SERVE="$(serve_config 443:"$(app_web_port vaultwarden)" 8443:9999)"

    assert_match "^serve --bg --https=8443 http://127.0.0.1:$(app_web_port romm)" \
        "$(run_the_step)" "step result"
}

test_app_not_installed_is_not_published() {
    FAKE_SERVE="{}"
    FAKE_INSTALLED="vaultwarden"

    assert_equal \
        "serve --bg --https=443 http://127.0.0.1:$(app_web_port vaultwarden)"$'\n'"status: " \
        "$(run_the_step)" "step result"
}

test_nothing_installed_is_a_skip() {
    FAKE_SERVE="{}"
    FAKE_INSTALLED=""

    assert_equal "status: ⏭️ Apps not installed yet" "$(run_the_step)" "step result"
}

test_stopped_tailscale_is_a_skip() {
    FAKE_RUNNING="false"

    assert_match "^status: ⏭️ Tailscale is not running" "$(run_the_step)" "step result"
}

test_logged_out_tailscale_is_a_skip() {
    FAKE_BACKEND="NeedsLogin"

    assert_match "^status: ⏭️ Tailscale is not logged in" "$(run_the_step)" "step result"
}

test_dry_run_never_calls_sudo() {
    DRY_RUN=true

    assert_match "^status: ⏭️ Needs sudo" "$(run_the_step)" "step result"
    assert_equal "" "$(cat "$CALLS_FILE")" "sudo calls"
}

test_published_address_omits_the_default_port() {
    assert_equal "https://$SERVER_NAME" "$(serve_rule_url "$SERVER_NAME" 443)" "port 443"
    assert_equal "https://$SERVER_NAME:8443" "$(serve_rule_url "$SERVER_NAME" 8443)" "port 8443"
}

run_tests
