#!/usr/bin/env bash
# =============================================================================
# verify.sh — RPI Cluster Health Check
# =============================================================================
# Runs a comprehensive health check on all 6 nodes:
#   ✓ SSH connectivity to each node
#   ✓ mpich installed on each node
#   ✓ ~/workspace/build/ binaries present (all 18 + game)
#   ✓ MPI can launch across all 6 nodes (mpirun hostname)
#
# Usage:
#   bash rpi/verify.sh [--quick]
#
# Options:
#   --quick   Skip binary checks and MPI test (connectivity only)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PASS="${GREEN}✓${NC}"; FAIL="${RED}✗${NC}"; WARN="${YELLOW}⚠${NC}"

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

[[ -f "$CONFIG" ]] || { echo -e "${RED}[verify] config.env not found${NC}"; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG"

USERS=("$MASTER_USER"  "$WORKER1_USER" "$WORKER2_USER" "$WORKER3_USER" "$WORKER4_USER" "$WORKER5_USER")
HOSTS=("$MASTER_HOST"  "$WORKER1_HOST" "$WORKER2_HOST" "$WORKER3_HOST" "$WORKER4_HOST" "$WORKER5_HOST")
IPS=(  "$MASTER_IP"    "$WORKER1_IP"   "$WORKER2_IP"   "$WORKER3_IP"   "$WORKER4_IP"   "$WORKER5_IP")
LABELS=("master" "worker1" "worker2" "worker3" "worker4" "worker5")

EXPECTED_BINS=(
    sobel_arch1 log_arch1 canny_arch1 fft_arch1
    sobel_arch2 log_arch2 canny_arch2 fft_arch2
    sobel_arch3 log_arch3 canny_arch3 fft_arch3
    sobel_arch4 log_arch4 canny_arch4 fft_arch4
    bully_election resilience_test baselines
)

OVERALL=0   # 0=pass, 1=fail

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  RPI Cluster Verification Report${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"

# ── Check 1: SSH connectivity ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[1/4] SSH Connectivity${NC}"
for i in $(seq 0 5); do
    USER="${USERS[$i]}"; IP="${IPS[$i]}"; LABEL="${LABELS[$i]}"
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "${USER}@${IP}" "hostname" &>/dev/null; then
        HOSTNAME=$(ssh -o ConnectTimeout=5 "${USER}@${IP}" "hostname" 2>/dev/null)
        echo -e "  ${PASS} ${LABEL} (${USER}@${IP}) — hostname: ${HOSTNAME}"
    else
        echo -e "  ${FAIL} ${LABEL} (${USER}@${IP}) — UNREACHABLE"
        OVERALL=1
    fi
done

# ── Check 2: mpich installed ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/4] mpich Installation${NC}"
for i in $(seq 0 5); do
    USER="${USERS[$i]}"; IP="${IPS[$i]}"; LABEL="${LABELS[$i]}"
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "${USER}@${IP}" "which mpirun" &>/dev/null; then
        VER=$(ssh "${USER}@${IP}" "mpirun --version 2>&1 | head -1" 2>/dev/null || echo "unknown")
        echo -e "  ${PASS} ${LABEL} — ${VER}"
    else
        echo -e "  ${FAIL} ${LABEL} — mpirun not found (run setup_cluster.sh)"
        OVERALL=1
    fi
done

if [[ $QUICK -eq 1 ]]; then
    echo ""
    echo -e "${WARN} Quick mode: skipping binary checks and MPI test"
else
    # ── Check 3: Binaries present ─────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}[3/4] Vision Binaries (~/workspace/build/)${NC}"
    for i in $(seq 0 5); do
        USER="${USERS[$i]}"; IP="${IPS[$i]}"; LABEL="${LABELS[$i]}"
        MISSING_COUNT=0
        MISSING_LIST=()
        for BIN in "${EXPECTED_BINS[@]}"; do
            if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${USER}@${IP}" \
                "[ -f ~/workspace/build/${BIN} ]" &>/dev/null; then
                MISSING_COUNT=$((MISSING_COUNT + 1))
                MISSING_LIST+=("$BIN")
            fi
        done

        # Check game binary
        GAME_OK=1
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${USER}@${IP}" \
            "[ -f /tmp/game ]" &>/dev/null; then
            GAME_OK=0
            MISSING_COUNT=$((MISSING_COUNT + 1))
            MISSING_LIST+=("/tmp/game")
        fi

        TOTAL=$((${#EXPECTED_BINS[@]} + 1))
        FOUND=$((TOTAL - MISSING_COUNT))
        if [[ $MISSING_COUNT -eq 0 ]]; then
            echo -e "  ${PASS} ${LABEL} — all ${TOTAL} binaries present"
        else
            echo -e "  ${FAIL} ${LABEL} — ${FOUND}/${TOTAL} binaries (missing: ${MISSING_LIST[*]})"
            echo -e "         → Run: make rpi-deploy"
            OVERALL=1
        fi
    done

    # ── Check 4: MPI connectivity test ────────────────────────────────────────
    echo ""
    echo -e "${BOLD}[4/4] MPI Cross-Node Launch (mpirun -np 6 hostname)${NC}"
    if ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_IP}" \
        "mpirun -np 6 --hostfile ~/hostfile hostname" 2>/tmp/mpi_verify_err; then
        echo -e "  ${PASS} MPI launched successfully across all 6 nodes"
        ssh "${MASTER_USER}@${MASTER_IP}" \
            "mpirun -np 6 --hostfile ~/hostfile hostname 2>/dev/null" | \
            sed 's/^/         /'
    else
        echo -e "  ${FAIL} MPI launch failed"
        cat /tmp/mpi_verify_err | sed 's/^/         /' || true
        OVERALL=1
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
if [[ $OVERALL -eq 0 ]]; then
    echo -e "  ${PASS} ${GREEN}${BOLD}Cluster is HEALTHY — all checks passed${NC}"
else
    echo -e "  ${FAIL} ${RED}${BOLD}Cluster has issues — see failures above${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""

exit $OVERALL
