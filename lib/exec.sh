#!/usr/bin/env bash
#
# Command execution, dry-run mode, temporary files and
# error handling.
#
# Every action that changes the server goes through run or
# write_root_file, so that --dry-run can print the action
# instead of executing it.
#

DRY_RUN=false

# Root of the temporary directories created by make_work_dir.
WORK_ROOT=""

is_dry_run() {
    [[ "$DRY_RUN" == true ]]
}

run_mode_label() {
    if is_dry_run; then
        echo "Simulation"
    else
        echo "Installation"
    fi
}

# Prints a command and executes it, unless in dry-run mode.
run() {
    local command

    printf -v command '%q ' "$@"
    print_info "➜ ${command% }"

    if is_dry_run; then
        return 0
    fi

    "$@"
}

# Writes standard input to a file as root. An existing
# file keeps its owner and mode.
write_root_file() {
    local target="$1"

    print_info "➜ Write $target (as root)"

    if is_dry_run; then
        cat > /dev/null
        return 0
    fi

    sudo tee "$target" > /dev/null
}

initialize_workspace() {
    WORK_ROOT="$(mktemp -d -t zimaos-setup.XXXXXX)"
}

cleanup_workspace() {
    if [[ -n "$WORK_ROOT" && -d "$WORK_ROOT" ]]; then
        rm -rf "$WORK_ROOT"
    fi
}

# Prints the path of a new temporary directory. It is
# removed, with everything in it, when the setup exits.
make_work_dir() {
    mktemp -d "$WORK_ROOT/$1.XXXXXX"
}

# Prints an error message and exits.
abort() {
    print_info "❌ $*"
    exit 1
}

# ERR trap handler.
#
# Arguments:
#   $1 - Exit code
#   $2 - Source file of the failing command
#   $3 - Line number
#   $4 - Command
handle_error() {
    local exit_code="$1"
    local source_file="$2"
    local line="$3"
    local command="$4"

    print_info
    print_info "❌ Setup failed!"
    print_info

    print_field "Exit code:" "$exit_code"
    print_field "Location:" "${source_file#"$SCRIPT_DIR/"}:$line"
    print_field "Command:" "$command"

    print_info
    print_info "See log:"
    print_info "  $LOG_FILE"

    exit "$exit_code"
}
