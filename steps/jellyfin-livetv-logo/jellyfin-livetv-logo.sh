#!/usr/bin/env bash
#
# Jellyfin Live TV logo: installs livetv-logo.sh as a
# systemd service that keeps the Live TV tile's image set to
# the logo of the last channel watched.
#
# The unit goes in /etc/systemd/system, which persists across
# ZimaOS updates, and runs the script from this checkout as
# the user running the setup (it only talks to Jellyfin's
# API, with JELLYFIN_API_KEY from config.sh).
#

LIVETV_LOGO_SCRIPT="$(cd "${BASH_SOURCE[0]%/*}" && pwd)/livetv-logo.sh"
readonly LIVETV_LOGO_SCRIPT
readonly LIVETV_LOGO_SERVICE="jellyfin-livetv-logo.service"
readonly LIVETV_LOGO_UNIT="/etc/systemd/system/$LIVETV_LOGO_SERVICE"

livetv_logo_unit() {
    cat << EOF
[Unit]
Description=Jellyfin Live TV tile shows the last watched channel's logo
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=$(id -un)
ExecStart=$LIVETV_LOGO_SCRIPT
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}

livetv_logo_configured() {
    livetv_logo_unit | cmp -s - "$LIVETV_LOGO_UNIT" &&
        systemctl is-enabled "$LIVETV_LOGO_SERVICE" > /dev/null 2>&1 &&
        systemctl is-active "$LIVETV_LOGO_SERVICE" > /dev/null 2>&1
}

configure_jellyfin_livetv_logo() {
    if [[ -z "${JELLYFIN_URL:-}" || -z "${JELLYFIN_API_KEY:-}" ]]; then
        skip_step "JELLYFIN_URL or JELLYFIN_API_KEY not set"
        return 0
    fi

    if livetv_logo_configured; then
        skip_step "Already configured"
        return 0
    fi

    livetv_logo_unit | write_root_file "$LIVETV_LOGO_UNIT"
    run sudo systemctl daemon-reload
    run sudo systemctl enable "$LIVETV_LOGO_SERVICE"
    # Restart, not start: picks up a changed unit or script.
    run sudo systemctl restart "$LIVETV_LOGO_SERVICE"
}
