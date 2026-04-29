#!/bin/bash
# =============================================================================
# upload.sh - Upload files to master's NFS shared folder
#
# Purpose:
#   Upload any file (binary, script, data, etc.) to the master node's
#   shared NFS folder, making it accessible to all cluster nodes.
#
# Usage:
#   ./scripts/upload.sh <file>
#   ./scripts/upload.sh <file1> <file2> ...
#
# Examples:
#   ./scripts/upload.sh ./bin/hello_cluster
#   ./scripts/upload.sh data.txt script.sh
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Source Globals
# =============================================================================

source "$(dirname "$0")/globals.sh"

# =============================================================================
# Main upload logic
# =============================================================================

upload_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        log_error "File not found: $file"
        return 1
    fi

    local filename
    filename="$(basename "$file")"

    log_info "Uploading file to master's NFS shared folder"
    log_info "File   : $file"
    log_info "Target : rpi-master.local:${MPI_SHARED}/$filename"

    if scp $SSH_OPTS "$file" "rpi-master@rpi-master.local:${MPI_SHARED}/"; then
        log_ok "Uploaded: $filename"
        return 0
    else
        log_error "Upload failed: $filename"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    if [ "$#" -eq 0 ]; then
        log_error "No files specified"
        echo "Usage: $0 <file> [file2] [file3] ..."
        exit 1
    fi

    local failed=0

    for file in "$@"; do
        if ! upload_file "$file"; then
            failed=$((failed + 1))
        fi
    done

    echo ""
    if [ "$failed" -eq 0 ]; then
        log_ok "All files uploaded successfully"
        exit 0
    else
        log_error "$failed file(s) failed to upload"
        exit 1
    fi
}

main "$@"
