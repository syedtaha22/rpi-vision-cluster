#!/usr/bin/env bash
# =============================================================================
# run_game.sh — MPI Number Guessing Game (cluster smoke test)
# =============================================================================
# Runs the MPI number game on rpi-master + N workers (2 to 5).
# This is an interactive smoke test. Once started, players must SSH into
# their respective Raspberry Pis and run ~/play_game.sh to submit their guess.
#
# Usage:
#   bash rpi/run_game.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[game]${NC} $*"; }
success() { echo -e "${GREEN}[game] ✓${NC} $*"; }
die()     { echo -e "${RED}[game] ✗${NC} $*" >&2; exit 1; }

[[ -f "$CONFIG" ]] || die "config.env not found. Run setup_cluster.sh first."
# shellcheck source=/dev/null
source "$CONFIG"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     MPI Cluster Number Game — Smoke Test             ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║  master  → generates secret number (1–100)           ║${NC}"
echo -e "${BOLD}║  workers → players log in and run ~/play_game.sh     ║${NC}"
echo -e "${BOLD}║  Closest guess wins!                                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Ask for number of players ─────────────────────────────────────────────────
while true; do
    read -rp "How many workers are playing? (2-5): " NUM_WORKERS
    if [[ "$NUM_WORKERS" =~ ^[0-9]+$ ]] && (( NUM_WORKERS >= 2 && NUM_WORKERS <= 5 )); then
        break
    fi
    echo -e "  ${RED}Invalid!${NC} Please enter a number between 2 and 5."
done

# ── Verify game binary exists ─────────────────────────────────────────────────
info "Checking /tmp/game on nodes..."
NODES=("${MASTER_USER}@${MASTER_IP}")
for ((i=1; i<=NUM_WORKERS; i++)); do
    WUSER_VAR="WORKER${i}_USER"
    WIP_VAR="WORKER${i}_IP"
    NODES+=("${!WUSER_VAR}@${!WIP_VAR}")
done

for NODE_USER_IP in "${NODES[@]}"; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${NODE_USER_IP}" "[ -f /tmp/game ]" 2>/dev/null; then
        die "/tmp/game not found on ${NODE_USER_IP}. Run: make rpi-deploy"
    fi
done
success "game binary confirmed on all selected nodes"
echo ""

# ── Create dynamic hostfile ───────────────────────────────────────────────────
GAME_HOSTFILE="/tmp/hostfile_game"
HOSTFILE_CONTENT="${MASTER_IP}:1\n"
for ((i=1; i<=NUM_WORKERS; i++)); do
    WIP_VAR="WORKER${i}_IP"
    HOSTFILE_CONTENT+="${!WIP_VAR}:1\n"
done
ssh "${MASTER_USER}@${MASTER_IP}" "printf '${HOSTFILE_CONTENT}' > ${GAME_HOSTFILE}"

# ── Start Game ────────────────────────────────────────────────────────────────
echo -e "${BOLD}🚀 Game is starting!${NC}"
echo -e "Tell your friends to SSH into their respective Raspberry Pis and run:"
echo -e "  ${YELLOW}bash ~/play_game.sh${NC}"
echo ""
echo -e "${YELLOW}── Master Output ───────────────────────────────────────${NC}"

NP=$((NUM_WORKERS + 1))
ssh "${MASTER_USER}@${MASTER_IP}" \
    "mpirun -np ${NP} --hostfile ${GAME_HOSTFILE} -wdir /tmp /tmp/game" || true

echo -e "${YELLOW}────────────────────────────────────────────────────────${NC}"
echo ""

# ── Cleanup ───────────────────────────────────────────────────────────────────
ssh "${MASTER_USER}@${MASTER_IP}" "rm -f ${GAME_HOSTFILE}" 2>/dev/null || true
success "Game complete!"
