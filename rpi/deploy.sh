#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Sync source & compile all binaries on the RPI cluster
# =============================================================================
# Transfers the entire workspace/ tree to the master, compiles all 18 vision
# architecture binaries + game binary on the master, then distributes the
# compiled binaries to all worker nodes.
#
# Binaries are deployed to TWO locations on every node:
#   1. $RPI_WORKSPACE_DIR/build/  — master's own workspace build dir
#   2. $RPI_SHARED_BIN/           — fixed path identical on all nodes (for mpirun)
#
# Usage:
#   bash rpi/deploy.sh [--skip-sync] [--skip-compile] [--skip-dist]
#
# Options:
#   --skip-sync     Skip rsync of workspace/ (use if code hasn't changed)
#   --skip-compile  Skip compilation (use existing binaries on master)
#   --skip-dist     Skip distributing binaries to workers
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[deploy]${NC} $*"; }
success() { echo -e "${GREEN}[deploy] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[deploy] ⚠${NC} $*"; }
die()     { echo -e "${RED}[deploy] ✗ FATAL:${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Parse flags ───────────────────────────────────────────────────────────────
SKIP_SYNC=0; SKIP_COMPILE=0; SKIP_DIST=0
for arg in "$@"; do
    case "$arg" in
        --skip-sync)    SKIP_SYNC=1 ;;
        --skip-compile) SKIP_COMPILE=1 ;;
        --skip-dist)    SKIP_DIST=1 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ── Load config ───────────────────────────────────────────────────────────────
[[ -f "$CONFIG" ]] || die "config.env not found. Run setup_cluster.sh first."
# shellcheck source=/dev/null
source "$CONFIG"

WORKER_USERS=("$WORKER1_USER" "$WORKER2_USER" "$WORKER3_USER" "$WORKER4_USER" "$WORKER5_USER")
WORKER_IPS=( "$WORKER1_IP"   "$WORKER2_IP"   "$WORKER3_IP"   "$WORKER4_IP"   "$WORKER5_IP")

RPI_WORKSPACE_DIR="${RPI_WORKSPACE_DIR:-~/Desktop/rpi-vision-cluster/workspace}"
RPI_WS_PARENT="${RPI_WS_PARENT:-~/Desktop/PDC_project}"
# Fixed absolute path that is the same on every node regardless of username.
# mpirun requires an identical binary path on all ranks.
RPI_SHARED_BIN="${RPI_SHARED_BIN:-/var/tmp/pdc_build}"

# Expand tildes on the remote master explicitly.
q_ws=$(printf '%q' "$RPI_WORKSPACE_DIR")
q_parent=$(printf '%q' "$RPI_WS_PARENT")
RPI_WORKSPACE_DIR_EXPANDED=$(ssh "${MASTER_USER}@${MASTER_IP}" "bash -lc \"echo ${q_ws}\"" 2>/dev/null) \
    || die "Failed to expand RPI_WORKSPACE_DIR on master"
RPI_WS_PARENT_EXPANDED=$(ssh "${MASTER_USER}@${MASTER_IP}" "bash -lc \"echo ${q_parent}\"" 2>/dev/null) \
    || die "Failed to expand RPI_WS_PARENT on master"
unset q_ws q_parent

WORKSPACE_LOCAL="${REPO_ROOT}/workspace"
WORKSPACE_REMOTE="${RPI_WORKSPACE_DIR_EXPANDED}"
BUILD_REMOTE="${RPI_WORKSPACE_DIR_EXPANDED}/build"

