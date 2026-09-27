#!/usr/bin/env bash
#
# Terminal output and log file.
#
# Messages printed with the print_* functions go to the
# terminal and, once the log file exists, to the log file.
#

START_TIME="$(date +%s)"
readonly START_TIME

readonly LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H-%M-%S).log"
readonly LOG_FILE

initialize_log() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
}

# Appends a line to the log file, if it exists.
log() {
    if [[ -f "$LOG_FILE" ]]; then
        printf '%s\n' "$*" >> "$LOG_FILE"
    fi
}

# Prints a line to the terminal and the log file.
print_info() {
    printf '%s\n' "$*"
    log "$*"
}

# Prints a label and a value in aligned columns.
print_field() {
    local line

    printf -v line '%-20s %s' "$1" "$2"
    print_info "$line"
}

print_section() {
    print_info
    print_info "========================================"
    print_info "$1"
    print_info "========================================"
    print_info
}

print_step() {
    print_info
    print_info "▶ $1"
    print_info
}

# Prints the terminal banner. Not logged: the log has its own header.
print_banner() {
    echo
    echo "=========================================="
    echo "         ZimaOS Setup v$VERSION"
    echo "=========================================="
    echo "Mode: $(run_mode_label)"
    echo
}

elapsed_seconds() {
    echo $(( $(date +%s) - START_TIME ))
}

# Formats a number of seconds as HH:MM:SS.
format_time() {
    local seconds="$1"

    printf '%02d:%02d:%02d\n' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}

write_log_header() {
    {
        echo "========================================"
        echo "ZimaOS Setup v$VERSION"
        echo "========================================"
        echo
        echo "Date:        $(date)"
        echo "Host:        $(hostname)"
        echo "Mode:        $(run_mode_label)"
        echo
        echo "========================================"
        echo
    } >> "$LOG_FILE"
}

write_log_footer() {
    {
        echo
        echo "========================================"
        echo "Finished"
        echo "========================================"
        echo
        echo "Status:      SUCCESS"
        echo "Elapsed:     $(format_time "$(elapsed_seconds)")"
    } >> "$LOG_FILE"
}
