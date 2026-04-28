#!/usr/bin/env bash
# =============================================================================
# teardown.sh — Clean compiled artefacts from all RPI nodes
# =============================================================================
# Removes compiled binaries and temporary files from all 6 nodes.
# Does NOT remove source code or the workspace/ directory structure.
#
# Usage:
#   bash rpi/teardown.sh          # Clean /tmp artefacts only
#   bash rpi/teardown.sh --full   # Also wipe ~/workspace/build/ on all nodes
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[teardown]${NC} $*"; }
success() { echo -e "${GREEN}[teardown] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[teardown] ⚠${NC} $*"; }
die()     { echo -e "${RED}[teardown] ✗${NC} $*" >&2; exit 1; }

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

[[ -f "$CONFIG" ]] || die "config.env not found."
# shellcheck source=/dev/null
source "$CONFIG"

USERS=("$MASTER_USER"  "$WORKER1_USER" "$WORKER2_USER" "$WORKER3_USER" "$WORKER4_USER" "$WORKER5_USER")
IPS=(  "$MASTER_IP"    "$WORKER1_IP"   "$WORKER2_IP"   "$WORKER3_IP"   "$WORKER4_IP"   "$WORKER5_IP")
LABELS=("master" "worker1" "worker2" "worker3" "worker4" "worker5")

if [[ $FULL -eq 1 ]]; then
    warn "Full teardown: will wipe ~/workspace/build/ on all nodes"
    read -rp "Are you sure? This removes all compiled binaries. [y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

echo ""
info "Cleaning artefacts from all 6 nodes..."
echo ""

for i in $(seq 0 5); do
    USER="${USERS[$i]}"; IP="${IPS[$i]}"; LABEL="${LABELS[$i]}"
    info "  ${LABEL} (${USER}@${IP})"

    # Always clean /tmp artefacts
    ssh -o ConnectTimeout=5 -o BatchMode=yes "${USER}@${IP}" "
        rm -f /tmp/game /tmp/my_number.txt /tmp/result.txt /tmp/hostfile_*
        echo '    /tmp artefacts cleared'
    " 2>/dev/null || warn "  ${LABEL}: SSH failed, skipping"

    # Full mode: also wipe build/
    if [[ $FULL -eq 1 ]]; then
        ssh -o ConnectTimeout=5 -o BatchMode=yes "${USER}@${IP}" "
            rm -rf ~/workspace/build/
            mkdir -p ~/workspace/build/
            echo '    ~/workspace/build/ cleared'
        " 2>/dev/null || warn "  ${LABEL}: could not clear build dir"
    fi

    success "  ${LABEL}: done"
done

echo ""
if [[ $FULL -eq 1 ]]; then
    success "Full teardown complete — run 'make rpi-deploy' to redeploy"
else
    success "Teardown complete — run 'make rpi-game' or 'make rpi-run' to use the cluster"
fi