# ── Step 1: Sync workspace/ to master ────────────────────────────────────────
if [[ $SKIP_SYNC -eq 0 ]]; then
    step "Syncing workspace/ → master"
    info "rsync ${WORKSPACE_LOCAL}/ → ${MASTER_USER}@${MASTER_IP}:${WORKSPACE_REMOTE}/"
    rsync -avz --progress \
        --exclude "build/" \
        --exclude "results/" \
        --exclude "__pycache__/" \
        --exclude "*.pyc" \
        --exclude "datasets/" \
        "${WORKSPACE_LOCAL}/" \
        "${MASTER_USER}@${MASTER_IP}:${WORKSPACE_REMOTE}/"
    success "workspace/ synced to master"

    info "Copying game files → master"
    ssh "${MASTER_USER}@${MASTER_IP}" "mkdir -p ${RPI_WS_PARENT_EXPANDED}"
    scp "${REPO_ROOT}/rpi/game.cpp"     "${MASTER_USER}@${MASTER_IP}:${RPI_WS_PARENT_EXPANDED}/game.cpp"
    scp "${REPO_ROOT}/rpi/play_game.sh" "${MASTER_USER}@${MASTER_IP}:${RPI_WS_PARENT_EXPANDED}/play_game.sh"
    ssh "${MASTER_USER}@${MASTER_IP}" "chmod +x ${RPI_WS_PARENT_EXPANDED}/play_game.sh"
    success "game files copied"
else
    warn "Skipping workspace sync (--skip-sync)"
fi

# ── Step 2: Compile all binaries on master ────────────────────────────────────
if [[ $SKIP_COMPILE -eq 0 ]]; then
    step "Compiling on master"

    ssh "${MASTER_USER}@${MASTER_IP}" "mkdir -p ${BUILD_REMOTE} ${RPI_SHARED_BIN}"

    info "Compiling game.cpp → ${RPI_GAME_BIN:-/tmp/game}"
    ssh "${MASTER_USER}@${MASTER_IP}" "mpic++ -O2 -std=c++17 -o ${RPI_GAME_BIN:-/tmp/game} ${RPI_WS_PARENT_EXPANDED}/game.cpp"
    success "game binary compiled"

    info "Compiling all vision architecture binaries (this takes a few minutes)..."
    ssh "${MASTER_USER}@${MASTER_IP}" WS="${RPI_WORKSPACE_DIR_EXPANDED}" bash << 'REMOTE_COMPILE'
set -e
cd "$WS"
B="${WS}/build"
mkdir -p "$B"
FLAGS="-std=c++17 -O2 -I${WS}/vision/shared"

echo "  [arch1] OpenMP Farm..."
mpic++ ${FLAGS} -fopenmp ${WS}/vision/sobel/sobel_arch1_farm.cpp     -o ${B}/sobel_arch1 -lm
mpic++ ${FLAGS} -fopenmp ${WS}/vision/log/log_arch1_farm.cpp         -o ${B}/log_arch1   -lm
mpic++ ${FLAGS} -fopenmp ${WS}/vision/canny/canny_arch1_farm.cpp     -o ${B}/canny_arch1 -lm
mpic++ ${FLAGS} -fopenmp ${WS}/vision/fft/fft_arch1_farm.cpp         -o ${B}/fft_arch1   -lm

echo "  [arch2] OpenMP Pipeline..."
mpic++ ${FLAGS} -fopenmp ${WS}/vision/sobel/sobel_arch2_pipeline.cpp -o ${B}/sobel_arch2 -lm
mpic++ ${FLAGS} -fopenmp ${WS}/vision/log/log_arch2_pipeline.cpp     -o ${B}/log_arch2   -lm
mpic++ ${FLAGS} -fopenmp ${WS}/vision/canny/canny_arch2_pipeline.cpp -o ${B}/canny_arch2 -lm
mpic++ ${FLAGS} -fopenmp ${WS}/vision/fft/fft_arch2_pipeline.cpp     -o ${B}/fft_arch2   -lm

echo "  [arch3] MPI Scatter-Gather..."
mpic++ ${FLAGS} ${WS}/vision/sobel/sobel_arch3_scatter.cpp           -o ${B}/sobel_arch3 -lm
mpic++ ${FLAGS} ${WS}/vision/log/log_arch3_scatter.cpp               -o ${B}/log_arch3   -lm
mpic++ ${FLAGS} ${WS}/vision/canny/canny_arch3_scatter.cpp           -o ${B}/canny_arch3 -lm
mpic++ ${FLAGS} ${WS}/vision/fft/fft_arch3_dist_dynamic.cpp          -o ${B}/fft_arch3   -lm

