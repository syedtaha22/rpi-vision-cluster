#!/usr/bin/env bash
# =============================================================================
# init.sh - Initialize Raspberry Pi cluster
#
# Purpose:
#   Upload init_pi.sh to all nodes and execute it sequentially.
#   Uploads hostlist to master after all nodes are initialized.
#
# Usage:
#   ./scripts/init.sh
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Source shared configuration and functions
# =============================================================================

source "$(dirname "$0")/globals.sh"

# =============================================================================
# Command: init
# =============================================================================

cmd_init() {
    log_info "Initialising cluster"

    local init_script="scripts/init_pi.sh"

    if [ ! -f "$init_script" ]; then
        log_error "init_pi.sh not found at $init_script"
        exit 1
    fi

    echo ""
    log_info "Initializing all nodes sequentially"

    local nodes
    mapfile -t nodes < <(build_node_list)

    for host in "${nodes[@]}"; do
        local user="${host%%.*}"
        log_info "Processing $host"

        # Upload
        if ! scp $SSH_OPTS "$init_script" "${user}@${host}:/tmp/"; then
            log_error "Failed to upload to $host"
            exit 1
        fi

        # Make executable and run init script
        if ! ssh -t $SSH_OPTS "${user}@${host}" "chmod +x /tmp/init_pi.sh && sudo /tmp/init_pi.sh"; then
            log_error "Failed to initialize $host"
            exit 1
        fi

        log_ok "$host configured successfully"
    done

    # Upload hostlist to master
    if [ -f "$HOSTLIST_FILE" ]; then
        echo ""
        log_info "Uploading ${HOSTLIST_FILE} to master"
        if scp $SSH_OPTS "$HOSTLIST_FILE" "rpi-master@rpi-master.local:${MPI_SHARED}/"; then
            log_ok "${HOSTLIST_FILE} uploaded to master"
        else
            log_warn "Failed to upload ${HOSTLIST_FILE}"
        fi
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    cmd_init "$@"
}

main "$@"
