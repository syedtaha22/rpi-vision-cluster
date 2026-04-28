#!/usr/bin/env bash
# =============================================================================
# setup_cluster.sh — One-shot Raspberry Pi cluster setup
# =============================================================================
# Run this ONCE from your laptop after physically connecting all 6 Pis.
# Assumes you can already SSH into all nodes with a password.
#
# What it does:
#   1. Validates config.env is fully filled in
#   2. Installs mpich + libgomp on all 6 nodes
#   3. Generates an SSH keypair on the master (idempotent)
#   4. Copies the master's public key to all 6 nodes (passwordless SSH)
#   5. Writes ~/.ssh/config on the master (correct User per host)
#   6. Adds master IP to /etc/hosts on all 5 workers
#   7. Pre-scans SSH fingerprints so mpirun never prompts
#   8. Writes ~/hostfile on the master (all 6 node IPs)
#   9. Calls verify.sh
#
# Usage:
#   cd /path/to/PDC_project
#   cp rpi/config.env.template rpi/config.env
#   nano rpi/config.env          # fill in real IPs
#   bash rpi/setup_cluster.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[setup]${NC} $*"; }
success() { echo -e "${GREEN}[setup] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[setup] ⚠${NC} $*"; }
die()     { echo -e "${RED}[setup] ✗ FATAL:${NC} $*" >&2; exit 1; }

# ── Step 0: Load & validate config ───────────────────────────────────────────
if [[ ! -f "$CONFIG" ]] || grep -q "__FILL_IN__" "$CONFIG" 2>/dev/null; then
    info "config.env missing or incomplete — running gen_config.sh first..."
    bash "${SCRIPT_DIR}/gen_config.sh" || die "gen_config.sh failed. Fix config.env manually and re-run."
fi

# shellcheck source=/dev/null
source "$CONFIG"

info "Validating config.env..."
MISSING=0
for VAR in MASTER_USER MASTER_HOST MASTER_IP \
           WORKER1_USER WORKER1_HOST WORKER1_IP \
           WORKER2_USER WORKER2_HOST WORKER2_IP \
           WORKER3_USER WORKER3_HOST WORKER3_IP \
           WORKER4_USER WORKER4_HOST WORKER4_IP \
           WORKER5_USER WORKER5_HOST WORKER5_IP; do
    VAL="${!VAR:-}"
    if [[ -z "$VAL" || "$VAL" == "__FILL_IN__" ]]; then
        echo -e "  ${RED}✗${NC} $VAR is not set"
        MISSING=1
    fi
done
[[ $MISSING -eq 0 ]] || die "Fix config.env before continuing."
success "config.env is valid"

