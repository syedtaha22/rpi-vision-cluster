#!/usr/bin/env bash
# =============================================================================
# full_setup.sh — One-shot idempotent cluster bootstrap
# =============================================================================
# Run this every time the Pis reconnect (e.g. after a subnet/IP change).
# Safe to re-run: duplicate SSH keys are never added, mkdir -p is idempotent.
#
# What it does:
#   1. Ensure config.env exists (runs gen_config.sh if missing/stale)
#   2. Laptop → master + all workers: install laptop SSH key
#   3. Pre-scan all 6 node fingerprints into laptop ~/.ssh/known_hosts
#   4. Master → all workers: generate master key if absent, install to workers
#   5. Create workspace directories on all 6 nodes
#   6. Verify: SSH + mpirun --version check, print PASS/FAIL table
#
# Usage:
#   bash rpi/full_setup.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[setup]${NC} $*"; }
success() { echo -e "${GREEN}[setup] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[setup] ⚠${NC} $*"; }
die()     { echo -e "${RED}[setup] ✗ FATAL:${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Step 1: config.env ────────────────────────────────────────────────────────
step "1 / 6  config.env"
if [[ ! -f "$CONFIG" ]] || grep -q "__FILL_IN__" "$CONFIG" 2>/dev/null; then
    info "config.env missing or incomplete — running gen_config.sh..."
    bash "${SCRIPT_DIR}/gen_config.sh" || die "gen_config.sh failed"
fi
# shellcheck source=/dev/null
source "$CONFIG"

ALL_USERS=("$MASTER_USER"  "$WORKER1_USER" "$WORKER2_USER" "$WORKER3_USER" "$WORKER4_USER" "$WORKER5_USER")
ALL_IPS=(  "$MASTER_IP"    "$WORKER1_IP"   "$WORKER2_IP"   "$WORKER3_IP"   "$WORKER4_IP"   "$WORKER5_IP")
ALL_HOSTS=("$MASTER_HOST"  "$WORKER1_HOST" "$WORKER2_HOST" "$WORKER3_HOST" "$WORKER4_HOST" "$WORKER5_HOST")

success "Loaded config.env (master=${MASTER_IP}, workers=${WORKER1_IP}..${WORKER5_IP})"

# ── Step 2: Laptop → all nodes SSH key ────────────────────────────────────────
step "2 / 6  Laptop → all nodes: install SSH key"

# Generate laptop key if absent
if [[ ! -f "${HOME}/.ssh/id_rsa" ]]; then
    info "Generating laptop SSH key (~/.ssh/id_rsa)..."
    ssh-keygen -t rsa -b 4096 -N "" -f "${HOME}/.ssh/id_rsa"
    success "Laptop key generated"
fi

for i in "${!ALL_USERS[@]}"; do
    USER="${ALL_USERS[$i]}"
    IP="${ALL_IPS[$i]}"
    info "  ssh-copy-id → ${USER}@${IP}"
    # -o StrictHostKeyChecking=no so we can reach new IPs without prior fingerprint
    ssh-copy-id -o StrictHostKeyChecking=no -i "${HOME}/.ssh/id_rsa.pub" \
        "${USER}@${IP}" 2>/dev/null \
        && success "  ${USER}@${IP} ✓" \
        || warn "  ${USER}@${IP} — ssh-copy-id failed (password auth may be disabled or key already exists)"
done

# ── Step 3: Pre-scan all fingerprints ─────────────────────────────────────────
step "3 / 6  Pre-scan node fingerprints into ~/.ssh/known_hosts"
for i in "${!ALL_IPS[@]}"; do
    IP="${ALL_IPS[$i]}"
    HOST="${ALL_HOSTS[$i]}"
    # Remove stale entries first, then re-add
    ssh-keygen -R "$IP"   2>/dev/null || true
    ssh-keygen -R "$HOST" 2>/dev/null || true
    ssh-keyscan -H "$IP" >> "${HOME}/.ssh/known_hosts" 2>/dev/null && success "  Scanned ${IP}"
done

# ── Step 4: Master → workers SSH key ──────────────────────────────────────────
step "4 / 6  Master → workers: install master SSH key"

# Generate master key if absent
info "Generating master key on ${MASTER_USER}@${MASTER_IP} (if absent)..."
ssh "${MASTER_USER}@${MASTER_IP}" \
    "test -f ~/.ssh/id_rsa || ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa" \
    && success "Master key ready"

# Scan worker fingerprints from master, then install master key to each worker
# ALL_USERS[0]/ALL_IPS[0] is master; indices 1-5 are workers
for i in 1 2 3 4 5; do
    WUSER="${ALL_USERS[$i]}"
    WIP="${ALL_IPS[$i]}"
    info "  Master → ${WUSER}@${WIP}: pre-scan + ssh-copy-id"
    ssh "${MASTER_USER}@${MASTER_IP}" \
        "ssh-keygen -R ${WIP} 2>/dev/null || true
         ssh-keyscan -H ${WIP} >> ~/.ssh/known_hosts 2>/dev/null
         ssh-copy-id -o StrictHostKeyChecking=accept-new ${WUSER}@${WIP}" \
        && success "  Master → ${WUSER}@${WIP} ✓" \
        || warn "  Master → ${WUSER}@${WIP} — failed (worker may need password auth enabled once)"
done

# ── Step 5: Workspace directories on all nodes ────────────────────────────────
step "5 / 6  Create workspace directories on all 6 nodes"

# Expand the workspace path on master (avoids tilde issues)
q_ws=$(printf '%q' "$RPI_WORKSPACE_DIR")
NATIVE_WS=$(ssh "${MASTER_USER}@${MASTER_IP}" "bash -lc \"echo ${q_ws}\"" 2>/dev/null) \
    || die "Cannot expand RPI_WORKSPACE_DIR on master"
unset q_ws

for i in "${!ALL_USERS[@]}"; do
    USER="${ALL_USERS[$i]}"
    IP="${ALL_IPS[$i]}"
    ssh "${USER}@${IP}" "mkdir -p '${NATIVE_WS}'" \
        && success "  ${USER}@${IP}: ${NATIVE_WS} ✓" \
        || warn "  ${USER}@${IP}: mkdir failed"
done

# ── Step 6: Verify ────────────────────────────────────────────────────────────
step "6 / 6  Verification"

PASS=0; FAIL=0
printf "  %-20s %-18s %-8s %s\n" "Node" "IP" "SSH" "MPI"
printf "  %-20s %-18s %-8s %s\n" "----" "--" "---" "---"

for i in "${!ALL_USERS[@]}"; do
    USER="${ALL_USERS[$i]}"
    IP="${ALL_IPS[$i]}"
    ssh_ok="FAIL"
    mpi_ok="FAIL"
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${USER}@${IP}" true 2>/dev/null; then
        ssh_ok="PASS"
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
    fi
    if ssh -o BatchMode=yes "${USER}@${IP}" "mpirun --version" &>/dev/null; then
        mpi_ok="PASS"
    fi
    printf "  %-20s %-18s %-8s %s\n" "${USER}" "${IP}" "${ssh_ok}" "${mpi_ok}"
done

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All nodes reachable. Cluster ready.${NC}"
    echo ""
    echo "Next steps:"
    echo "  Deploy  : bash rpi/deploy.sh"
    echo "  Analyse : bash analysis/run_analysis.sh --native"
    echo "           bash analysis/run_analysis_bsds.sh --native"
    echo "           bash analysis/resilience_analysis.sh --native"
else
    echo -e "${YELLOW}${BOLD}${FAIL} node(s) unreachable. Check IPs and SSH keys.${NC}"
    echo "  Re-run  : bash rpi/gen_config.sh   (if IPs changed)"
    echo "  Then    : bash rpi/full_setup.sh"
fi
echo ""
