#!/bin/bash
# =============================================================================
# globals.sh - Shared configuration for cluster scripts
#
# Source this file in other scripts:
#   source ./scripts/globals.sh
#
# =============================================================================

# Cluster configuration
MPI_SHARED="/rpi-vision-cluster"
NUM_WORKERS=5
HOSTLIST_FILE="hostlists"

# Local paths
LOCAL_BIN_DIR="./bin"

# SSH options
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no"

# Master node
MASTER_HOST="rpi-master.local"
MASTER_USER="rpi-master"

# =============================================================================
# Logging helpers
# =============================================================================

log_info()    { printf "\033[0;35m$*\033[0m\n"; }
log_ok()      { printf "\033[0;32m$*\033[0m\n"; }
log_warn()    { printf "\033[0;33m$*\033[0m\n"; }
log_error()   { printf "\033[0;31m$*\033[0m\n" >&2; }

# =============================================================================
# Host list construction
# =============================================================================

build_node_list() {
    echo "$MASTER_HOST"
    for i in $(seq 1 "$NUM_WORKERS"); do
        echo "rpi-worker${i}.local"
    done
}

# =============================================================================
# Parallel result collection
#
# Each parallel job writes a single result line to a named pipe (fifo).
# Format: "ok <host>" or "fail <host>"
# collect_results reads exactly N lines, tallies them, and prints a summary.
# The pipe is created fresh per command and removed on script exit.
# =============================================================================

RESULT_PIPE=""

setup_pipe() {
    RESULT_PIPE="$(mktemp -u /tmp/cluster-pipe-XXXXXX)"
    mkfifo "$RESULT_PIPE"
    trap 'rm -f "$RESULT_PIPE"' EXIT
}

# collect_results <total>
#   Blocks until all N results are received, then prints the summary.
collect_results() {
    local total="$1"
    local pass=0 fail=0 failed_nodes=""

    for (( i = 0; i < total; i++ )); do
        IFS= read -r line < "$RESULT_PIPE"
        status="${line%% *}"
        host="${line#* }"
        if [ "$status" = "ok" ]; then
            pass=$(( pass + 1 ))
        else
            fail=$(( fail + 1 ))
            failed_nodes="${failed_nodes} ${host}"
        fi
    done

    wait

    echo ""
    echo "Result: success=${pass} fail=${fail}"
    if [ -n "$failed_nodes" ]; then
        echo "Failed:${failed_nodes}"
    fi
}