# Convenience arrays for iteration
USERS=("$MASTER_USER"  "$WORKER1_USER" "$WORKER2_USER" "$WORKER3_USER" "$WORKER4_USER" "$WORKER5_USER")
HOSTS=("$MASTER_HOST"  "$WORKER1_HOST" "$WORKER2_HOST" "$WORKER3_HOST" "$WORKER4_HOST" "$WORKER5_HOST")
IPS=(  "$MASTER_IP"    "$WORKER1_IP"   "$WORKER2_IP"   "$WORKER3_IP"   "$WORKER4_IP"   "$WORKER5_IP")
NODE_COUNT=${#USERS[@]}

WORKER_USERS=("$WORKER1_USER" "$WORKER2_USER" "$WORKER3_USER" "$WORKER4_USER" "$WORKER5_USER")
WORKER_HOSTS=("$WORKER1_HOST" "$WORKER2_HOST" "$WORKER3_HOST" "$WORKER4_HOST" "$WORKER5_HOST")
WORKER_IPS=( "$WORKER1_IP"   "$WORKER2_IP"   "$WORKER3_IP"   "$WORKER4_IP"   "$WORKER5_IP")

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Cluster: 1 master + 5 workers  (${NODE_COUNT} nodes total)"
echo "  Master : ${MASTER_USER}@${MASTER_HOST} (${MASTER_IP})"
for i in "${!WORKER_USERS[@]}"; do
    echo "  Worker$((i+1)): ${WORKER_USERS[$i]}@${WORKER_HOSTS[$i]} (${WORKER_IPS[$i]})"
done
echo "════════════════════════════════════════════════════════"
echo ""
read -rp "Proceed with setup? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Step 1: Install all required packages on all nodes ────────────────────────
# Using openmpi-bin + libopenmpi-dev to match the Docker environment exactly.
# build-essential + g++ are needed to compile C++ code on the nodes themselves.
# libgomp1/dev provides OpenMP support for arch1/arch2 pipelines.
# rsync is needed by deploy.sh to sync source files efficiently.
info "Step 1/8 — Installing all required packages on all ${NODE_COUNT} nodes..."
PACKAGES="build-essential g++ openmpi-bin libopenmpi-dev libgomp1 rsync cmake"
for i in $(seq 0 $((NODE_COUNT - 1))); do
    USER="${USERS[$i]}"
    HOST="${HOSTS[$i]}"
    IP="${IPS[$i]}"
    info "  ${HOST} (${IP}) — installing: ${PACKAGES}"
    ssh -o StrictHostKeyChecking=accept-new "${USER}@${IP}" "
        sudo apt-get update -qq 2>&1 | tail -2
        sudo apt-get install -y ${PACKAGES} 2>&1 | tail -5
        echo '--- Versions ---'
        mpirun --version 2>&1 | head -1
        g++ --version | head -1
        echo 'rsync:' \$(rsync --version | head -1)
    "
    success "  ${HOST}: all packages installed"
done

# ── Step 2: Generate SSH keypair on master (idempotent) ───────────────────────
info "Step 2/8 — Generating SSH keypair on master..."
ssh -o StrictHostKeyChecking=accept-new "${MASTER_USER}@${MASTER_IP}" \
    "[ -f ~/.ssh/id_rsa ] && echo 'Key already exists, skipping.' || ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa"
success "Master keypair ready"

# ── Step 3: Fetch master's public key to local machine ───────────────────────
info "Step 3/8 — Fetching master public key..."
MASTER_PUBKEY=$(ssh "${MASTER_USER}@${MASTER_IP}" "cat ~/.ssh/id_rsa.pub")
success "Public key retrieved"

# ── Step 4: Copy public key to all 6 nodes ───────────────────────────────────
info "Step 4/8 — Distributing master public key to all nodes..."
for i in $(seq 0 $((NODE_COUNT - 1))); do
    USER="${USERS[$i]}"
    IP="${IPS[$i]}"
    info "  → ${USER}@${IP}"
    ssh -o StrictHostKeyChecking=accept-new "${USER}@${IP}" "
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        echo '${MASTER_PUBKEY}' >> ~/.ssh/authorized_keys
        sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
    "
    success "  Authorized on ${USER}@${IP}"
done

# ── Step 5: Write ~/.ssh/config on master ────────────────────────────────────
info "Step 5/8 — Writing SSH config on master..."
SSH_CONFIG="# Auto-generated by setup_cluster.sh — do not edit manually
Host ${MASTER_HOST} ${MASTER_IP}
    User ${MASTER_USER}
    StrictHostKeyChecking accept-new

Host ${WORKER1_HOST} ${WORKER1_IP}
    User ${WORKER1_USER}
    StrictHostKeyChecking accept-new

Host ${WORKER2_HOST} ${WORKER2_IP}
    User ${WORKER2_USER}
    StrictHostKeyChecking accept-new

Host ${WORKER3_HOST} ${WORKER3_IP}
    User ${WORKER3_USER}
    StrictHostKeyChecking accept-new

Host ${WORKER4_HOST} ${WORKER4_IP}
    User ${WORKER4_USER}
    StrictHostKeyChecking accept-new

Host ${WORKER5_HOST} ${WORKER5_IP}
    User ${WORKER5_USER}
    StrictHostKeyChecking accept-new
"
ssh "${MASTER_USER}@${MASTER_IP}" "cat > ~/.ssh/config && chmod 600 ~/.ssh/config" <<< "$SSH_CONFIG"
success "SSH config written on master"

# ── Step 6: Add master IP to /etc/hosts on all workers ───────────────────────
info "Step 6/8 — Adding master IP to /etc/hosts on all workers..."
for i in "${!WORKER_USERS[@]}"; do
    USER="${WORKER_USERS[$i]}"
    IP="${WORKER_IPS[$i]}"
    ssh "${USER}@${IP}" "
        grep -q '${MASTER_IP}' /etc/hosts && echo 'Entry already exists' || \
        echo '${MASTER_IP} rpi-master rpi-master.local' | sudo tee -a /etc/hosts > /dev/null
    "
    success "  ${USER}@${IP}: hosts updated"
done

# ── Step 7: Pre-scan SSH fingerprints from master ────────────────────────────
info "Step 7/8 — Pre-scanning SSH fingerprints from master..."
for i in $(seq 0 $((NODE_COUNT - 1))); do
    USER="${USERS[$i]}"
    IP="${IPS[$i]}"
    ssh "${MASTER_USER}@${MASTER_IP}" \
        "ssh -o StrictHostKeyChecking=accept-new ${USER}@${IP} 'hostname'" 2>/dev/null || true
    success "  Fingerprint cached for ${USER}@${IP}"
done

# ── Step 8: Write ~/hostfile on master ───────────────────────────────────────
info "Step 8/8 — Writing hostfile on master..."
HOSTFILE_CONTENT=""
for IP in "${IPS[@]}"; do
    HOSTFILE_CONTENT+="${IP}:1"$'\n'
done
ssh "${MASTER_USER}@${MASTER_IP}" "cat > ~/hostfile" <<< "$HOSTFILE_CONTENT"
success "Hostfile written: $(echo "$HOSTFILE_CONTENT" | tr '\n' ' ')"

# ── Done: run verify ─────────────────────────────────────────────────────────
echo ""
success "════════ Setup complete ════════"
echo ""
info "Running cluster verification..."
bash "${SCRIPT_DIR}/verify.sh"
