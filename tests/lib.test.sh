#!/usr/bin/env bash
#
# Tests of the test runner itself: a runner that lets a
# failing test pass makes every other test worthless.
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT_DIR

# shellcheck source-path=SCRIPTDIR/..
source "$SCRIPT_DIR/tests/lib.sh"

# Runs a test file made of the given lines and prints what
# the runner printed, followed by its exit code.
run_test_file() {
    local status=0

    bash -c "source '$SCRIPT_DIR/tests/lib.sh'; $1; run_tests" 2>&1 || status=$?
    echo "exit: $status"
}

test_passing_test_is_reported_as_passed() {
    local result

    result="$(run_test_file 'test_ok() { assert_equal a a "value"; }')"

    assert_match "✅ test_ok" "$result" "runner output"
    assert_match "exit: 0$" "$result" "runner exit code"
}

test_failing_test_fails_the_run() {
    local result

    result="$(run_test_file 'test_bad() { assert_equal a b "value"; }')"

    assert_match "❌ test_bad" "$result" "runner output"
    assert_match "exit: 1$" "$result" "runner exit code"
}

test_failed_assert_followed_by_a_passing_one_still_fails() {
    local result

    result="$(run_test_file 'test_bad() { assert_equal a b "first"; assert_equal a a "second"; }')"

    assert_match "❌ test_bad" "$result" "runner output"
    assert_match "exit: 1$" "$result" "runner exit code"
}

test_failing_command_fails_the_test() {
    local result

    result="$(run_test_file 'test_bad() { false; assert_equal a a "value"; }')"

    assert_match "❌ test_bad" "$result" "runner output"
}

test_one_test_does_not_change_the_next() {
    local result

    # The test file's own code: expanded by the bash that runs it.
    # shellcheck disable=SC2016
    result="$(run_test_file 'VALUE=before; test_a_changes() { VALUE=after; }; test_b_reads() { assert_equal before "$VALUE" "value"; }')"

    assert_match "exit: 0$" "$result" "runner exit code"
}

run_tests
