#!/usr/bin/env bash
#
# Minimal test runner, so the tests need nothing but bash.
#
# A test file defines functions named test_*, sources this
# file and ends with run_tests. Each test runs in its own
# subshell, so what one test changes (variables, fakes)
# doesn't reach the next one.
#

# Fails the test unless both values are equal.
#
# Arguments:
#   $1 - Expected value
#   $2 - Actual value
#   $3 - What is being compared
assert_equal() {
    if [[ "$1" != "$2" ]]; then
        printf '    %s\n      expected: %q\n      actual:   %q\n' "$3" "$1" "$2"
        return 1
    fi
}

# Fails the test unless the value matches the regular expression.
#
# Arguments:
#   $1 - Extended regular expression
#   $2 - Actual value
#   $3 - What is being compared
assert_match() {
    if [[ ! "$2" =~ $1 ]]; then
        printf '    %s\n      expected to match: %s\n      actual:            %q\n' "$3" "$1" "$2"
        return 1
    fi
}

# Fails the test unless the command succeeds.
#
# Arguments:
#   $1 - What is being checked
#   $@ - Command
assert_true() {
    local label="$1"
    shift

    if ! "$@"; then
        printf '    %s\n      expected to succeed: %s\n' "$label" "$*"
        return 1
    fi
}

# Fails the test unless the command fails.
#
# Arguments:
#   $1 - What is being checked
#   $@ - Command
assert_false() {
    local label="$1"
    shift

    if "$@"; then
        printf '    %s\n      expected to fail: %s\n' "$label" "$*"
        return 1
    fi
}

# Runs every test_* function and exits with 1 if any failed.
run_tests() {
    local test_name
    local output
    local status
    local failed=0
    local total=0

    for test_name in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
        total=$((total + 1))

        # Not inside an "if": bash ignores set -e there, and a
        # test would pass whenever its last assert passed.
        set +e
        output="$(set -e; "$test_name" 2>&1)"
        status=$?
        set -e

        if (( status == 0 )); then
            echo "  ✅ $test_name"
        else
            echo "  ❌ $test_name"
            [[ -n "$output" ]] && echo "$output"
            failed=$((failed + 1))
        fi
    done

    echo
    echo "  $((total - failed))/$total passed"

    (( failed == 0 ))
}
