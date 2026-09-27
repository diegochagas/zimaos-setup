#!/usr/bin/env bash
#
# Checks that run before any step: required commands
# (we are on ZimaOS), administrator privileges and the
# external data drive.
#

readonly REQUIRED_COMMANDS=(
    casaos-cli
    envsubst
    mountpoint
    docker
    sudo
)

check_dependencies() {
    local command
    local missing=()

    print_info "Checking dependencies..."

    for command in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$command" > /dev/null 2>&1; then
            missing+=("$command")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        print_info "❌ Missing required commands:"
        for command in "${missing[@]}"; do
            print_info "  • $command"
        done
        print_info
        abort "Run this script on the ZimaOS server."
    fi

    print_info "✅ Dependencies OK"
    print_info
}

# Asks for the sudo password up front, so later steps
# (Jellyfin Live TV) don't stop halfway to prompt for it.
check_sudo() {
    print_info "Checking administrator privileges..."

    if is_dry_run; then
        print_info "⏭️ Skipped (dry-run)"
        print_info
        return 0
    fi

    if ! sudo -v; then
        abort "Administrator privileges are required."
    fi

    print_info "✅ OK"
    print_info
}

# The external drive must be mounted, otherwise Docker would
# create the bind paths as plain folders on the internal disk
# and the apps would silently run against the wrong storage.
check_data_drive() {
    print_info "Checking external data drive..."

    if mountpoint -q "$DATA4TB_MOUNT"; then
        print_info "✅ Mounted at $DATA4TB_MOUNT"
    elif is_dry_run; then
        print_info "⚠️ $DATA4TB_MOUNT is not a mounted drive (ignored in dry-run)"
    else
        print_info "❌ $DATA4TB_MOUNT is not a mounted drive."
        print_info "   Connect and mount the external data drive first, or"
        print_info "   point DATA4TB_MOUNT in config.sh to the right path."
        exit 1
    fi

    print_info
}

run_preflight_checks() {
    print_section "Initialization"

    check_dependencies
    check_sudo
    check_data_drive
}
