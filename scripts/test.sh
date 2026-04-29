#!/bin/bash
# =============================================================================
# test.sh - Test cluster connectivity
#
# Purpose:
#   Ping all cluster nodes in parallel and report reachability status.
#
# Usage:
#   ./scripts/test.sh
#   ./scripts/test.sh -n 3
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Source shared configuration and functions
# =============================================================================

source "$(dirname "$0")/globals.sh"

# =============================================================================
# Command: test
# =============================================================================

cmd_test() {
    log_info "Testing cluster connectivity"

    setup_pipe
    local nodes
    mapfile -t nodes < <(build_node_list)
    local total="${#nodes[@]}"

    for host in "${nodes[@]}"; do
        (
            if ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
                log_ok   "$host"
                echo "ok $host" > "$RESULT_PIPE"
            else
                log_warn "$host - unreachable"
                echo "fail $host" > "$RESULT_PIPE"
            fi
        ) &
    done

    collect_results "$total"
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Parse arguments for -n option
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -n)
                shift
                NUM_WORKERS="${1:?-n requires a number}"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    cmd_test
}

main "$@"
