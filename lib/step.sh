#!/usr/bin/env bash
#
# Setup steps and the execution summary.
#
# A step is a function that installs or configures one
# thing. run_step prints the step header, calls the
# function and records the result in the summary. A step
# that ends early calls skip_step or warn_step; a step
# that returns without doing so is recorded as installed
# or configured.
#

SUMMARY=()

CURRENT_STEP_STATUS=""

# Runs a setup step.
#
# Arguments:
#   $1 - Action: install or configure
#   $2 - Display name, used in the header and the summary
#   $3 - Step function
#   $@ - Extra arguments passed to the step function
run_step() {
    local action="$1"
    local name="$2"
    local handler="$3"
    shift 3

    CURRENT_STEP_STATUS=""

    print_step "$(action_in_progress "$action") $name"

    "$handler" "$@"

    if [[ -z "$CURRENT_STEP_STATUS" ]]; then
        CURRENT_STEP_STATUS="$(action_completed "$action")"
    fi

    SUMMARY+=("$name|$CURRENT_STEP_STATUS")
}

# Records the current step as skipped, with a reason.
skip_step() {
    print_info "⏭️ $1"
    CURRENT_STEP_STATUS="⏭️ $1"
}

# Records the current step as not completed, with a reason.
warn_step() {
    print_info "⚠️ $1"
    CURRENT_STEP_STATUS="⚠️ $1"
}

# Records the current step as done, with a custom status.
complete_step() {
    print_info "✅ $1"
    CURRENT_STEP_STATUS="✅ $1"
}

action_in_progress() {
    case "$1" in
        install) echo "Installing" ;;
        configure) echo "Configuring" ;;
    esac
}

action_completed() {
    case "$1" in
        install)
            if is_dry_run; then echo "🔄 Would install"; else echo "✅ Installed"; fi
            ;;
        configure)
            if is_dry_run; then echo "🔄 Would configure"; else echo "✅ Configured"; fi
            ;;
    esac
}

print_summary() {
    local item
    local name
    local status

    print_section "Summary"

    for item in "${SUMMARY[@]}"; do
        IFS="|" read -r name status <<< "$item"
        print_field "$name" "$status"
    done

    print_info

    print_field "Elapsed:" "$(format_time "$(elapsed_seconds)")"
}
