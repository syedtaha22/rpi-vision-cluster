#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Sync source & compile all binaries on the RPI cluster
# =============================================================================
# Transfers the entire workspace/ tree to the master, compiles all 18 vision
# architecture binaries + game binary on the master, then distributes the
# compiled binaries to all worker nodes.
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

WORKSPACE_LOCAL="${REPO_ROOT}/workspace"
WORKSPACE_REMOTE="~/workspace"
BUILD_REMOTE="~/workspace/build"

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

    # Also copy game files
    info "Copying game files → master"
    scp "${REPO_ROOT}/rpi/game.cpp" "${MASTER_USER}@${MASTER_IP}:~/game.cpp"
    scp "${REPO_ROOT}/rpi/play_game.sh" "${MASTER_USER}@${MASTER_IP}:~/play_game.sh"
    ssh "${MASTER_USER}@${MASTER_IP}" "chmod +x ~/play_game.sh"
    success "game files copied"
else
    warn "Skipping workspace sync (--skip-sync)"
fi

# ── Step 2: Compile all binaries on master ────────────────────────────────────
if [[ $SKIP_COMPILE -eq 0 ]]; then
    step "Compiling on master"

    # Ensure build dir exists
    ssh "${MASTER_USER}@${MASTER_IP}" "mkdir -p ${BUILD_REMOTE}"

    # Compile game.cpp → /tmp/game
    info "Compiling game.cpp → /tmp/game"
    ssh "${MASTER_USER}@${MASTER_IP}" "mpic++ -O2 -std=c++17 -o /tmp/game ~/game.cpp"
    success "game binary compiled"

    # Compile all 18 vision architecture binaries.
    # NOTE: Binaries are ALWAYS compiled natively on the Pis.
    # Docker binaries (even ARM64 emulated) are NOT transferred here —
    # glibc versions and OpenMPI ABI may differ between Debian Bullseye
    # in Docker and Raspberry Pi OS on the real hardware.
    # Both environments use openmpi-bin/libopenmpi-dev for consistency.
    info "Compiling all vision architecture binaries (this takes a few minutes)..."
    ssh "${MASTER_USER}@${MASTER_IP}" bash << 'REMOTE_COMPILE'
set -e
cd ~/workspace
W=~/workspace/vision
B=~/workspace/build
# Use the same flags as the Docker workspace/Makefile
FLAGS="-std=c++17 -O2 -I${HOME}/workspace/vision/shared"

echo "  [arch1] OpenMP Farm..."
mpic++ ${FLAGS} -fopenmp ${W}/sobel/sobel_arch1_farm.cpp     -o ${B}/sobel_arch1 -lm
mpic++ ${FLAGS} -fopenmp ${W}/log/log_arch1_farm.cpp         -o ${B}/log_arch1   -lm
mpic++ ${FLAGS} -fopenmp ${W}/canny/canny_arch1_farm.cpp     -o ${B}/canny_arch1 -lm
mpic++ ${FLAGS} -fopenmp ${W}/fft/fft_arch1_farm.cpp         -o ${B}/fft_arch1   -lm

echo "  [arch2] OpenMP Pipeline..."
mpic++ ${FLAGS} -fopenmp ${W}/sobel/sobel_arch2_pipeline.cpp -o ${B}/sobel_arch2 -lm
mpic++ ${FLAGS} -fopenmp ${W}/log/log_arch2_pipeline.cpp     -o ${B}/log_arch2   -lm
mpic++ ${FLAGS} -fopenmp ${W}/canny/canny_arch2_pipeline.cpp -o ${B}/canny_arch2 -lm
mpic++ ${FLAGS} -fopenmp ${W}/fft/fft_arch2_pipeline.cpp     -o ${B}/fft_arch2   -lm

echo "  [arch3] MPI Scatter-Gather..."
mpic++ ${FLAGS} ${W}/sobel/sobel_arch3_scatter.cpp           -o ${B}/sobel_arch3 -lm
mpic++ ${FLAGS} ${W}/log/log_arch3_scatter.cpp               -o ${B}/log_arch3   -lm
mpic++ ${FLAGS} ${W}/canny/canny_arch3_scatter.cpp           -o ${B}/canny_arch3 -lm
mpic++ ${FLAGS} ${W}/fft/fft_arch3_dist_dynamic.cpp          -o ${B}/fft_arch3   -lm

echo "  [arch4] MPI Distributed Pipeline..."
mpic++ ${FLAGS} ${W}/sobel/sobel_arch4_pipeline.cpp          -o ${B}/sobel_arch4 -lm
mpic++ ${FLAGS} ${W}/log/log_arch4_pipeline.cpp              -o ${B}/log_arch4   -lm
mpic++ ${FLAGS} ${W}/canny/canny_arch4_pipeline.cpp          -o ${B}/canny_arch4 -lm
mpic++ ${FLAGS} ${W}/fft/fft_arch4_dist_pipeline.cpp         -o ${B}/fft_arch4   -lm

echo "  [extras] Bully election, resilience, baselines..."
mpic++ ${FLAGS} ${W}/resilience/bully_election.cpp           -o ${B}/bully_election  -lm
mpic++ ${FLAGS} ${W}/resilience/resilience_test.cpp          -o ${B}/resilience_test -lm
mpic++ ${FLAGS} ${W}/shared/baselines.cpp                    -o ${B}/baselines        -lm

echo "  Done."
REMOTE_COMPILE
    success "All 18 vision binaries compiled on master"
else
    warn "Skipping compilation (--skip-compile)"
fi

# ── Step 3: Distribute binaries from master to all workers ───────────────────
if [[ $SKIP_DIST -eq 0 ]]; then
    step "Distributing binaries to workers"

    # List of all binaries to distribute
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

        # Ensure remote build dir exists
        ssh "${WUSER}@${WIP}" "mkdir -p ~/workspace/build"

        # Also copy game binary and play script to workers
        ssh "${MASTER_USER}@${MASTER_IP}" \
            "scp /tmp/game ${WUSER}@${WIP}:/tmp/game && scp ~/play_game.sh ${WUSER}@${WIP}:~/play_game.sh && ssh ${WUSER}@${WIP} 'chmod +x ~/play_game.sh'"

        # Copy all vision binaries via master (master has passwordless SSH to workers)
        for BIN in "${BINARIES[@]}"; do
            ssh "${MASTER_USER}@${MASTER_IP}" \
                "scp ~/workspace/build/${BIN} ${WUSER}@${WIP}:~/workspace/build/${BIN}"
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
echo -e "║  Workspace : synced to master                ║"
echo -e "║  Binaries  : 18 vision + 1 game              ║"
echo -e "║  Nodes     : master + 5 workers              ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo "  Verify  : make rpi-verify"
echo "  Play    : make rpi-game"
echo "  Vision  : make rpi-run FILTER=sobel ARCH=3 NODES=6 IMAGE=path/to/img.jpg"