echo "  [arch4] MPI Distributed Pipeline..."
mpic++ ${FLAGS} ${WS}/vision/sobel/sobel_arch4_pipeline.cpp          -o ${B}/sobel_arch4 -lm
mpic++ ${FLAGS} ${WS}/vision/log/log_arch4_pipeline.cpp              -o ${B}/log_arch4   -lm
mpic++ ${FLAGS} ${WS}/vision/canny/canny_arch4_pipeline.cpp          -o ${B}/canny_arch4 -lm
mpic++ ${FLAGS} ${WS}/vision/fft/fft_arch4_dist_pipeline.cpp         -o ${B}/fft_arch4   -lm

echo "  [extras] Bully election, resilience, baselines..."
mpic++ ${FLAGS} ${WS}/vision/resilience/bully_election.cpp           -o ${B}/bully_election  -lm
mpic++ ${FLAGS} ${WS}/vision/resilience/resilience_test.cpp          -o ${B}/resilience_test -lm
mpic++ ${FLAGS} ${WS}/vision/shared/baselines.cpp                    -o ${B}/baselines        -lm

echo "  Done."
REMOTE_COMPILE
    success "All 18 vision binaries compiled on master"

    # Copy compiled binaries to the shared bin dir on master
    info "Copying binaries to shared path ${RPI_SHARED_BIN} on master..."
    ssh "${MASTER_USER}@${MASTER_IP}" "cp ${BUILD_REMOTE}/* ${RPI_SHARED_BIN}/"
    success "Shared bin dir populated on master"
else
    warn "Skipping compilation (--skip-compile)"
fi

# ── Step 3: Distribute binaries from master to all workers ───────────────────
if [[ $SKIP_DIST -eq 0 ]]; then
    step "Distributing binaries to workers"

    BINARIES=(
        sobel_arch1 log_arch1 canny_arch1 fft_arch1
        sobel_arch2 log_arch2 canny_arch2 fft_arch2
        sobel_arch3 log_arch3 canny_arch3 fft_arch3
        sobel_arch4 log_arch4 canny_arch4 fft_arch4
        bully_election resilience_test baselines
    )

    for i in "${!WORKER_USERS[@]}"; do
        WUSER="${WORKER_USERS[$i]}"
        WIP="${WORKER_IPS[$i]}"
        info "  → worker$((i+1)): ${WUSER}@${WIP}"

        # Create shared bin dir on worker (same absolute path for mpirun)
        ssh "${WUSER}@${WIP}" "mkdir -p ${RPI_SHARED_BIN}"

        # Copy game binary and play script
        ssh "${MASTER_USER}@${MASTER_IP}" \
            "scp ${RPI_GAME_BIN:-/tmp/game} ${WUSER}@${WIP}:${RPI_GAME_BIN:-/tmp/game}"
        ssh "${MASTER_USER}@${MASTER_IP}" \
            "scp ${RPI_WS_PARENT_EXPANDED}/play_game.sh ${WUSER}@${WIP}:~/play_game.sh \
             && ssh ${WUSER}@${WIP} 'chmod +x ~/play_game.sh'"

        # Distribute vision binaries to shared path on each worker
        for BIN in "${BINARIES[@]}"; do
            ssh "${MASTER_USER}@${MASTER_IP}" \
                "scp ${BUILD_REMOTE}/${BIN} ${WUSER}@${WIP}:${RPI_SHARED_BIN}/${BIN}"
        done

        success "  worker$((i+1)) binaries deployed"
    done
else
    warn "Skipping binary distribution (--skip-dist)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗"
echo -e "║  Deploy complete                              ║"
echo -e "╠══════════════════════════════════════════════╣"
echo -e "║  Workspace  : synced to master                ║"
echo -e "║  Binaries   : 18 vision + 1 game              ║"
echo -e "║  Shared bin : ${RPI_SHARED_BIN} (all nodes) ║"
echo -e "║  Nodes      : master + 5 workers              ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo "  Verify  : bash rpi/verify.sh"
echo "  Analyse : bash analysis/run_analysis.sh --native"
